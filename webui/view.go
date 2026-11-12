package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const maxLineOverrun = 256 * 1024 // how far a page may run past its size to finish a line

// view shows one page of a raw log, or a streamed text filter when ?q= is set.
// Neither path ever holds more than one page (or one line) in memory.
func (a *app) view(w http.ResponseWriter, r *http.Request) {
	day, host, file, ok := a.pathArgs(w, r)
	if !ok {
		return
	}
	f, err := a.open(rawDir(day) + "/" + host + "/" + file)
	if err != nil {
		a.fail(w, http.StatusNotFound, "This file is not available as a raw log. Archived days offer downloads only.")
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		a.fail(w, http.StatusNotFound, "Not a file.")
		return
	}
	size := info.Size()
	base := "/view/" + day + "/" + host + "/" + file
	if q := r.URL.Query().Get("q"); q != "" {
		a.filter(w, r, f, size, base, day, host, file, q)
		return
	}

	pageSize := a.cfg.PageBytes
	off := queryInt(r, "off")
	if r.URL.Query().Get("tail") != "" {
		off = size - pageSize
	}
	if off > size {
		off = size
	}
	if off < 0 {
		off = 0
	}
	start := lineStart(f, off)
	buf := make([]byte, pageSize+maxLineOverrun)
	n, err := f.ReadAt(buf, start)
	if err != nil && !errors.Is(err, io.EOF) {
		a.fail(w, http.StatusInternalServerError, "Could not read the file.")
		return
	}
	buf = buf[:n]
	truncated := false
	if int64(n) > pageSize {
		// Finish the last line, but never read more than the overrun.
		if i := bytes.IndexByte(buf[pageSize-1:], '\n'); i >= 0 {
			buf = buf[:pageSize+int64(i)]
		} else {
			truncated = true
		}
	}
	end := start + int64(len(buf))

	data := map[string]any{
		"Day": day, "Host": host, "File": file, "Base": base,
		"Text":  strings.ToValidUTF8(string(buf), "�"),
		"Start": start, "End": end, "Size": size,
		"HasPrev": start > 0, "HasNext": end < size, "Truncated": truncated,
		"PrevOff": max64(0, start-pageSize), "NextOff": end,
	}
	a.render(w, 200, "view", file+" · "+host+" · "+day, "days", data)
}

// lineStart moves off back to the beginning of the line it points into,
// looking at most one overrun backwards.
func lineStart(f *os.File, off int64) int64 {
	if off <= 0 {
		return 0
	}
	from := max64(0, off-maxLineOverrun)
	buf := make([]byte, off-from)
	n, _ := f.ReadAt(buf, from)
	if i := bytes.LastIndexByte(buf[:n], '\n'); i >= 0 {
		return from + int64(i) + 1
	}
	return off
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// filter streams the lines containing q (case-insensitive substring). It
// stops at the result limit or the timeout and then offers a link that
// continues from the byte offset it reached.
func (a *app) filter(w http.ResponseWriter, r *http.Request, f *os.File, size int64, base, day, host, file, q string) {
	off := queryInt(r, "off")
	if off > size {
		off = size
	}
	off = lineStart(f, off)
	deadline := time.Now().Add(a.cfg.FilterTimeout)
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(deadline.Add(10 * time.Second))

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	p := page{Title: "Filter · " + file, Site: a.cfg.Title, Version: version, Nav: "days",
		Data: map[string]any{"Day": day, "Host": host, "File": file, "Base": base, "Query": q, "Off": off}}
	if err := a.tpl["filter"].ExecuteTemplate(w, "filter_head", p); err != nil {
		return
	}

	needle := bytes.ToLower([]byte(q))
	rd := bufio.NewReaderSize(io.NewSectionReader(f, off, size-off), 64*1024)
	scratch := make([]byte, 0, 64*1024)
	pos, matches, lines := off, 0, 0
	reason := "done"
	const maxShown = 4096 // bytes of one matching line that are printed

loop:
	for {
		line, err := rd.ReadSlice('\n')
		lineOff := pos
		pos += int64(len(line))
		long := errors.Is(err, bufio.ErrBufferFull)
		if len(line) > 0 {
			scratch = append(scratch[:0], line...)
			lowerASCII(scratch)
			if bytes.Contains(scratch, needle) {
				matches++
				shown := bytes.TrimRight(line, "\r\n")
				cut := ""
				if len(shown) > maxShown || long {
					shown = shown[:min(len(shown), maxShown)]
					cut = " <span class=\"muted\">[line cut]</span>"
				}
				fmt.Fprintf(w, "<a class=\"off\" href=\"%s?off=%d\">%d</a> %s%s\n", base, lineOff, lineOff,
					html.EscapeString(strings.ToValidUTF8(string(shown), "�")), cut)
				if matches%50 == 0 {
					_ = rc.Flush()
				}
			}
		}
		if long { // skip the rest of an over-long line
			for errors.Is(err, bufio.ErrBufferFull) {
				var rest []byte
				rest, err = rd.ReadSlice('\n')
				pos += int64(len(rest))
			}
		}
		if err != nil { // io.EOF or a read error
			if !errors.Is(err, io.EOF) {
				reason = "error"
			}
			break
		}
		lines++
		switch {
		case matches >= a.cfg.FilterMax:
			reason = "limit"
			break loop
		case lines%512 == 0 && time.Now().After(deadline):
			reason = "timeout"
			break loop
		case lines%512 == 0 && r.Context().Err() != nil:
			return
		}
	}

	foot := map[string]any{
		"Matches": matches, "From": off, "To": pos, "Size": size, "Reason": reason,
		"Continue": base + "?q=" + url.QueryEscape(q) + fmt.Sprintf("&off=%d", pos),
		"Limit":    a.cfg.FilterMax, "Timeout": a.cfg.FilterTimeout.String(),
	}
	p.Data = foot
	_ = a.tpl["filter"].ExecuteTemplate(w, "filter_foot", p)
}

func lowerASCII(b []byte) {
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
}
