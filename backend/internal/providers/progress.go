package providers

import (
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// Progress is one smooth, never-decreasing view of a yt-dlp save.
//
// yt-dlp reports each stream on its own: a merged 1080p save goes 0-100% for
// the video, starts again at 0% for the audio, then sits silent while ffmpeg
// merges. The app showed that as an empty or jumping bar. ProgressTracker
// folds the streams and the merge into one 0..0.99 value with real bytes and
// speed.
type Progress struct {
	Value      float64 // 0..0.99 until the file is ready
	Downloaded int64   // bytes received so far, all streams
	Total      int64   // bytes expected for the streams seen so far (0 = unknown)
	Speed      float64 // bytes per second (0 = unknown)
	Phase      string  // "downloading" or "merging"
}

// ProgressTracker parses yt-dlp's default "--newline --progress" output.
type ProgressTracker struct {
	mu        sync.Mutex
	streams   int     // expected streams ("137+140" = 2)
	index     int     // current stream, -1 before the first
	pct       float64 // current stream 0..1
	curTotal  int64   // current stream size
	doneBytes int64   // finished streams
	last      Progress
	report    func(Progress)
}

func NewProgressTracker(report func(Progress)) *ProgressTracker {
	return &ProgressTracker{streams: 1, index: -1, report: report, last: Progress{Phase: "downloading"}}
}

var (
	formatsLine  = regexp.MustCompile(`Downloading \d+ format\(s\): (\S+)`)
	percentLine  = regexp.MustCompile(`^\[download\]\s+([0-9.]+)% of\s+~?\s*([0-9.]+)\s*([KMGT]i?B|B)(?:.*? at\s+([0-9.]+)\s*([KMGT]i?B|B)/s)?`)
	postLine     = regexp.MustCompile(`^\[(Merger|ExtractAudio|VideoRemuxer|VideoConvertor|Fixup[A-Za-z0-9]*|ffmpeg)\]`)
)

func unitBytes(number, unit string) int64 {
	value, err := strconv.ParseFloat(number, 64)
	if err != nil {
		return 0
	}
	mult := 1.0
	switch strings.TrimSuffix(strings.TrimSuffix(unit, "B"), "i") {
	case "K":
		mult = 1 << 10
	case "M":
		mult = 1 << 20
	case "G":
		mult = 1 << 30
	case "T":
		mult = 1 << 40
	}
	return int64(value * mult)
}

// weights: share of the bar for each stream; the last 3% is the merge.
func (t *ProgressTracker) weight(i int) (before, own float64) {
	switch {
	case t.streams <= 1:
		return 0, 0.96
	case t.streams == 2:
		w := []float64{0.88, 0.08}
		if i <= 0 {
			return 0, w[0]
		}
		return w[0], w[1]
	default:
		each := 0.96 / float64(t.streams)
		return each * float64(i), each
	}
}

// Line feeds one output line; returns true when the view changed.
func (t *ProgressTracker) Line(line string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return
	}
	t.mu.Lock()
	next := t.last
	changed := false
	switch {
	case formatsLine.MatchString(line):
		ids := formatsLine.FindStringSubmatch(line)[1]
		t.streams = strings.Count(ids, "+") + 1
	case strings.HasPrefix(line, "[download] Destination:"):
		if t.index >= 0 {
			t.doneBytes += t.curTotal
		}
		t.index++
		if t.index >= t.streams {
			t.streams = t.index + 1
		}
		t.pct, t.curTotal = 0, 0
	case strings.HasPrefix(line, "[download]") && strings.Contains(line, "has already been downloaded"):
		t.pct = 1
		next.Value = maxF(next.Value, 0.96)
		changed = true
	case percentLine.MatchString(line):
		m := percentLine.FindStringSubmatch(line)
		pct, _ := strconv.ParseFloat(m[1], 64)
		if t.index < 0 {
			t.index = 0
		}
		t.pct = clampF(pct/100, 0, 1)
		if total := unitBytes(m[2], m[3]); total > 0 {
			t.curTotal = total
		}
		if m[4] != "" {
			next.Speed = float64(unitBytes(m[4], m[5]))
		}
		before, own := t.weight(t.index)
		next.Value = maxF(next.Value, before+own*t.pct)
		next.Downloaded = maxI(next.Downloaded, t.doneBytes+int64(t.pct*float64(t.curTotal)))
		next.Total = maxI(next.Total, t.doneBytes+t.curTotal)
		changed = true
	case postLine.MatchString(line):
		if next.Phase != "merging" {
			next.Phase = "merging"
			next.Value = maxF(next.Value, 0.97)
		} else {
			next.Value = maxF(next.Value, minF(next.Value+0.005, 0.99))
		}
		next.Speed = 0
		if next.Total > 0 {
			next.Downloaded = next.Total
		}
		changed = true
	}
	next.Value = minF(next.Value, 0.99)
	if changed {
		t.last = next
	}
	report := t.report
	t.mu.Unlock()
	if changed && report != nil {
		report(next)
	}
}

// Snapshot is the latest view.
func (t *ProgressTracker) Snapshot() Progress {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.last
}

func clampF(v, lo, hi float64) float64 { return maxF(lo, minF(v, hi)) }
func maxF(a, b float64) float64 {
	if a > b {
		return a
	}
	return b
}
func minF(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
