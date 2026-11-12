package main

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"path"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
)

// extractFile streams one member of a day's .tar.zst, decompressed on the
// fly. Memory use is bounded by the zstd window of the archive (plus small
// buffers), so only a limited number of extractions run at the same time.
func (a *app) extractFile(w http.ResponseWriter, r *http.Request) {
	day, host, file, ok := a.pathArgs(w, r)
	if !ok {
		return
	}
	f, err := a.open(archivePath(day))
	if err != nil {
		a.fail(w, http.StatusNotFound, "There is no archive for "+day+".")
		return
	}
	defer f.Close()

	wait := time.NewTimer(20 * time.Second)
	defer wait.Stop()
	select {
	case a.extract <- struct{}{}:
		defer func() { <-a.extract }()
	case <-r.Context().Done():
		return
	case <-wait.C:
		w.Header().Set("Retry-After", "30")
		a.fail(w, http.StatusServiceUnavailable, "Another archive download is running. Try again in a moment.")
		return
	}

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
		debug.FreeOSMemory() // hand the decompression window back right away
	}()

	want := host + "/" + file
	tr := tar.NewReader(zr)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			a.fail(w, http.StatusNotFound, "The archive for "+day+" does not contain "+want+".")
			return
		}
		if err != nil {
			log.Printf("extract %s: %v", day, err)
			msg := "Could not read the archive."
			if errors.Is(err, zstd.ErrWindowSizeExceeded) || errors.Is(err, zstd.ErrDecoderSizeExceeded) {
				msg = "This archive was compressed with a larger zstd window than the web UI is allowed to use " +
					"(LOGS_ZSTD_MAX_WINDOW_MB). Download the whole archive instead."
			}
			a.fail(w, http.StatusInternalServerError, msg)
			return
		}
		if hdr.Typeflag != tar.TypeReg || path.Clean(strings.TrimPrefix(hdr.Name, "./")) != want {
			continue
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", strconv.FormatInt(hdr.Size, 10))
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename="%s_%s_%s"`, day, host, file))
		if r.Method == http.MethodHead {
			return
		}
		if _, err := io.Copy(w, tr); err != nil {
			log.Printf("extract %s %s: %v", day, want, err)
		}
		return
	}
}
