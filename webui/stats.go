package main

import (
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
)

type rankRow struct {
	Name     string
	Bytes    int64
	Lines    int64
	Errors   int64
	Warnings int64
	Share    float64 // percent of the period's bytes
}

// periodDays returns the manifest days of a period. Periods are counted back
// from the latest collected day, not from the wall clock, so the numbers do
// not change while the UI waits for the next nightly run.
func periodDays(ix *Index, period string) []*DayInfo {
	latest := ix.Latest()
	if latest == nil {
		return nil
	}
	n := 0
	switch period {
	case "latest":
		return []*DayInfo{latest}
	case "7d":
		n = 7
	case "30d":
		n = 30
	default:
		n = -1
	}
	cutoff := ""
	if n > 0 {
		cutoff = shiftDay(latest.Day, -n)
	}
	var out []*DayInfo
	for _, d := range ix.Days {
		if d.HasManifest && d.Day > cutoff && d.Day <= latest.Day {
			out = append(out, d)
		}
	}
	return out
}

func shiftDay(day string, n int) string {
	t, err := time.Parse("2006-01-02", day)
	if err != nil {
		return day
	}
	return t.AddDate(0, 0, n).Format("2006-01-02")
}

func rank(days []*DayInfo, byService bool, limit int) []rankRow {
	agg := map[string]*rankRow{}
	var total int64
	for _, d := range days {
		for host, h := range d.Hosts {
			for _, s := range h.Sources {
				key := host
				if byService {
					key = host + " / " + s.Name
				}
				r := agg[key]
				if r == nil {
					r = &rankRow{Name: key}
					agg[key] = r
				}
				r.Bytes += s.Bytes
				r.Lines += s.Lines
				r.Errors += s.Errors
				r.Warnings += s.Warnings
				total += s.Bytes
			}
		}
	}
	rows := make([]rankRow, 0, len(agg))
	for _, r := range agg {
		if total > 0 {
			r.Share = float64(r.Bytes) * 100 / float64(total)
		}
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Bytes != rows[j].Bytes {
			return rows[i].Bytes > rows[j].Bytes
		}
		return rows[i].Name < rows[j].Name
	})
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

type growthRow struct {
	Name    string
	Cur     int64
	Prev    int64
	Delta   int64
	Pct     float64
	HasPrev bool
}

// growth compares the last 7 collected days with the 7 days before them.
func growth(ix *Index, limit int) []growthRow {
	latest := ix.Latest()
	if latest == nil {
		return nil
	}
	curFrom := shiftDay(latest.Day, -7)
	prevFrom := shiftDay(latest.Day, -14)
	agg := map[string]*growthRow{}
	for _, d := range ix.Days {
		if !d.HasManifest || d.Day <= prevFrom || d.Day > latest.Day {
			continue
		}
		for host, h := range d.Hosts {
			for _, s := range h.Sources {
				key := host + " / " + s.Name
				r := agg[key]
				if r == nil {
					r = &growthRow{Name: key}
					agg[key] = r
				}
				if d.Day > curFrom {
					r.Cur += s.Bytes
				} else {
					r.Prev += s.Bytes
				}
			}
		}
	}
	rows := make([]growthRow, 0, len(agg))
	for _, r := range agg {
		r.Delta = r.Cur - r.Prev
		if r.Prev > 0 {
			r.HasPrev = true
			r.Pct = float64(r.Delta) * 100 / float64(r.Prev)
		}
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := abs64(rows[i].Delta), abs64(rows[j].Delta)
		if a != b {
			return a > b
		}
		return rows[i].Name < rows[j].Name
	})
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	return rows
}

func abs64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

type failHost struct {
	Name   string
	Status string
	Error  string
}

type failRow struct {
	Day   string
	Hosts []failHost
}

// failures lists the most recent days that had hosts with problems.
func failures(ix *Index, limit int) []failRow {
	var rows []failRow
	for i := len(ix.Days) - 1; i >= 0 && len(rows) < limit; i-- {
		d := ix.Days[i]
		if len(d.Problems) == 0 {
			continue
		}
		row := failRow{Day: d.Day}
		for _, name := range d.Problems {
			h := d.Hosts[name]
			msg := h.Error
			if msg == "" {
				var bad []string
				for _, s := range h.Sources {
					if !s.OK {
						bad = append(bad, s.Name+": "+s.Msg)
					}
				}
				msg = strings.Join(bad, "; ")
			}
			row.Hosts = append(row.Hosts, failHost{Name: name, Status: h.Status, Error: msg})
		}
		rows = append(rows, row)
	}
	return rows
}

// ---- size-per-day chart (server-rendered SVG, no JavaScript) ----

type chartBar struct {
	Day      string
	Path     string // bar outline with rounded top
	HitX     float64
	HitW     float64
	Title    string
	Problem  bool
	MarkX    float64
	HasValue bool
}

type chartTick struct {
	Y     float64
	Label string
}

type chartLabel struct {
	X      float64
	Text   string
	Anchor string
}

type chart struct {
	W, H           float64
	PlotX, PlotY   float64
	PlotW, PlotH   float64
	BaseY          float64
	Bars           []chartBar
	Ticks          []chartTick
	XLabels        []chartLabel
	From, To       string
	Total          int64
	AnyProblem     bool
	ShowMarks      bool
	Empty          bool
	RangeDays      int
	CollectedDays  int
	AverageBytes   int64
	LargestDay     string
	LargestDaySize int64
}

