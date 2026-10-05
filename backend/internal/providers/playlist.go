package providers

import (
	"context"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

const playlistLimit = 40

// FlatPlaylist lists public playlist entries without downloading media.
func (r *Runner) FlatPlaylist(ctx context.Context, rawURL string) ([]models.PlaylistEntry, error) {
	if err := r.available(); err != nil {
		return nil, err
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
		return nil, MapExtractorError(stderr+"\n"+err.Error(), rawURL)
	}
	return decodePlaylist(stdout, rawURL)
}

func decodePlaylist(stdout, pageURL string) ([]models.PlaylistEntry, error) {
	info, err := decodeInfo(stdout)
	if err != nil {
		return nil, err
	}
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
			Title:    title,
			URL:      page,
			Duration: positiveDuration(info.Duration.N),
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
			Title:    title,
			URL:      page,
			Duration: positiveDuration(entry.Duration.N),
		})
	}
	if len(items) == 0 {
		return nil, errs.RemovedVideo()
	}
	return items, nil
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
