package providers

import "testing"

func TestDecodePlaylistUsesEntryURLs(t *testing.T) {
	raw := `{
		"title": "Mix",
		"entries": [
			{"title": "One", "url": "https://example.com/watch?v=1", "duration": 12},
			{"title": "Skip", "url": "abc"},
			{"title": "Two", "webpage_url": "https://example.com/watch?v=2"}
		]
	}`
	items, err := decodePlaylist(raw, "https://example.com/playlist")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[0].URL != "https://example.com/watch?v=1" || items[1].URL != "https://example.com/watch?v=2" {
		t.Fatalf("items = %#v", items)
	}
	if items[0].Duration == nil || *items[0].Duration != 12 {
		t.Fatalf("duration = %#v", items[0].Duration)
	}
}

func TestDecodePlaylistSingleVideo(t *testing.T) {
	items, err := decodePlaylist(`{"title":"Flower"}`, "https://example.com/flower.mp4")
	if err != nil || len(items) != 1 || items[0].URL != "https://example.com/flower.mp4" {
		t.Fatalf("items=%#v err=%v", items, err)
	}
}