func buildChart(ix *Index, n int) chart {
	c := chart{W: 900, H: 230, PlotX: 62, PlotY: 10, RangeDays: n}
	c.PlotW = c.W - c.PlotX - 8
	c.PlotH = c.H - c.PlotY - 34
	c.BaseY = c.PlotY + c.PlotH
	latest := ix.Latest()
	if latest == nil {
		c.Empty = true
		return c
	}
	if n <= 0 { // all: from the first manifest day
		first := latest.Day
		for _, d := range ix.Days {
			if d.HasManifest {
				first = d.Day
				break
			}
		}
		a, _ := time.Parse("2006-01-02", first)
		b, _ := time.Parse("2006-01-02", latest.Day)
		n = int(b.Sub(a).Hours()/24) + 1
	}
	c.From, c.To = shiftDay(latest.Day, -(n-1)), latest.Day

	var max int64
	days := make([]*DayInfo, n)
	for i := 0; i < n; i++ {
		d := ix.Day(shiftDay(c.From, i))
		if d != nil && d.HasManifest {
			days[i] = d
			c.Total += d.Bytes
			c.CollectedDays++
			if d.Bytes > max {
				max = d.Bytes
				c.LargestDay, c.LargestDaySize = d.Day, d.Bytes
			}
		}
	}
	if c.CollectedDays > 0 {
		c.AverageBytes = c.Total / int64(c.CollectedDays)
	}
	top := niceMax(max)
	for _, f := range []float64{0, 0.5, 1} {
		c.Ticks = append(c.Ticks, chartTick{Y: c.BaseY - c.PlotH*f, Label: humanBytes(int64(float64(top) * f))})
	}

	slot := c.PlotW / float64(n)
	w := slot
	if slot >= 4 {
		w = slot - 2 // 2px surface gap between bars
	}
	c.ShowMarks = slot >= 7
	for i, d := range days {
		x := c.PlotX + float64(i)*slot + (slot-w)/2
		b := chartBar{Day: shiftDay(c.From, i), HitX: c.PlotX + float64(i)*slot, HitW: slot, MarkX: x + w/2}
		if d == nil {
			b.Title = b.Day + ": no manifest"
		} else {
			b.HasValue = true
			h := 0.0
			if top > 0 {
				h = c.PlotH * float64(d.Bytes) / float64(top)
			}
			if h < 1 && d.Bytes > 0 {
				h = 1
			}
			b.Path = barPath(x, c.BaseY-h, w, h)
			b.Title = fmt.Sprintf("%s: %s, %s lines", d.Day, humanBytes(d.Bytes), groupDigits(d.Lines))
			if len(d.Problems) > 0 {
				b.Problem = true
				c.AnyProblem = true
				b.Title += fmt.Sprintf(", %d host(s) with problems", len(d.Problems))
			}
		}
		c.Bars = append(c.Bars, b)
	}
	c.XLabels = []chartLabel{{X: c.PlotX, Text: c.From, Anchor: "start"}}
	if n >= 14 {
		c.XLabels = append(c.XLabels, chartLabel{X: c.PlotX + c.PlotW/2, Text: shiftDay(c.From, n/2), Anchor: "middle"})
	}
	if n > 1 {
		c.XLabels = append(c.XLabels, chartLabel{X: c.PlotX + c.PlotW, Text: c.To, Anchor: "end"})
	}
	return c
}

// barPath draws a bar anchored to the baseline with a rounded top.
func barPath(x, y, w, h float64) string {
	r := math.Min(4, math.Min(w/2, h))
	return fmt.Sprintf("M%.1f %.1fV%.1fQ%.1f %.1f %.1f %.1fH%.1fQ%.1f %.1f %.1f %.1fV%.1fZ",
		x, y+h, y+r, x, y, x+r, y, x+w-r, x+w, y, x+w, y+r, y+h)
}

// niceMax rounds up to 1, 2 or 5 times a power of ten of a binary unit.
func niceMax(v int64) int64 {
	if v <= 0 {
		return 1024
	}
	unit := int64(1)
	for v/unit >= 1024 {
		unit *= 1024
	}
	m := float64(v) / float64(unit)
	for _, s := range []float64{1, 2, 5, 10, 20, 50, 100, 200, 500, 1024} {
		if m <= s {
			return int64(s * float64(unit))
		}
	}
	return v
}

func humanBytes(v int64) string {
	if v < 0 {
		return "-" + humanBytes(-v)
	}
	units := []string{"B", "KiB", "MiB", "GiB", "TiB", "PiB"}
	f := float64(v)
	i := 0
	for f >= 1024 && i < len(units)-1 {
		f /= 1024
		i++
	}
	switch {
	case i == 0:
		return fmt.Sprintf("%d B", v)
	case f >= 100:
		return fmt.Sprintf("%.0f %s", f, units[i])
	case f >= 10:
		return fmt.Sprintf("%.1f %s", f, units[i])
	default:
		return fmt.Sprintf("%.2f %s", f, units[i])
	}
}

func groupDigits(v int64) string {
	s := fmt.Sprintf("%d", abs64(v))
	var b strings.Builder
	if v < 0 {
		b.WriteByte('-')
	}
	for i, ch := range s {
		if i > 0 && (len(s)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(ch)
	}
	return b.String()
}
