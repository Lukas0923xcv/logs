package main

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"golang.org/x/crypto/bcrypt"
)

// All test data is generated here.

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func genLog(lines int) string {
	var b strings.Builder
	for i := 1; i <= lines; i++ {
		word := "info"
		if i%100 == 0 {
			word = "NEEDLE"
		}
		fmt.Fprintf(&b, "2025-01-02T00:00:00 host app[%d]: %s generated line %06d\n", i, word, i)
	}
	return b.String()
}

func manifestJSON(day, host, file string, size int) string {
	return fmt.Sprintf(`{"version":1,"day":%q,"hosts":{%q:{"status":"ok","origin":"ansible","error":"",
"sources":[{"name":"journald","file":%q,"bytes":%d,"lines":5000,"errors":3,"warnings":7,"ok":true,"msg":""}]},
"down01":{"status":"failed","origin":"ansible","error":"unreachable","sources":[]}}}`, day, host, file, size)
}

func testApp(t *testing.T, mutate func(*config)) (*app, string) {
	t.Helper()
	dir := t.TempDir()
	content := genLog(5000)

	// raw day
	write(t, dir+"/raw/2025/01/02/web01/journald.log", content)
	write(t, dir+"/manifests/2025/2025-01-02.json", manifestJSON("2025-01-02", "web01", "journald.log", len(content)))
	// archived day
	write(t, dir+"/manifests/2025/2025-01-01.json", manifestJSON("2025-01-01", "web01", "journald.log", len(content)))
	var buf bytes.Buffer
	zw, _ := zstd.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	for _, name := range []string{"db01/other.log", "web01/journald.log"} {
		_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg})
		_, _ = tw.Write([]byte(content))
	}
	_ = tw.Close()
	_ = zw.Close()
	write(t, dir+"/archive/2025/2025-01-01.tar.zst", buf.String())
	// a file outside the data directory that must never be reachable
	write(t, filepath.Dir(dir)+"/secret.txt", "outside")

	cfg := config{DataDir: dir, Title: "test", IndexRefresh: time.Hour, FilterTimeout: 5 * time.Second,
		FilterMax: 10, PageBytes: 4096, ArchiveStreams: 1, ZstdMaxWindow: 32 << 20}
	if mutate != nil {
		mutate(&cfg)
	}
	a, err := newApp(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return a, content
}

func get(t *testing.T, a *app, method, target string) (*http.Response, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	a.handler().ServeHTTP(rec, httptest.NewRequest(method, target, nil))
	res := rec.Result()
	body, _ := io.ReadAll(res.Body)
	return res, string(body)
}

func TestPages(t *testing.T) {
	a, _ := testApp(t, nil)
	for _, target := range []string{"/", "/?period=all&range=all", "/?period=latest&range=30", "/days", "/day/2025-01-02", "/day/2025-01-01", "/static/style.css"} {
		res, body := get(t, a, "GET", target)
		if res.StatusCode != 200 {
			t.Errorf("%s: status %d\n%s", target, res.StatusCode, body)
		}
	}
	_, body := get(t, a, "GET", "/")
	for _, want := range []string{"down01", "unreachable", "web01 / journald", "<svg"} {
		if !strings.Contains(body, want) {
			t.Errorf("dashboard lacks %q", want)
		}
	}
	_, body = get(t, a, "GET", "/day/2025-01-01")
	if !strings.Contains(body, "/extract/2025-01-01/web01/journald.log") || !strings.Contains(body, "/archive/2025-01-01.tar.zst") {
		t.Error("archived day lacks download links")
	}
}

func TestViewPaginationCoversFileExactly(t *testing.T) {
	a, content := testApp(t, nil)
	base := "/view/2025-01-02/web01/journald.log"
	var got strings.Builder
	target, pages := base, 0
	for target != "" && pages < 1000 {
		_, body := get(t, a, "GET", target)
		start := strings.Index(body, `<pre class="log">`) + len(`<pre class="log">`)
		end := strings.Index(body, "</pre>")
		got.WriteString(body[start:end])
		pages++
		target = ""
		if i := strings.Index(body, base+"?off="); i >= 0 {
			for _, part := range strings.Split(body, `href="`) {
				if strings.HasPrefix(part, base+"?off=") && strings.Contains(part, "Next") {
					target = part[:strings.Index(part, `"`)]
					break
				}
			}
		}
	}
	if got.String() != content {
		t.Fatalf("paging through the file did not reproduce it (%d pages, %d vs %d bytes)", pages, got.Len(), len(content))
	}
	if pages < 10 {
		t.Errorf("expected many pages, got %d", pages)
	}
	_, body := get(t, a, "GET", base+"?tail=1")
	if !strings.Contains(body, "generated line 005000") || strings.Contains(body, "generated line 000001\n") {
		t.Error("tail does not show the end of the file")
	}
}

