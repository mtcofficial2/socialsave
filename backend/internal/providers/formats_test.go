package providers

import "testing"

func TestPickProgressiveRequiresAudio(t *testing.T) {
	info := mediaInfo{
		Formats: []mediaInfo{
			{URL: "https://cdn.example.com/silent.mp4", VCodec: "avc1", ACodec: "none", Height: flex(1080), TBR: 2500},
			{URL: "https://cdn.example.com/with-audio.mp4", VCodec: "avc1", ACodec: "aac", Height: flex(480), TBR: 800},
		},
	}
	max := 1080
	picked := PickProgressive(info, &max)
	if picked == nil || picked.URL != "https://cdn.example.com/with-audio.mp4" {
		t.Fatalf("picked = %#v", picked)
	}
}

func TestPickProgressiveSkipsVideoOnly(t *testing.T) {
	info := mediaInfo{
		Formats: []mediaInfo{
			{URL: "https://cdn.example.com/silent.mp4", VCodec: "avc1", ACodec: "none", Height: flex(1080)},
		},
	}
	if PickProgressive(info, nil) != nil {
		t.Fatal("expected no progressive stream")
	}
}

func TestPreferDirectFileDoesNotDowngrade(t *testing.T) {
	if preferDirectFile(480, 1080) {
		t.Fatal("a 480p file must not replace a 1080p video")
	}
	if !preferDirectFile(1080, 1080) {
		t.Fatal("a matching 1080p file should be delivered directly")
	}
	if !preferDirectFile(720, 0) {
		t.Fatal("a file should be delivered directly when no taller video is known")
	}
}

func TestFormatSelectorCapsHeight(t *testing.T) {
	if RequestedMaxHeight("auto", 1080) != nil {
		t.Fatal("auto should be uncapped")
	}
	if got := RequestedMaxHeight("720p", 1080); got == nil || *got != 720 {
		t.Fatalf("720p = %v", got)
	}
	if RequestedMaxHeight("original", 1080) != nil {
		t.Fatal("original should be uncapped")
	}
	auto := FormatSelector("auto", true, 1080)
	if contains(auto, "height<=") || !contains(auto, "bv*") {
		t.Fatal(auto)
	}
	if !contains(FormatSelector("720p", true, 1080), "720") {
		t.Fatal(FormatSelector("720p", true, 1080))
	}
	original := FormatSelector("original", true, 1080)
	if !contains(original, "bv*") || contains(original, "avc1") || contains(original, "height<=") {
		t.Fatal(original)
	}
	if contains(dashFirst(1080), "avc1") {
		t.Fatal(dashFirst(1080))
	}
}

func TestASCIIFilenameStripsEmoji(t *testing.T) {
	name := ASCIIFilename("Scramble up ur name #foryou.mp4")
	if !isASCII(name) || len(name) < 4 || name[len(name)-4:] != ".mp4" {
		t.Fatalf("name = %q", name)
	}
	emoji := ASCIIFilename("hello 😍.mp4")
	if !isASCII(emoji) || contains(emoji, `"`) {
		t.Fatalf("emoji name = %q", emoji)
	}
}

func TestMapExtractorErrors(t *testing.T) {
	youtube := MapExtractorError("ERROR: unable to download video data: HTTP Error 403: Forbidden", "https://www.youtube.com/watch?v=jNQXAC9IVRw")
	if youtube.Code != "platform_unavailable" || contains(youtube.Message, "tiktok") || !contains(youtube.Message, "YouTube") {
		t.Fatalf("youtube = %+v", youtube)
	}
	tiktok := MapExtractorError("[TikTok] 123: This post may not be comfortable for some audiences. Log in for access.", "https://www.tiktok.com/@user/video/123")
	if tiktok.Code != "private_video" || !contains(tiktok.Message, "TikTok") {
		t.Fatalf("tiktok = %+v", tiktok)
	}
	private := MapExtractorError("[youtube] Private video", "https://youtu.be/abcdefghijk")
	if contains(private.Message, "TikTok") {
		t.Fatalf("private = %+v", private)
	}
}

func TestRegistryDetectsHostsAndDisabledPlatform(t *testing.T) {
	registry := NewRegistry(testSettings("tiktok,instagram,facebook,x,youtube,reddit,pinterest,direct"), nil)
	youtube, err := registry.Resolve("https://youtu.be/dQw4w9WgXcQ")
	if err != nil || youtube.ID() != "youtube" || !youtube.SupportsDownload() {
		t.Fatalf("youtube = %v %v", youtube, err)
	}
	if _, ok := youtube.(*Social); !ok {
		t.Fatalf("youtube provider type = %T", youtube)
	}
	for _, raw := range []string{
		"https://www.instagram.com/reel/abc/",
		"https://www.facebook.com/watch?v=1",
		"https://www.pinterest.com/pin/1/",
	} {
		provider, err := registry.Resolve(raw)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := provider.(*Social); !ok || provider.ID() == "tiktok" {
			t.Fatalf("%s provider = %T %s", raw, provider, provider.ID())
		}
	}
	tiktok, err := registry.Resolve("https://www.tiktok.com/@user/video/123")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := tiktok.(*Social); !ok || tiktok.ID() != "tiktok" {
		t.Fatalf("tiktok provider type = %T %s", tiktok, tiktok.ID())
	}
	direct, err := registry.Resolve("https://cdn.example.com/film.mp4")
	if err != nil || direct.ID() != "direct" || !direct.CanHandle("https://cdn.example.com/film.mp4") {
		t.Fatalf("direct = %v %v", direct, err)
	}
	if direct.CanHandle("https://cdn.example.com/page") {
		t.Fatal("pages are not direct files")
	}
	disabled := NewRegistry(testSettings("direct"), nil)
	if _, err := disabled.Resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ"); err == nil {
		t.Fatal("expected disabled youtube to fail")
	}
}

func flex(n int64) flexInt {
	return flexInt{N: &n}
}

func contains(text, part string) bool {
	return len(part) == 0 || (len(text) >= len(part) && (text == part || len(text) > 0 && stringIndex(text, part) >= 0))
}

func stringIndex(text, part string) int {
	for i := 0; i+len(part) <= len(text); i++ {
		if text[i:i+len(part)] == part {
			return i
		}
	}
	return -1
}

func isASCII(text string) bool {
	for _, r := range text {
		if r > 127 {
			return false
		}
	}
	return true
}
