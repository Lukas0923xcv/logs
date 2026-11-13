package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed templates/*.html static/*
var assets embed.FS

type app struct {
	cfg     config
	index   *indexer
	auth    *basicAuth
	tpl     map[string]*template.Template
	extract chan struct{} // limits concurrent archive decompression
	zips    chan struct{} // limits concurrent zip downloads of raw days
}

func newApp(cfg config) (*app, error) {
	if info, err := os.Stat(cfg.DataDir); err != nil || !info.IsDir() {
		return nil, fmt.Errorf("data directory %s does not exist (LOGS_DATA_DIR)", cfg.DataDir)
	}
	a := &app{cfg: cfg, extract: make(chan struct{}, max(cfg.ArchiveStreams, 1)), zips: make(chan struct{}, max(cfg.ZipStreams, 1))}
	if cfg.AuthFile != "" {
		var err error
		if a.auth, err = loadBasicAuth(cfg.AuthFile); err != nil {
			return nil, err
		}
	}
	funcs := template.FuncMap{
		"bytes": humanBytes,
		"num":   groupDigits,
		"pct":   func(f float64) string { return fmt.Sprintf("%.1f%%", f) },
		"signedBytes": func(v int64) string {
			if v > 0 {
				return "+" + humanBytes(v)
			}
			return humanBytes(v)
		},
		"signedPct": func(f float64) string { return fmt.Sprintf("%+.0f%%", f) },
	}
	a.tpl = map[string]*template.Template{}
	for _, page := range []string{"dashboard", "days", "day", "view", "filter", "error"} {
		a.tpl[page] = template.Must(template.New(page).Funcs(funcs).ParseFS(assets,
			"templates/layout.html", "templates/"+page+".html"))
	}
	a.index = newIndexer(cfg.DataDir)
	return a, nil
}

func (a *app) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", a.dashboard)
	mux.HandleFunc("GET /days", a.days)
	mux.HandleFunc("GET /day/{day}", a.day)
	mux.HandleFunc("GET /view/{day}/{host}/{file}", a.view)
	mux.HandleFunc("GET /raw/{day}/{host}/{file}", a.downloadRaw)
	mux.HandleFunc("GET /archive/{day}", a.downloadArchive)
	mux.HandleFunc("GET /zip/{day}", a.downloadZip)
	mux.HandleFunc("GET /extract/{day}/{host}/{file}", a.extractFile)
	mux.HandleFunc("GET /healthz", a.healthz)
	static, _ := fs.Sub(assets, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServerFS(static)))
	return a.middleware(mux)
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (a *app) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: 200}
		h := sw.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("Cache-Control", "no-store")

		switch {
		case r.Method != http.MethodGet && r.Method != http.MethodHead:
			// The UI is read-only: nothing but GET and HEAD exists.
			h.Set("Allow", "GET, HEAD")
			http.Error(sw, "method not allowed", http.StatusMethodNotAllowed)
		case a.auth != nil && r.URL.Path != "/healthz" && !a.auth.check(r):
			h.Set("WWW-Authenticate", `Basic realm="logs", charset="UTF-8"`)
			http.Error(sw, "authentication required", http.StatusUnauthorized)
		default:
			next.ServeHTTP(sw, r)
		}
		if r.URL.Path != "/healthz" && !strings.HasPrefix(r.URL.Path, "/static/") {
			// Query strings are not logged: they can contain search terms.
			log.Printf("%s %s %d %s", r.Method, r.URL.Path, sw.status, time.Since(start).Round(time.Millisecond))
		}
	})
}

type page struct {
	Title   string
	Site    string
	Version string
	Nav     string
	Data    any
}

func (a *app) render(w http.ResponseWriter, status int, name, title, nav string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	p := page{Title: title, Site: a.cfg.Title, Version: version, Nav: nav, Data: data}
	if err := a.tpl[name].ExecuteTemplate(w, "page", p); err != nil {
		log.Printf("render %s: %v", name, err)
	}
}

func (a *app) fail(w http.ResponseWriter, status int, msg string) {
	a.render(w, status, "error", http.StatusText(status), "", map[string]any{"Status": status, "Message": msg})
}

// ---- path handling ----

// open opens a file below the data directory. The directory is opened anew
// for every request, so a share that gets mounted after the UI started is
// picked up. os.Root refuses every path that would leave the directory,
// including through symlinks.
func (a *app) open(name string) (*os.File, error) {
	root, err := os.OpenRoot(a.cfg.DataDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	return root.Open(name)
}

func (a *app) readDir(name string) []fs.DirEntry {
	root, err := os.OpenRoot(a.cfg.DataDir)
	if err != nil {
		return nil
	}
	defer root.Close()
	return readDir(root.FS(), name)
}

// nameRe is the only shape of host and file names the UI will open. The
// collector sanitises names to this alphabet. os.Root additionally stops
// any path (including symlinks) from leaving the data directory.
var nameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._@+-]{0,200}$`)

func validName(s string) bool { return nameRe.MatchString(s) && !strings.Contains(s, "..") }

func rawDir(day string) string { return "raw/" + day[0:4] + "/" + day[5:7] + "/" + day[8:10] }

func archivePath(day string) string { return "archive/" + day[0:4] + "/" + day + ".tar.zst" }

// pathArgs validates the {day}/{host}/{file} URL parts.
func (a *app) pathArgs(w http.ResponseWriter, r *http.Request) (day, host, file string, ok bool) {
	day, host, file = r.PathValue("day"), r.PathValue("host"), r.PathValue("file")
	if !validDay(day) || !validName(host) || !validName(file) {
		a.fail(w, http.StatusBadRequest, "Invalid day, host or file name.")
		return "", "", "", false
	}
	return day, host, file, true
}

// ---- pages ----

type tile struct {
	Label string
	Value string
	Note  string
}

func (a *app) dashboard(w http.ResponseWriter, r *http.Request) {
	ix := a.index.get()
	period := r.URL.Query().Get("period")
	if period != "latest" && period != "30d" && period != "all" {
		period = "7d"
	}
	rng := 90
	switch r.URL.Query().Get("range") {
	case "30":
		rng = 30
	case "365":
		rng = 365
	case "all":
		rng = 0
	}
	days := periodDays(ix, period)

	tiles := []tile{
		{"Raw logs", humanBytes(ix.RawBytes), fmt.Sprintf("%d day(s), uncompressed", ix.RawDays)},
	}
	note := fmt.Sprintf("%d archive(s)", ix.ArchiveDays)
	if ix.ArchiveBytes > 0 && ix.ArchivedOrig > 0 {
		note += fmt.Sprintf(", %.1fx smaller than raw", float64(ix.ArchivedOrig)/float64(ix.ArchiveBytes))
	}
	tiles = append(tiles, tile{"Archives", humanBytes(ix.ArchiveBytes), note})
	if free, total, ok := diskFree(a.cfg.DataDir); ok && total > 0 {
		tiles = append(tiles, tile{"Free on share", humanBytes(free),
			fmt.Sprintf("%.0f%% of %s", float64(free)*100/float64(total), humanBytes(total))})
	} else {
		tiles = append(tiles, tile{"Free on share", "unknown", "share not readable"})
	}
	if l := ix.Latest(); l != nil {
		note := fmt.Sprintf("%d host(s) ok", l.HostsOK)
		if len(l.Problems) > 0 {
			note += fmt.Sprintf(", %d with problems", len(l.Problems))
		}
		tiles = append(tiles, tile{"Latest day", l.Day, note + ", " + humanBytes(l.Bytes)})
	} else {
		tiles = append(tiles, tile{"Latest day", "none", "no manifest found yet"})
	}
	tiles = append(tiles, tile{"Collected in total", humanBytes(ix.TotalBytes), groupDigits(ix.TotalLines) + " lines"})

	a.render(w, 200, "dashboard", "Overview", "overview", map[string]any{
		"Tiles":    tiles,
		"Chart":    buildChart(ix, rng),
		"Range":    r.URL.Query().Get("range"),
		"Period":   period,
		"Hosts":    rank(days, false, 50),
		"Services": rank(days, true, 50),
		"Growth":   growth(ix, 25),
		"Failures": failures(ix, 30),
		"Built":    ix.Built.Format("2006-01-02 15:04:05 MST"),
		"IndexErr": ix.Err,
	})
}

func (a *app) days(w http.ResponseWriter, r *http.Request) {
	ix := a.index.get()
	yearSet := map[string]bool{}
	for _, d := range ix.Days {
		yearSet[d.Day[:4]] = true
	}
	years := make([]string, 0, len(yearSet))
	for y := range yearSet {
		years = append(years, y)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(years)))
	year := r.URL.Query().Get("year")
	if !yearSet[year] && len(years) > 0 {
		year = years[0]
	}
	var rows []*DayInfo
	for i := len(ix.Days) - 1; i >= 0; i-- {
		if ix.Days[i].Day[:4] == year {
			rows = append(rows, ix.Days[i])
		}
	}
	a.render(w, 200, "days", "Days", "days", map[string]any{"Years": years, "Year": year, "Days": rows})
}

type fileRow struct {
	Name     string
	Source   string
	Bytes    int64
	Lines    int64
	Errors   int64
	Warnings int64
	HasStats bool
	Failed   bool
	Msg      string
}

type hostRow struct {
	Name   string
	Status string
	Origin string
	Error  string
	Files  []fileRow
}

func (a *app) day(w http.ResponseWriter, r *http.Request) {
	day := r.PathValue("day")
	if !validDay(day) {
		a.fail(w, http.StatusBadRequest, "Invalid day.")
		return
	}
	d := a.index.get().Day(day)
	if d == nil {
		a.fail(w, http.StatusNotFound, "Nothing is stored for "+day+".")
		return
	}
	hosts := map[string]*hostRow{}
	for name, h := range d.Hosts {
		row := &hostRow{Name: name, Status: h.Status, Origin: h.Origin, Error: h.Error}
		for _, s := range h.Sources {
			row.Files = append(row.Files, fileRow{Name: s.File, Source: s.Name, Bytes: s.Bytes, Lines: s.Lines,
				Errors: s.Errors, Warnings: s.Warnings, HasStats: true, Failed: !s.OK, Msg: s.Msg})
		}
		hosts[name] = row
	}
	if d.HasRaw {
		// Show what is really on disk; the manifest only adds the statistics.
		for _, he := range a.readDir(rawDir(day)) {
			if !he.IsDir() || !validName(he.Name()) {
				continue
			}
			row := hosts[he.Name()]
			if row == nil {
				row = &hostRow{Name: he.Name(), Status: "unlisted"}
				hosts[he.Name()] = row
			}
			known := map[string]bool{}
			for _, f := range row.Files {
				known[f.Name] = true
			}
			for _, fe := range a.readDir(rawDir(day) + "/" + he.Name()) {
				if fe.IsDir() || !validName(fe.Name()) || known[fe.Name()] {
					continue
				}
				fr := fileRow{Name: fe.Name(), Source: strings.TrimSuffix(fe.Name(), ".log")}
				if info, err := fe.Info(); err == nil {
					fr.Bytes = info.Size()
				}
				row.Files = append(row.Files, fr)
			}
		}
	}
	rows := make([]*hostRow, 0, len(hosts))
	for _, h := range hosts {
		sort.Slice(h.Files, func(i, j int) bool { return h.Files[i].Name < h.Files[j].Name })
		rows = append(rows, h)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Name < rows[j].Name })
	ix := a.index.get()
	a.render(w, 200, "day", day, "days", map[string]any{
		"Day": d, "Hosts": rows, "Prev": neighbour(ix, day, -1), "Next": neighbour(ix, day, 1),
		"CanZip": d.HasRaw || d.ArchiveBytes >= 0,
	})
}

func neighbour(ix *Index, day string, dir int) string {
	i := sort.Search(len(ix.Days), func(i int) bool { return ix.Days[i].Day >= day }) + dir
	if i < 0 || i >= len(ix.Days) {
		return ""
	}
	return ix.Days[i].Day
}

func (a *app) downloadRaw(w http.ResponseWriter, r *http.Request) {
	day, host, file, ok := a.pathArgs(w, r)
	if !ok {
		return
	}
	f, err := a.open(rawDir(day) + "/" + host + "/" + file)
	if err != nil {
		a.fail(w, http.StatusNotFound, "This file is not available as a raw log (it may be archived).")
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		a.fail(w, http.StatusNotFound, "Not a file.")
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_%s_%s"`, day, host, file))
	http.ServeContent(w, r, "", info.ModTime(), f) // streams, supports Range
}

func (a *app) downloadArchive(w http.ResponseWriter, r *http.Request) {
	day := strings.TrimSuffix(r.PathValue("day"), ".tar.zst")
	if !validDay(day) {
		a.fail(w, http.StatusBadRequest, "Invalid day.")
		return
	}
	f, err := a.open(archivePath(day))
	if err != nil {
		a.fail(w, http.StatusNotFound, "There is no archive for "+day+".")
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		a.fail(w, http.StatusNotFound, "There is no archive for "+day+".")
		return
	}
	w.Header().Set("Content-Type", "application/zstd")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s.tar.zst"`, day))
	http.ServeContent(w, r, "", info.ModTime(), f)
}

func (a *app) healthz(w http.ResponseWriter, r *http.Request) {
	ix := a.index.get()
	_, err := os.ReadDir(a.cfg.DataDir)
	out := map[string]any{
		"status":            "ok",
		"version":           version,
		"data_dir_readable": err == nil,
		"days":              len(ix.Days),
		"index_age_seconds": int(time.Since(ix.Built).Seconds()),
	}
	if l := ix.Latest(); l != nil {
		out["latest_day"] = l.Day
		out["latest_day_problem_hosts"] = len(l.Problems)
	}
	status := http.StatusOK
	if err != nil {
		out["status"] = "error"
		status = http.StatusServiceUnavailable
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(out)
}

func queryInt(r *http.Request, key string) int64 {
	n, err := strconv.ParseInt(r.URL.Query().Get(key), 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}
