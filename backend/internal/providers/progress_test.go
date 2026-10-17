package providers

import "testing"

func TestProgressTrackerMergedIsMonotonic(t *testing.T) {
	var seen []Progress
	tr := NewProgressTracker(func(p Progress) { seen = append(seen, p) })
	lines := []string{
		"[youtube] YE7VzlLtp-4: Downloading webpage",
		"[info] YE7VzlLtp-4: Downloading 1 format(s): 137+140",
		"[download] Destination: Big Buck Bunny.f137.mp4",
		"[download]   0.0% of   90.00MiB at  Unknown B/s ETA Unknown",
		"[download]  50.0% of   90.00MiB at    2.00MiB/s ETA 00:22",
		"[download] 100.0% of   90.00MiB at    2.00MiB/s ETA 00:00",
		"[download] 100% of   90.00MiB in 00:00:45 at 2.00MiB/s",
		"[download] Destination: Big Buck Bunny.f140.m4a",
		"[download]   1.0% of    9.00MiB at  500.00KiB/s ETA 00:18",
		"[download] 100% of    9.00MiB in 00:00:04 at 2.10MiB/s",
		"[Merger] Merging formats into \"Big Buck Bunny.mp4\"",
		"Deleting original file Big Buck Bunny.f137.mp4",
	}
	for _, l := range lines {
		tr.Line(l)
	}
	prev := -1.0
	for _, p := range seen {
		if p.Value < prev {
			t.Fatalf("went backwards: %v after %v", p.Value, prev)
		}
		prev = p.Value
	}
	last := tr.Snapshot()
	if last.Phase != "merging" || last.Value < 0.97 || last.Value > 0.99 {
		t.Fatalf("merge step: %+v", last)
	}
	if last.Total != 99*(1<<20) {
		t.Fatalf("total %d", last.Total)
	}
	mid := seen[1]
	if mid.Value < 0.43 || mid.Value > 0.45 || mid.Speed != 2*(1<<20) {
		t.Fatalf("video half: %+v", mid)
	}
	audio := seen[4]
	if audio.Value < 0.88 {
		t.Fatalf("audio start went back: %+v", audio)
	}
}

func TestProgressTrackerSingleStream(t *testing.T) {
	tr := NewProgressTracker(nil)
	tr.Line("[info] 76790: Downloading 1 format(s): bytevc1_720p_1")
	tr.Line("[download] Destination: TikTok.mp4")
	tr.Line("[download]  25.0% of ~   6.60MiB at    1.20MiB/s ETA 00:05 (frag 2/8)")
	if v := tr.Snapshot().Value; v < 0.23 || v > 0.25 {
		t.Fatalf("single 25%%: %v", v)
	}
}
