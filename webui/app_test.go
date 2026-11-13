package main

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
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
		FilterMax: 10, PageBytes: 4096, ArchiveStreams: 1, ZipStreams: 2, ZstdMaxWindow: 32 << 20}
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

// zipEntries downloads a zip and returns name -> content.
func zipEntries(t *testing.T, a *app, target string) (map[string]string, *http.Response) {
	t.Helper()
	res, body := get(t, a, "GET", target)
	if res.StatusCode != 200 {
		return nil, res
	}
	zr, err := zip.NewReader(bytes.NewReader([]byte(body)), int64(len(body)))
	if err != nil {
		t.Fatalf("%s: not a valid zip: %v", target, err)
	}
	out := map[string]string{}
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		b, err := io.ReadAll(rc) // also verifies the CRC
		rc.Close()
		if err != nil {
			t.Fatalf("%s: reading %s: %v", target, f.Name, err)
		}
		out[f.Name] = string(b)
	}
	return out, res
}

func TestZipRawDay(t *testing.T) {
	a, content := testApp(t, nil)
	other := "second host line\n"
	write(t, a.cfg.DataDir+"/raw/2025/01/02/web01/docker-app.log", "docker line\n")
	write(t, a.cfg.DataDir+"/raw/2025/01/02/db01/journald.log", other)

	all, res := zipEntries(t, a, "/zip/2025-01-02")
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "application/zip" ||
		!strings.Contains(res.Header.Get("Content-Disposition"), `filename="logs-2025-01-02.zip"`) {
		t.Fatalf("download all: status %d, headers %v", res.StatusCode, res.Header)
	}
	want := map[string]string{
		"2025-01-02/web01/journald.log":   content,
		"2025-01-02/web01/docker-app.log": "docker line\n",
		"2025-01-02/db01/journald.log":    other,
	}
	if len(all) != len(want) {
		t.Fatalf("download all: got %d entries, want %d: %v", len(all), len(want), keys(all))
	}
	for n, c := range want {
		if all[n] != c {
			t.Errorf("download all: %s differs", n)
		}
	}

	// two files out of three
	sel, res := zipEntries(t, a, "/zip/2025-01-02?sel=1&f=web01/docker-app.log&f=db01/journald.log")
	if res.StatusCode != 200 || len(sel) != 2 || sel["2025-01-02/db01/journald.log"] != other ||
		!strings.Contains(res.Header.Get("Content-Disposition"), "selected") {
		t.Errorf("selection: status %d, entries %v", res.StatusCode, keys(sel))
	}
	// a whole host
	hostOnly, _ := zipEntries(t, a, "/zip/2025-01-02?h=web01")
	if len(hostOnly) != 2 || hostOnly["2025-01-02/db01/journald.log"] != "" {
		t.Errorf("host selection: %v", keys(hostOnly))
	}
	// a missing file is reported inside the zip, existing ones are delivered
	partial, _ := zipEntries(t, a, "/zip/2025-01-02?f=db01/journald.log&f=db01/gone.log")
	if !strings.Contains(partial["2025-01-02/MISSING.txt"], "db01/gone.log") || partial["2025-01-02/db01/journald.log"] != other {
		t.Errorf("missing file not reported: %v", keys(partial))
	}
	if _, res = zipEntries(t, a, "/zip/2025-01-02?f=db01/gone.log"); res.StatusCode != 404 {
		t.Errorf("only missing files: status %d, want 404", res.StatusCode)
	}
	// HEAD does not stream
	if res, body := get(t, a, "HEAD", "/zip/2025-01-02"); res.StatusCode != 200 || body != "" {
		t.Errorf("HEAD: status %d, body %d bytes", res.StatusCode, len(body))
	}
}

