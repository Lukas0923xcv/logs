package main

import (
	"archive/tar"
	"archive/zip"
	"compress/flate"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"path"
	"runtime/debug"
	"sort"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
)

// Zip downloads: one day, all files or a selection, streamed.
//
//	/zip/{day}                       everything stored for the day
//	/zip/{day}?f=host/file&f=...     selected files
//	/zip/{day}?h=host                all files of a host
//	/zip/{day}?sel=1                 a form submit: refuses an empty selection
//
// The zip is written while the files are read, so memory use does not depend
// on the size of the day. Raw days are read from raw/, archived days from the
// .tar.zst (decompressed once, sequentially).

const maxZipPicks = 2000

type zipSel struct {
	all   bool
	hosts map[string]bool
	files map[string]bool // "host/file"
}

func (s zipSel) matches(host, file string) bool {
	return s.all || s.hosts[host] || s.files[host+"/"+file]
}

// explicitOnly reports a selection of single files only, which lets an
// archive scan stop as soon as every one of them has been found.
func (s zipSel) explicitOnly() bool { return !s.all && len(s.hosts) == 0 }

func parseZipSel(r *http.Request) (zipSel, error) {
	q := r.URL.Query()
	fs, hs := q["f"], q["h"]
	if len(fs)+len(hs) > maxZipPicks {
		return zipSel{}, fmt.Errorf("too many files selected (the limit is %d); download whole hosts or the whole day instead", maxZipPicks)
	}
	sel := zipSel{hosts: map[string]bool{}, files: map[string]bool{}}
	for _, h := range hs {
		if !validName(h) {
			return zipSel{}, errors.New("invalid host name in the selection")
		}
		sel.hosts[h] = true
	}
	for _, f := range fs {
		host, file, ok := strings.Cut(f, "/")
		if !ok || !validName(host) || !validName(file) {
			return zipSel{}, errors.New("invalid file in the selection")
		}
		sel.files[host+"/"+file] = true
	}
	if len(fs)+len(hs) == 0 {
		if q.Has("sel") {
			return zipSel{}, errors.New("nothing is selected. Tick at least one source, or use \"Download all\"")
		}
		sel.all = true
	}
	return sel, nil
}

func newZipWriter(w io.Writer) *zip.Writer {
	zw := zip.NewWriter(w)
	// Fast deflate: logs compress well, and the CPU quota is small.
	zw.RegisterCompressor(zip.Deflate, func(out io.Writer) (io.WriteCloser, error) {
		return flate.NewWriter(out, flate.BestSpeed)
	})
	return zw
}

func writeZipEntry(zw *zip.Writer, name string, mod time.Time, src io.Reader) error {
	hw, err := zw.CreateHeader(&zip.FileHeader{Name: name, Method: zip.Deflate, Modified: mod})
	if err != nil {
		return err
	}
	_, err = io.Copy(hw, src)
	return err
}

func zipHeaders(w http.ResponseWriter, filename string) {
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s"`, filename))
}

// abortStream ends a response whose body has already started and cannot be
// completed. Panicking with ErrAbortHandler closes the connection, so the
// browser reports a failed download instead of saving a truncated zip.
func abortStream(what string, err error) {
	log.Printf("zip %s: %v", what, err)
	panic(http.ErrAbortHandler)
}

// acquire takes a slot of a concurrency limiter, waiting a little.
func (a *app) acquire(w http.ResponseWriter, r *http.Request, slots chan struct{}) (release func(), ok bool) {
	wait := time.NewTimer(20 * time.Second)
	defer wait.Stop()
	select {
	case slots <- struct{}{}:
		return func() { <-slots }, true
	case <-r.Context().Done():
		return nil, false
	case <-wait.C:
		w.Header().Set("Retry-After", "30")
		a.fail(w, http.StatusServiceUnavailable, "Other zip or archive downloads are running. Try again in a moment.")
		return nil, false
	}
}

func (a *app) downloadZip(w http.ResponseWriter, r *http.Request) {
	day := r.PathValue("day")
	if !validDay(day) {
		a.fail(w, http.StatusBadRequest, "Invalid day.")
		return
	}
	sel, err := parseZipSel(r)
	if err != nil {
		a.fail(w, http.StatusBadRequest, "The selection is not valid: "+err.Error()+".")
		return
	}
	name := "logs-" + day
	if !sel.all {
		name += "-selected"
	}
	name += ".zip"

	// Decide by what is on disk, not by the (possibly stale) index.
	if len(a.readDir(rawDir(day))) > 0 {
		a.zipRaw(w, r, day, name, sel)
		return
	}
	if f, err := a.open(archivePath(day)); err == nil {
		f.Close()
		a.zipArchive(w, r, day, name, sel)
		return
	}
	a.fail(w, http.StatusNotFound, "No log files are stored for "+day+" (only statistics may remain).")
}

type zipItem struct {
	host, file string
	mod        time.Time
}

