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

func TestDecodePlaylistKeepsVideoThumbnail(t *testing.T) {
	raw := `{
		"entries": [
			{
				"title": "One",
				"webpage_url": "https://www.youtube.com/watch?v=abcdefghijk",
				"thumbnail": "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg",
				"thumbnails": [{"id": "avatar_uncropped", "url": "https://yt3.ggpht.com/face"}]
			},
			{"title": "Bare", "url": "https://example.com/v", "thumbnail": "not-a-url"}
		]
	}`
	items, err := decodePlaylist(raw, "https://example.com/playlist")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("len=%d", len(items))
	}
	if items[0].Thumbnail != "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg" {
		t.Fatalf("thumb=%q", items[0].Thumbnail)
	}
	if items[1].Thumbnail != "" {
		t.Fatalf("bare thumb=%q", items[1].Thumbnail)
	}
}

func TestDecodePlaylistSingleVideo(t *testing.T) {
	items, err := decodePlaylist(`{"title":"Flower"}`, "https://example.com/flower.mp4")
	if err != nil || len(items) != 1 || items[0].URL != "https://example.com/flower.mp4" {
		t.Fatalf("items=%#v err=%v", items, err)
	}
}

func TestPlaylistMetaKeepsAvatarAndStripsTab(t *testing.T) {
	channel, avatar := playlistMeta(mediaInfo{
		Title:     "Ada - Videos",
		Channel:   "Ada - Videos",
		Thumbnail: "https://i.ytimg.com/vi/abc/hqdefault.jpg",
		Thumbnails: []thumbInfo{
			{ID: "0", URL: "https://i.ytimg.com/vi/abc/hqdefault.jpg"},
			{ID: "banner_uncropped", URL: "https://yt3.googleusercontent.com/banner"},
			{ID: "avatar_uncropped", URL: "https://yt3.ggpht.com/ada=s900"},
		},
	})
	if channel != "Ada" || avatar != "https://yt3.ggpht.com/ada=s900" {
		t.Fatalf("channel=%q avatar=%q", channel, avatar)
	}
}

func TestPlaylistMetaSkipsVideoThumb(t *testing.T) {
	channel, avatar := playlistMeta(mediaInfo{
		Uploader:  "Ada",
		Thumbnail: "https://i.ytimg.com/vi/abc/maxresdefault.jpg",
	})
	if channel != "Ada" || avatar != "" {
		t.Fatalf("channel=%q avatar=%q", channel, avatar)
	}
}

func TestPlaylistMetaSkipsBannerAlone(t *testing.T) {
	_, avatar := playlistMeta(mediaInfo{
		Channel: "Ada",
		Thumbnails: []thumbInfo{
			{ID: "banner_uncropped", URL: "https://yt3.googleusercontent.com/banner"},
		},
	})
	if avatar != "" {
		t.Fatalf("avatar=%q", avatar)
	}
}