func TestZipArchivedDay(t *testing.T) {
	a, content := testApp(t, nil)
	all, res := zipEntries(t, a, "/zip/2025-01-01")
	if res.StatusCode != 200 || len(all) != 2 || all["2025-01-01/db01/other.log"] != content || all["2025-01-01/web01/journald.log"] != content {
		t.Fatalf("archived day, all: status %d, entries %v", res.StatusCode, keys(all))
	}
	one, _ := zipEntries(t, a, "/zip/2025-01-01?sel=1&f=db01/other.log")
	if len(one) != 1 || one["2025-01-01/db01/other.log"] != content {
		t.Errorf("archived selection: %v", keys(one))
	}
	host, _ := zipEntries(t, a, "/zip/2025-01-01?h=web01")
	if len(host) != 1 || host["2025-01-01/web01/journald.log"] != content {
		t.Errorf("archived host selection: %v", keys(host))
	}
	part, _ := zipEntries(t, a, "/zip/2025-01-01?f=db01/other.log&f=db01/gone.log")
	if !strings.Contains(part["2025-01-01/MISSING.txt"], "db01/gone.log") || part["2025-01-01/db01/other.log"] != content {
		t.Errorf("archived: missing file not reported: %v", keys(part))
	}
	if _, res = zipEntries(t, a, "/zip/2025-01-01?f=nope/nope.log"); res.StatusCode != 404 {
		t.Errorf("archived, nothing found: status %d, want 404", res.StatusCode)
	}
	if _, res = zipEntries(t, a, "/zip/2024-12-31"); res.StatusCode != 404 {
		t.Errorf("unknown day: status %d, want 404", res.StatusCode)
	}
}

func TestZipRejectsBadInput(t *testing.T) {
	a, _ := testApp(t, nil)
	for _, target := range []string{
		"/zip/2025-01-02?sel=1",                    // nothing selected
		"/zip/2025-01-02?f=",                       // empty value
		"/zip/2025-01-02?f=web01",                  // no file part
		"/zip/2025-01-02?f=../secret.txt",          // traversal
		"/zip/2025-01-02?f=web01/../../secret.txt", // traversal
		"/zip/2025-01-02?f=web01/sub/journald.log", // extra path part
		"/zip/2025-01-02?f=%2e%2e/%2e%2e",          // encoded traversal
		"/zip/2025-01-02?h=..",                     // bad host
		"/zip/2025-01-02?h=web01%2f..%2f..",        // bad host
		"/zip/..%2f..%2fetc",                       // bad day
		"/zip/2025-13-40",                          // bad day
	} {
		res, body := get(t, a, "GET", target)
		if res.StatusCode != 400 || strings.Contains(body, "outside") {
			t.Errorf("%s: status %d, want 400 from the input validation", target, res.StatusCode)
		}
	}
	// too many picks
	var q strings.Builder
	for i := 0; i <= maxZipPicks; i++ {
		fmt.Fprintf(&q, "&f=web01/f%d.log", i)
	}
	if res, _ := get(t, a, "GET", "/zip/2025-01-02?x=1"+q.String()); res.StatusCode != 400 {
		t.Errorf("too many files: status %d, want 400", res.StatusCode)
	}
	// a symlink in a raw day must not leak a file from outside
	link := filepath.Join(a.cfg.DataDir, "raw/2025/01/02/web01/link.log")
	if err := os.Symlink(filepath.Join(filepath.Dir(a.cfg.DataDir), "secret.txt"), link); err == nil {
		all, _ := zipEntries(t, a, "/zip/2025-01-02")
		for n, c := range all {
			if strings.Contains(c, "outside") {
				t.Errorf("symlinked file leaked into the zip as %s", n)
			}
		}
		explicit, _ := zipEntries(t, a, "/zip/2025-01-02?f=web01/link.log&f=web01/journald.log")
		for n, c := range explicit {
			if strings.Contains(c, "outside") {
				t.Errorf("explicit symlink leaked as %s", n)
			}
		}
	}
	if res, _ := get(t, a, "POST", "/zip/2025-01-02"); res.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("POST: status %d, want 405", res.StatusCode)
	}
}

func TestDayPageOffersZip(t *testing.T) {
	a, _ := testApp(t, nil)
	for _, day := range []string{"2025-01-02", "2025-01-01"} {
		_, body := get(t, a, "GET", "/day/"+day)
		for _, want := range []string{`href="/zip/` + day + `"`, `name="f" value="web01/journald.log"`, `/static/select.js`, `name="sel"`} {
			if !strings.Contains(body, want) {
				t.Errorf("%s: day page lacks %q", day, want)
			}
		}
	}
	res, _ := get(t, a, "GET", "/static/select.js")
	if res.StatusCode != 200 || !strings.Contains(res.Header.Get("Content-Security-Policy"), "script-src 'self'") {
		t.Errorf("select.js not served or CSP lacks script-src 'self'")
	}
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
