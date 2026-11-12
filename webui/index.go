package main

import (
	"context"
	"encoding/json"
	"io/fs"
	"log"
	"os"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Manifest types mirror the JSON written by the collector (manifest v1).

type Source struct {
	Name     string `json:"name"`
	File     string `json:"file"`
	Bytes    int64  `json:"bytes"`
	Lines    int64  `json:"lines"`
	Errors   int64  `json:"errors"`
	Warnings int64  `json:"warnings"`
	OK       bool   `json:"ok"`
	Msg      string `json:"msg"`
}

type Host struct {
	Status  string   `json:"status"` // ok | partial | failed
	Origin  string   `json:"origin"` // ansible | push | syslog
	Error   string   `json:"error"`
	Sources []Source `json:"sources"`
}

type manifest struct {
	Version int             `json:"version"`
	Day     string          `json:"day"`
	Hosts   map[string]Host `json:"hosts"`
}

// DayInfo is the aggregated view of one day.
type DayInfo struct {
	Day          string
	HasManifest  bool
	HasRaw       bool
	ArchiveBytes int64 // -1 when there is no archive file
	Bytes        int64
	Lines        int64
	Errors       int64
	Warnings     int64
	HostsOK      int
	Problems     []string // hosts with status != ok
	Hosts        map[string]Host
}

// State is raw, archived or expired (only the manifest is left).
func (d *DayInfo) State() string {
	switch {
	case d.HasRaw:
		return "raw"
	case d.ArchiveBytes >= 0:
		return "archived"
	default:
		return "expired"
	}
}

func (d *DayInfo) HostNames() []string {
	names := make([]string, 0, len(d.Hosts))
	for n := range d.Hosts {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Index is an immutable snapshot; a rebuild swaps in a new one.
type Index struct {
	Days         []*DayInfo // ascending by day
	byDay        map[string]*DayInfo
	Built        time.Time
	RawBytes     int64
	RawDays      int
	ArchiveBytes int64
	ArchiveDays  int
	ArchivedOrig int64 // uncompressed bytes of archived days
	TotalBytes   int64
	TotalLines   int64
	Err          string
}

func (ix *Index) Day(day string) *DayInfo { return ix.byDay[day] }

func (ix *Index) Latest() *DayInfo {
	for i := len(ix.Days) - 1; i >= 0; i-- {
		if ix.Days[i].HasManifest {
			return ix.Days[i]
		}
	}
	return nil
}

type cachedManifest struct {
	mod  time.Time
	size int64
	day  *DayInfo
}

type indexer struct {
	dataDir string
	mu      sync.RWMutex
	cur     *Index
	cache   map[string]cachedManifest
	kick    chan struct{}
}

func newIndexer(dataDir string) *indexer {
	ix := &indexer{dataDir: dataDir, cache: map[string]cachedManifest{}, kick: make(chan struct{}, 1)}
	ix.cur = &Index{byDay: map[string]*DayInfo{}}
	ix.rebuild()
	return ix
}

func (ix *indexer) get() *Index {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	return ix.cur
}

// run refreshes the index periodically. Manifests that did not change
// (same mtime and size) are not parsed again, so a refresh costs a few
// directory listings.
func (ix *indexer) run(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-ix.kick:
		}
		ix.rebuild()
	}
}

var (
	dayRe  = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	yearRe = regexp.MustCompile(`^\d{4}$`)
	twoRe  = regexp.MustCompile(`^\d{2}$`)
)

func validDay(day string) bool {
	if !dayRe.MatchString(day) {
		return false
	}
	_, err := time.Parse("2006-01-02", day)
	return err == nil
}

func readDir(fsys fs.FS, name string) []fs.DirEntry {
	entries, err := fs.ReadDir(fsys, name)
	if err != nil {
		return nil
	}
	return entries
}

func (ix *indexer) rebuild() {
	next := &Index{byDay: map[string]*DayInfo{}, Built: time.Now()}
	root, err := os.OpenRoot(ix.dataDir) // reopened every time: follows late mounts
	if err != nil {
		next.Err = "data directory is not readable"
		ix.mu.Lock()
		ix.cur = next
		ix.mu.Unlock()
		return
	}
	defer root.Close()
	fsys := root.FS()
	if _, err := fs.ReadDir(fsys, "."); err != nil {
		next.Err = "data directory is not readable"
	}
	seen := map[string]bool{}
	day := func(name string) *DayInfo {
		d := next.byDay[name]
		if d == nil {
			d = &DayInfo{Day: name, ArchiveBytes: -1}
			next.byDay[name] = d
		}
		return d
	}

	// manifests/YYYY/YYYY-MM-DD.json
	for _, y := range readDir(fsys, "manifests") {
		if !y.IsDir() || !yearRe.MatchString(y.Name()) {
			continue
		}
		for _, e := range readDir(fsys, "manifests/"+y.Name()) {
			name := strings.TrimSuffix(e.Name(), ".json")
			if e.IsDir() || name == e.Name() || !validDay(name) {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			p := "manifests/" + y.Name() + "/" + e.Name()
			seen[p] = true
			c, ok := ix.cache[p]
			if !ok || !c.mod.Equal(info.ModTime()) || c.size != info.Size() {
				parsed, err := parseManifest(fsys, p, name)
				if err != nil {
					log.Printf("index: skipping %s: %v", p, err)
					continue
				}
				c = cachedManifest{mod: info.ModTime(), size: info.Size(), day: parsed}
				ix.cache[p] = c
			}
			cp := *c.day // copy, state fields are set below
			next.byDay[name] = &cp
		}
	}
	for p := range ix.cache {
		if !seen[p] {
			delete(ix.cache, p)
		}
	}

	// archive/YYYY/YYYY-MM-DD.tar.zst
	for _, y := range readDir(fsys, "archive") {
		if !y.IsDir() || !yearRe.MatchString(y.Name()) {
			continue
		}
		for _, e := range readDir(fsys, "archive/"+y.Name()) {
			name := strings.TrimSuffix(e.Name(), ".tar.zst")
			if e.IsDir() || name == e.Name() || !validDay(name) {
				continue
			}
			if info, err := e.Info(); err == nil {
				day(name).ArchiveBytes = info.Size()
			}
		}
	}

	// raw/YYYY/MM/DD/
	for _, y := range readDir(fsys, "raw") {
		if !y.IsDir() || !yearRe.MatchString(y.Name()) {
			continue
		}
		for _, m := range readDir(fsys, "raw/"+y.Name()) {
			if !m.IsDir() || !twoRe.MatchString(m.Name()) {
				continue
			}
			for _, d := range readDir(fsys, "raw/"+y.Name()+"/"+m.Name()) {
				name := y.Name() + "-" + m.Name() + "-" + d.Name()
				if d.IsDir() && validDay(name) {
					day(name).HasRaw = true
				}
			}
		}
	}

	for _, d := range next.byDay {
		next.Days = append(next.Days, d)
		next.TotalBytes += d.Bytes
		next.TotalLines += d.Lines
		if d.HasRaw {
			next.RawBytes += d.Bytes
			next.RawDays++
		}
		if d.ArchiveBytes >= 0 {
			next.ArchiveBytes += d.ArchiveBytes
			next.ArchiveDays++
			next.ArchivedOrig += d.Bytes
		}
	}
	sort.Slice(next.Days, func(i, j int) bool { return next.Days[i].Day < next.Days[j].Day })

	ix.mu.Lock()
	ix.cur = next
	ix.mu.Unlock()
}

func parseManifest(fsys fs.FS, p, day string) (*DayInfo, error) {
	f, err := fsys.Open(p)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var m manifest
	if err := json.NewDecoder(f).Decode(&m); err != nil {
		return nil, err
	}
	d := &DayInfo{Day: day, HasManifest: true, ArchiveBytes: -1, Hosts: m.Hosts}
	for name, h := range m.Hosts {
		if h.Status == "ok" {
			d.HostsOK++
		} else {
			d.Problems = append(d.Problems, name)
		}
		for _, s := range h.Sources {
			d.Bytes += s.Bytes
			d.Lines += s.Lines
			d.Errors += s.Errors
			d.Warnings += s.Warnings
		}
	}
	sort.Strings(d.Problems)
	return d, nil
}

// diskFree returns free and total bytes of the filesystem holding dir.
func diskFree(dir string) (free, total int64, ok bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), int64(st.Blocks) * int64(st.Bsize), true
}
