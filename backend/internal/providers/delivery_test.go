package providers

import (
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/security"
)

func TestPlatformsChooseRedirectOrPrepareWithoutLoweringQuality(t *testing.T) {
	cfg := testSettings("tiktok,instagram,facebook,youtube,pinterest,direct")
	progressive := func(raw, page string, height int64) {
		t.Helper()
		info := mediaInfo{
			Title: "clip",
			Formats: []mediaInfo{
				{URL: raw, Ext: "mp4", VCodec: "avc1", ACodec: "aac", Height: flex(height), TBR: 4000, Filesize: flex(20_000_000)},
			},
		}
		handle, ok, err := directFromInfo(info, page, "original", "clip", cfg)
		if err != nil || !ok || handle.PrepareLocally || handle.Proxy || handle.UpstreamURL != raw {
			t.Fatalf("%s handle=%#v ok=%v err=%v", page, handle, ok, err)
		}
		if handle.MimeType != "video/mp4" {
			t.Fatalf("%s mime %s", page, handle.MimeType)
		}
	}
	progressive("https://v16.tiktokcdn.com/video.mp4", "https://www.tiktok.com/@name/video/1", 1080)
	progressive("https://instagram.fcdn.net/reel.mp4", "https://www.instagram.com/reel/abc/", 1080)
	progressive("https://video.xx.fbcdn.net/watch.mp4", "https://www.facebook.com/watch?v=1", 1080)
	progressive("https://v.pinimg.com/videos/pin.mp4", "https://www.pinterest.com/pin/1/", 720)

	youtube := mediaInfo{
		Title: "watch",
		Formats: []mediaInfo{
			{URL: "https://rr3---sn.googlevideo.com/video", Ext: "mp4", VCodec: "avc1", ACodec: "none", Height: flex(1080), TBR: 4500},
			{URL: "https://rr3---sn.googlevideo.com/audio", Ext: "m4a", VCodec: "none", ACodec: "mp4a", TBR: 128},
		},
	}
	if _, ok, err := directFromInfo(youtube, "https://www.youtube.com/watch?v=abcdefghijk", "original", "watch", cfg); err != nil || ok {
		t.Fatalf("youtube should be prepared locally, ok=%v err=%v", ok, err)
	}
	selector := FormatSelector("original", true, 1080)
	if strings.Contains(selector, "height<=") || strings.Contains(selector, "480") || strings.Contains(selector, "720") || !strings.Contains(selector, "bv*") {
		t.Fatalf("selector = %s", selector)
	}
}

func TestDirectSourceURLStaysOnTheSourceHost(t *testing.T) {
	validator := security.NewValidator()
	validator.Lookup = func(context.Context, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("93.184.216.34")}, nil
	}
	fetch := NewFetcher(validator, time.Second, 1)
	fetch.Client = &http.Client{
		Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{
				StatusCode: http.StatusOK,
				Header: http.Header{
					"Content-Type":   []string{"video/mp4"},
					"Content-Length": []string{"4096"},
				},
				Body:    io.NopCloser(strings.NewReader("")),
				Request: r,
			}, nil
		}),
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	direct := &Direct{cfg: testSettings("direct"), fetch: fetch}
	handle, err := direct.CreateDownload(context.Background(), "https://cdn.example.com/clip.mp4", "original")
	if err != nil {
		t.Fatal(err)
	}
	if handle.PrepareLocally || handle.Proxy || handle.UpstreamURL != "https://cdn.example.com/clip.mp4" {
		t.Fatalf("handle = %#v", handle)
	}
	if handle.MimeType != "video/mp4" || handle.Filesize == nil || *handle.Filesize != 4096 {
		t.Fatalf("mime %s size %v", handle.MimeType, handle.Filesize)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return fn(r)
}