// resolveRaw lists the files of a raw day that the selection covers, and the
// selected names that do not exist.
func (a *app) resolveRaw(day string, sel zipSel) (items []zipItem, missing []string) {
	hostSet := map[string]bool{}
	if sel.all {
		for _, e := range a.readDir(rawDir(day)) {
			if e.IsDir() && validName(e.Name()) {
				hostSet[e.Name()] = true
			}
		}
	}
	for h := range sel.hosts {
		hostSet[h] = true
	}
	for f := range sel.files {
		host, _, _ := strings.Cut(f, "/")
		hostSet[host] = true
	}
	hosts := make([]string, 0, len(hostSet))
	for h := range hostSet {
		hosts = append(hosts, h)
	}
	sort.Strings(hosts)
	for _, host := range hosts {
		entries := a.readDir(rawDir(day) + "/" + host)
		present := map[string]time.Time{}
		for _, e := range entries {
			if !e.Type().IsRegular() || !validName(e.Name()) {
				continue
			}
			var mod time.Time
			if info, err := e.Info(); err == nil {
				mod = info.ModTime()
			}
			present[e.Name()] = mod
		}
		names := make([]string, 0, len(present))
		for n := range present {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			if sel.matches(host, n) {
				items = append(items, zipItem{host, n, present[n]})
			}
		}
		if sel.hosts[host] && len(present) == 0 {
			missing = append(missing, host+"/ (no files)")
		}
		for f := range sel.files {
			if h, n, _ := strings.Cut(f, "/"); h == host {
				if _, ok := present[n]; !ok {
					missing = append(missing, f)
				}
			}
		}
	}
	sort.Strings(missing)
	return items, missing
}

func writeMissing(zw *zip.Writer, day string, missing []string) error {
	if len(missing) == 0 {
		return nil
	}
	text := "These selected files were not found for " + day + ":\n\n" + strings.Join(missing, "\n") + "\n"
	return writeZipEntry(zw, day+"/MISSING.txt", time.Now(), strings.NewReader(text))
}

func (a *app) zipRaw(w http.ResponseWriter, r *http.Request, day, filename string, sel zipSel) {
	items, missing := a.resolveRaw(day, sel)
	if len(items) == 0 {
		a.fail(w, http.StatusNotFound, "None of the selected files exist for "+day+".")
		return
	}
	if r.Method == http.MethodHead {
		zipHeaders(w, filename)
		return
	}
	release, ok := a.acquire(w, r, a.zips)
	if !ok {
		return
	}
	defer release()

	zipHeaders(w, filename)
	zw := newZipWriter(w)
	for _, it := range items {
		f, err := a.open(rawDir(day) + "/" + it.host + "/" + it.file)
		if err != nil {
			missing = append(missing, it.host+"/"+it.file+" (could not be opened)")
			continue
		}
		err = writeZipEntry(zw, day+"/"+it.host+"/"+it.file, it.mod, f)
		f.Close()
		if err != nil {
			abortStream(day+" "+it.host+"/"+it.file, err)
		}
	}
	if err := writeMissing(zw, day, missing); err != nil {
		abortStream(day, err)
	}
	if err := zw.Close(); err != nil {
		abortStream(day, err)
	}
}

func (a *app) zipArchive(w http.ResponseWriter, r *http.Request, day, filename string, sel zipSel) {
	if r.Method == http.MethodHead {
		zipHeaders(w, filename)
		return
	}
	f, err := a.open(archivePath(day))
	if err != nil {
		a.fail(w, http.StatusNotFound, "There is no archive for "+day+".")
		return
	}
	defer f.Close()
	release, ok := a.acquire(w, r, a.extract)
	if !ok {
		return
	}
	defer release()

	zr, err := zstd.NewReader(f,
		zstd.WithDecoderConcurrency(1),
		zstd.WithDecoderLowmem(true),
		zstd.WithDecoderMaxWindow(a.cfg.ZstdMaxWindow))
	if err != nil {
		a.fail(w, http.StatusInternalServerError, "Could not open the archive.")
		return
	}
	defer func() {
		zr.Close()
		debug.FreeOSMemory()
	}()

	tr := tar.NewReader(zr)
	var zw *zip.Writer // created with the first matching file, so early errors can still be shown
	found := map[string]bool{}
	foundHost := map[string]bool{}
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			if zw == nil {
				msg := "Could not read the archive."
				if errors.Is(err, zstd.ErrWindowSizeExceeded) || errors.Is(err, zstd.ErrDecoderSizeExceeded) {
					msg = "This archive was compressed with a larger zstd window than the web UI is allowed to use " +
						"(LOGS_ZSTD_MAX_WINDOW_MB). Download the whole archive instead."
				}
				log.Printf("zip %s: %v", day, err)
				a.fail(w, http.StatusInternalServerError, msg)
				return
			}
			abortStream(day, err)
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		clean := path.Clean(strings.TrimPrefix(hdr.Name, "./"))
		host, file, ok := strings.Cut(clean, "/")
		if !ok || !validName(host) || !validName(file) || !sel.matches(host, file) {
			continue
		}
		if zw == nil {
			zipHeaders(w, filename)
			zw = newZipWriter(w)
		}
		if err := writeZipEntry(zw, day+"/"+clean, hdr.ModTime, tr); err != nil {
			abortStream(day+" "+clean, err)
		}
		found[clean] = true
		foundHost[host] = true
		if sel.explicitOnly() && len(found) == len(sel.files) {
			break
		}
	}
	if zw == nil {
		a.fail(w, http.StatusNotFound, "The archive for "+day+" contains none of the selected files.")
		return
	}
	var missing []string
	for f := range sel.files {
		if !found[f] {
			missing = append(missing, f)
		}
	}
	for h := range sel.hosts {
		if !foundHost[h] {
			missing = append(missing, h+"/ (no files)")
		}
	}
	sort.Strings(missing)
	if err := writeMissing(zw, day, missing); err != nil {
		abortStream(day, err)
	}
	if err := zw.Close(); err != nil {
		abortStream(day, err)
	}
}