func TestFilterLimitAndContinue(t *testing.T) {
	a, _ := testApp(t, nil)
	_, body := get(t, a, "GET", "/view/2025-01-02/web01/journald.log?q=needle")
	if n := strings.Count(body, "NEEDLE generated"); n != 10 {
		t.Fatalf("expected 10 matches (the limit), got %d", n)
	}
	if !strings.Contains(body, "Continue from here") {
		t.Error("no continue link after hitting the limit")
	}
	_, body = get(t, a, "GET", "/view/2025-01-02/web01/journald.log?q=%3Cscript%3E")
	if strings.Contains(body, "<script>") {
		t.Error("query is not escaped")
	}
}

func TestDownloads(t *testing.T) {
	a, content := testApp(t, nil)
	res, body := get(t, a, "GET", "/raw/2025-01-02/web01/journald.log")
	if res.StatusCode != 200 || body != content {
		t.Error("raw download differs")
	}
	res, body = get(t, a, "GET", "/extract/2025-01-01/web01/journald.log")
	if res.StatusCode != 200 || body != content {
		t.Errorf("extracted file differs (status %d)", res.StatusCode)
	}
	if res, _ = get(t, a, "GET", "/extract/2025-01-01/web01/missing.log"); res.StatusCode != 404 {
		t.Errorf("missing member: status %d", res.StatusCode)
	}
	res, body = get(t, a, "GET", "/archive/2025-01-01.tar.zst")
	if res.StatusCode != 200 || len(body) == 0 || res.Header.Get("Content-Type") != "application/zstd" {
		t.Error("whole archive download failed")
	}
}

func TestTraversalAndReadOnly(t *testing.T) {
	a, _ := testApp(t, nil)
	for _, target := range []string{
		"/raw/2025-01-02/web01/..%2F..%2F..%2F..%2F..%2Fsecret.txt",
		"/raw/2025-01-02/..%2F..%2F..%2F..%2Fsecret.txt/x",
		"/raw/2025-01-02/web01/%2e%2e",
		"/view/2025-01-02/web01/.hidden",
		"/raw/..%2F..%2F/web01/journald.log",
		"/extract/2025-01-01/web01/..%2Fdb01%2Fother.log",
		"/day/2025-13-45",
		"/archive/..%2F..%2Fsecret.txt",
	} {
		res, body := get(t, a, "GET", target)
		if res.StatusCode < 400 || strings.Contains(body, "outside") {
			t.Errorf("%s: status %d, must be refused", target, res.StatusCode)
		}
	}
	// A symlink inside the share must not lead out of it either.
	link := filepath.Join(a.cfg.DataDir, "raw/2025/01/02/web01/link.log")
	if err := os.Symlink(filepath.Join(filepath.Dir(a.cfg.DataDir), "secret.txt"), link); err == nil {
		res, body := get(t, a, "GET", "/raw/2025-01-02/web01/link.log")
		if res.StatusCode == 200 || strings.Contains(body, "outside") {
			t.Error("symlink escaped the data directory")
		}
	}
	for _, method := range []string{"POST", "PUT", "DELETE", "PATCH"} {
		if res, _ := get(t, a, method, "/raw/2025-01-02/web01/journald.log"); res.StatusCode != http.StatusMethodNotAllowed {
			t.Errorf("%s: status %d, want 405", method, res.StatusCode)
		}
	}
}

func TestHealthAndAuth(t *testing.T) {
	hash, _ := bcrypt.GenerateFromPassword([]byte("generated-test-password"), bcrypt.MinCost)
	authFile := filepath.Join(t.TempDir(), "htpasswd")
	write(t, authFile, "logcollector:"+string(hash)+"\n")
	a, _ := testApp(t, func(c *config) { c.AuthFile = authFile })

	res, body := get(t, a, "GET", "/healthz")
	if res.StatusCode != 200 || !strings.Contains(body, `"latest_day":"2025-01-02"`) {
		t.Errorf("healthz: %d %s", res.StatusCode, body)
	}
	if res, _ = get(t, a, "GET", "/"); res.StatusCode != 401 {
		t.Errorf("no credentials: status %d, want 401", res.StatusCode)
	}
	for pass, want := range map[string]int{"generated-test-password": 200, "wrong": 401} {
		req := httptest.NewRequest("GET", "/", nil)
		req.SetBasicAuth("logcollector", pass)
		rec := httptest.NewRecorder()
		a.handler().ServeHTTP(rec, req)
		if rec.Code != want {
			t.Errorf("password %q: status %d, want %d", pass, rec.Code, want)
		}
	}
	if _, err := loadBasicAuth(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Error("a missing auth file must stop the start")
	}
}
