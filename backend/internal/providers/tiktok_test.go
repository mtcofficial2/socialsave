package providers

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTikTokUsesCleanURLNotWatermark(t *testing.T) {
	var gotAuth, gotURL string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		gotURL = string(body)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
			"data": {
				"videoUrl": "https://v16.tiktokcdn.com/clean.mp4",
				"watermarkedUrl": "https://v16.tiktokcdn.com/watermark.mp4",
				"author": "creator",
				"caption": "Hello",
				"duration": 30,
				"width": 1080,
				"height": 1920,
				"coverUrl": "https://p16.tiktokcdn.com/cover.jpg"
			}
		}`))
	}))
	defer server.Close()

	cfg := testSettings("tiktok")
	cfg.AnyAPIKey = "test-key"
	resolver := NewTikTok(cfg)
	resolver.endpoint = server.URL
	resolver.client = server.Client()

	page := "https://www.tiktok.com/@creator/video/123456789"
	clip, err := resolver.Lookup(context.Background(), page)
	if err != nil {
		t.Fatal(err)
	}
	if clip.VideoURL != "https://v16.tiktokcdn.com/clean.mp4" {
		t.Fatalf("video = %s", clip.VideoURL)
	}
	if strings.Contains(clip.VideoURL, "watermark") {
		t.Fatal("used watermarked file")
	}
	if clip.Author != "@creator" || clip.Caption != "Hello" || clip.Duration != 30 || clip.Height != 1920 {
		t.Fatalf("clip = %+v", clip)
	}
	if gotAuth != "Bearer test-key" || !strings.Contains(gotURL, page) {
		t.Fatalf("request auth=%q body=%s", gotAuth, gotURL)
	}
	if clip.Response().Watermarked {
		t.Fatal("response marked watermarked")
	}

	handle, err := resolver.CreateDownload(context.Background(), page, "auto")
	if err != nil {
		t.Fatal(err)
	}
	if handle.PrepareLocally || handle.UpstreamURL != clip.VideoURL {
		t.Fatalf("handle = %+v", handle)
	}
}

func TestTikTokReadsAnyAPIEnvelope(t *testing.T) {
	body := []byte(`{"output":{"found":true,"data":{"authorHandle":"tiktok","caption":"Hello","durationSeconds":66,"image":"https://cdn.example/cover.jpg","videoUrl":"https://cdn.example/clean.mp4","watermarkedUrl":"https://cdn.example/wm.mp4"}},"costUsd":0.0009}`)
	clip, err := parseTikTokClip(body)
	if err != nil {
		t.Fatal(err)
	}
	if clip.VideoURL != "https://cdn.example/clean.mp4" || clip.Author != "@tiktok" || clip.Duration != 66 || clip.CoverURL != "https://cdn.example/cover.jpg" {
		t.Fatalf("clip = %+v", clip)
	}
}

func TestTikTokRejectsWatermarkOnlyAndBadURLs(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"data":{"watermarkedUrl":"https://cdn.example/wm.mp4"}}`))
	}))
	defer server.Close()
	cfg := testSettings("tiktok")
	cfg.AnyAPIKey = "test-key"
	resolver := NewTikTok(cfg)
	resolver.endpoint = server.URL
	resolver.client = server.Client()

	if _, err := resolver.Lookup(context.Background(), "https://www.tiktok.com/@creator/video/1"); err == nil {
		t.Fatal("expected watermark-only response to fail")
	}
	if ValidTikTokVideoURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ") {
		t.Fatal("youtube accepted as tiktok")
	}
	if ValidTikTokVideoURL("https://www.tiktok.com/@creator") {
		t.Fatal("profile accepted as video")
	}
	if !ValidTikTokVideoURL("https://vm.tiktok.com/ZMabc123/") {
		t.Fatal("short link rejected")
	}
	bare := NewTikTok(testSettings("tiktok"))
	if _, err := bare.Lookup(context.Background(), "https://www.tiktok.com/@creator/video/1"); err == nil {
		t.Fatal("missing key should fail before any network call")
	}
}
