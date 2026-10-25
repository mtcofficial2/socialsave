package providers

import (
	"context"
	"net/url"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

// ListedPlaylist is the public rows plus the channel name and portrait when known.
type ListedPlaylist struct {
	Items   []models.PlaylistEntry
	Channel string
	Avatar  string
}

const playlistLimit = 40

// FlatPlaylist lists public playlist entries without downloading media.
func (r *Runner) FlatPlaylist(ctx context.Context, rawURL string) (ListedPlaylist, error) {
	if err := r.available(); err != nil {
		return ListedPlaylist{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	args := []string{
		"--flat-playlist",
		"--dump-single-json",
		"--skip-download",
		"--no-progress",
		"--ignore-config",
		"--no-cache-dir",
		"--playlist-end", "40",
		"--socket-timeout", "20",
		"--retries", "1",
	}
	args = append(args, toolArgs(rawURL)...)
	args = append(args, "--", rawURL)
	stdout, stderr, err := r.run(ctx, args, "")
	if err != nil {
		return ListedPlaylist{}, MapExtractorError(stderr+"\n"+err.Error(), rawURL)
	}
	return decodeListed(stdout, rawURL)
}

func decodePlaylist(stdout, pageURL string) ([]models.PlaylistEntry, error) {
	listed, err := decodeListed(stdout, pageURL)
	if err != nil {
		return nil, err
	}
	return listed.Items, nil
}

func decodeListed(stdout, pageURL string) (ListedPlaylist, error) {
	info, err := decodeInfo(stdout)
	if err != nil {
		return ListedPlaylist{}, err
	}
	items, err := playlistEntries(info, pageURL)
	if err != nil {
		return ListedPlaylist{}, err
	}
	channel, avatar := playlistMeta(info)
	return ListedPlaylist{Items: items, Channel: channel, Avatar: avatar}, nil
}

func playlistEntries(info mediaInfo, pageURL string) ([]models.PlaylistEntry, error) {
	if len(info.Entries) == 0 {
		title := strings.TrimSpace(info.Title)
		if title == "" {
			title = "Video"
		}
		page := strings.TrimSpace(pageURL)
		if !strings.HasPrefix(page, "http") {
			return nil, errs.RemovedVideo()
		}
		return []models.PlaylistEntry{{
			Title:     title,
			URL:       page,
			Duration:  positiveDuration(info.Duration.N),
			Thumbnail: entryThumbnail(info),
		}}, nil
	}
	items := make([]models.PlaylistEntry, 0, len(info.Entries))
	for _, entry := range info.Entries {
		if len(items) >= playlistLimit {
			break
		}
		page := firstHTTP(entry.WebpageURL, entry.URL)
		if page == "" {
			continue
		}
		title := strings.TrimSpace(entry.Title)
		if title == "" {
			title = "Video"
		}
		items = append(items, models.PlaylistEntry{
			Title:     title,
			URL:       page,
			Duration:  positiveDuration(entry.Duration.N),
			Thumbnail: entryThumbnail(entry),
		})
	}
	if len(items) == 0 {
		return nil, errs.RemovedVideo()
	}
	return items, nil
}

func playlistMeta(info mediaInfo) (channel, avatar string) {
	for _, value := range []string{info.Channel, info.Uploader, info.Creator, info.Title} {
		if label := creatorLabel(value); label != "" {
			channel = label
			break
		}
	}
	return channel, creatorAvatar(info)
}

func creatorLabel(raw string) string {
	name := strings.TrimSpace(raw)
	lower := strings.ToLower(name)
	for _, suffix := range []string{" - videos", " - shorts", " - live", " - streams"} {
		if strings.HasSuffix(lower, suffix) {
			name = strings.TrimSpace(name[:len(name)-len(suffix)])
			lower = strings.ToLower(name)
		}
	}
	switch lower {
	case "", "videos", "shorts", "live", "streams":
		return ""
	}
	return name
}

func creatorAvatar(info mediaInfo) string {
	var fallback string
	for _, thumb := range info.Thumbnails {
		page := strings.TrimSpace(thumb.URL)
		id := strings.ToLower(strings.TrimSpace(thumb.ID))
		if strings.Contains(id, "banner") || !portraitURL(page) {
			continue
		}
		if strings.Contains(id, "avatar") {
			return page
		}
		if fallback == "" {
			fallback = page
		}
	}
	if portraitURL(info.Thumbnail) {
		return strings.TrimSpace(info.Thumbnail)
	}
	return fallback
}

func portraitURL(raw string) bool {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "http://") && !strings.HasPrefix(raw, "https://") {
		return false
	}
	host := strings.ToLower(raw)
	if parsed, err := url.Parse(raw); err == nil && parsed.Host != "" {
		host = strings.ToLower(parsed.Host)
	}
	if strings.Contains(host, "i.ytimg.com") || strings.Contains(host, "img.youtube.com") {
		return false
	}
	for _, part := range []string{"yt3.", "ggpht.com", "googleusercontent.com", "tiktokcdn", "fbcdn", "cdninstagram", "twimg.com"} {
		if strings.Contains(host, part) {
			return true
		}
	}
	return false
}

func entryThumbnail(info mediaInfo) string {
	if page := httpURL(info.Thumbnail); page != "" {
		return page
	}
	for _, thumb := range info.Thumbnails {
		id := strings.ToLower(strings.TrimSpace(thumb.ID))
		if strings.Contains(id, "avatar") || strings.Contains(id, "banner") {
			continue
		}
		if page := httpURL(thumb.URL); page != "" {
			return page
		}
	}
	return ""
}

func httpURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return raw
	}
	return ""
}

func firstHTTP(values ...string) string {
	for _, value := range values {
		value = strings.TrimSpace(value)
		if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") {
			return value
		}
	}
	return ""
}

func positiveDuration(value *int64) *int {
	if value == nil || *value <= 0 {
		return nil
	}
	seconds := int(*value)
	return &seconds
}
