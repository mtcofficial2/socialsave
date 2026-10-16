package providers

import (
	"strings"
	"testing"
)

func TestWebFormatPrefersH264(t *testing.T) {
	selector := FormatSelector("1080p+web", true, 1080)
	if !strings.HasPrefix(selector, "b[height<=1080][vcodec^=avc1][acodec!=none]/") {
		t.Fatal(selector)
	}
	if !strings.HasSuffix(selector, FormatSelector("1080p", true, 1080)) {
		t.Fatal(selector)
	}
	if got := FormatSelector("audio+web", true, 1080); got != FormatSelector("audio", true, 1080) {
		t.Fatal(got)
	}
	if h := RequestedMaxHeight("720p+web", 1080); h == nil || *h != 720 {
		t.Fatal(h)
	}
	if strings.Contains(FormatSelector("original+web", false, 1080), "height") {
		t.Fatal(FormatSelector("original+web", false, 1080))
	}
}
