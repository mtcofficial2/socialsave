package providers

import (
	"context"
	"errors"
	"net/url"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

// Social is a platform whose public files are resolved with yt-dlp.
type Social struct {
	id      string
	display string
	hosts   []string
	notes   string
	cfg     config.Config
	fetch   *Fetcher
	runner  *Runner
}

func (s *Social) ID() string             { return s.id }
func (s *Social) SupportsMetadata() bool { return true }
func (s *Social) SupportsDownload() bool { return true }
func (s *Social) Notes() string          { return s.notes }
func (s *Social) CanHandle(rawURL string) bool {
	return hostMatches(hostOf(rawURL), s.hosts...)
}

func (s *Social) Analyze(ctx context.Context, rawURL string) (Metadata, error) {
	if s.id == "x" && s.cfg.XBearerToken != "" {
		meta, err := s.analyzeX(ctx, rawURL)
		if err == nil {
			return meta, nil
		}
		if hardOfficial(err) {
			return Metadata{}, err
		}
	}
	info, err := s.runner.Extract(ctx, rawURL, s.cfg)
	if err != nil {
		if fallback, ok := s.officialFallback(ctx, rawURL, err); ok {
			return fallback, nil
		}
		return Metadata{}, err
	}
	title := strings.TrimSpace(info.Title)
	if title == "" {
		title = s.display + " video"
	}
	return Metadata{
		Platform:    s.id,
		Title:       title,
		SourceURL:   rawURL,
		Thumbnail:   thumbnailOf(info),
		Duration:    durationOf(info),
		Author:      authorOf(info),
		Formats:     BuildFormats(info),
		CanDownload: true,
	}, nil
}

func (s *Social) CreateDownload(ctx context.Context, rawURL, formatID string) (Handle, error) {
	if formatID == "" {
		formatID = "auto"
	}
	if formatID == "preview" {
		info, err := s.runner.Extract(ctx, rawURL, s.cfg)
		if err == nil {
			title := safeTitle(firstNonEmpty(info.Title, "video"))
			// 1.0.45: Preview starts from one muxed progressive file at a
			// moderate size (up to 720p), even when a sharper split
			// video+audio exists, so playback starts at once with no merge.
			if handle, ok := previewDirect(info, rawURL, title); ok {
				return handle, nil
			}
			if handle, ok, directErr := directFromInfo(info, rawURL, "auto", title, s.cfg); directErr != nil || ok {
				return handle, directErr
			}
		}
		return Handle{
			SourceURL: rawURL,
			FormatID:  "preview",
			MimeType:  "video/mp4",
			FileName:  "preview.mp4",
			Stream:    true,
		}, nil
	}
	if s.id == "x" && s.cfg.XBearerToken != "" {
		handle, ok, err := s.downloadX(ctx, rawURL, formatID)
		if err != nil && hardOfficial(err) {
			return Handle{}, err
		}
		if ok {
			handle.Proxy = false
			return handle, nil
		}
	}
	info, err := s.runner.Extract(ctx, rawURL, s.cfg)
	if err != nil {
		return Handle{}, err
	}
	title := safeTitle(firstNonEmpty(info.Title, "video"))
	if handle, ok, err := directFromInfo(info, rawURL, formatID, title, s.cfg); err != nil || ok {
		return handle, err
	}
	return Handle{
		SourceURL:      rawURL,
		FormatID:       formatID,
		MimeType:       "video/mp4",
		FileName:       title + ".mp4",
		PrepareLocally: true,
	}, nil
}

func (s *Social) officialFallback(ctx context.Context, rawURL string, cause error) (Metadata, bool) {
	if errorCode(cause) != "platform_unavailable" {
		return Metadata{}, false
	}
	var token, endpoint string
	switch s.id {
	case "instagram":
		token = s.cfg.InstagramToken
		endpoint = "https://graph.facebook.com/v21.0/instagram_oembed?url="
	case "facebook":
		token = s.cfg.FacebookToken
		endpoint = "https://graph.facebook.com/v21.0/oembed_video?url="
	default:
		return Metadata{}, false
	}
	if token == "" {
		return Metadata{}, false
	}
	var doc oEmbedDoc
	full := endpoint + url.QueryEscape(rawURL) + "&access_token=" + url.QueryEscape(token)
	if err := s.fetch.GetJSON(ctx, full, nil, &doc); err != nil || strings.TrimSpace(doc.Title) == "" {
		return Metadata{}, false
	}
	meta := Metadata{
		Platform:                 s.id,
		Title:                    doc.Title,
		SourceURL:                rawURL,
		Formats:                  []models.MediaFormat{},
		CanDownload:              false,
		DownloadRestrictedReason: reasonPtr(messageOf(cause)),
	}
	applyOEmbed(&meta, doc)
	return meta, true
}

func hardOfficial(err error) bool {
	switch errorCode(err) {
	case "private_video", "removed_video", "invalid_url", "download_not_permitted", "file_too_large":
		return true
	default:
		return false
	}
}

func messageOf(err error) string {
	var api *errs.Error
	if errors.As(err, &api) {
		return api.Message
	}
	if err == nil {
		return ""
	}
	return err.Error()
}

// previewDirect picks a single progressive (video+audio) stream of at most
// 720p for Preview. ok is false when there is none that plays without a
// session cookie.
func previewDirect(info mediaInfo, rawURL, title string) (Handle, bool) {
	limit := 720
	stream := PickProgressive(info, &limit)
	if stream == nil || !strings.HasPrefix(stream.URL, "http") || needsSession(stream.URL, stream.Headers) {
		return previewSplit(info, rawURL, title, limit)
	}
	ext := strings.TrimPrefix(stream.Ext, ".")
	if ext == "" {
		ext = "mp4"
	}
	return Handle{
		SourceURL:   rawURL,
		FormatID:    "preview",
		MimeType:    mimeForExt(ext),
		Filesize:    stream.Filesize,
		FileName:    title + "." + ext,
		UpstreamURL: stream.URL,
		Headers:     publicHeaders(baseHeaders(rawURL), stream.Headers),
	}, true
}

// previewSplit (YouTube has no muxed files any more): one plain-HTTPS
// video-only stream of at most limit p (H.264 first, it starts fastest) plus
// the best M4A audio. The player adds the audio as an external track, so
// nothing is merged before the first frame.
func previewSplit(info mediaInfo, rawURL, title string, limit int) (Handle, bool) {
	plain := func(item mediaInfo) bool {
		return strings.HasPrefix(item.URL, "http") &&
			!strings.HasPrefix(item.Protocol, "m3u8") &&
			!strings.HasPrefix(item.Protocol, "http_dash") &&
			!strings.Contains(item.URL, ".m3u8")
	}
	score := func(item mediaInfo) int {
		h := heightOf(item)
		v := h * 10
		if strings.HasPrefix(item.VCodec, "avc1") {
			v += 5
		}
		return v
	}
	var video, audio *mediaInfo
	for i := range info.Formats {
		item := info.Formats[i]
		if !plain(item) {
			continue
		}
		if hasVideo(item) && !hasAudio(item) {
			h := heightOf(item)
			if h <= 0 || h > limit {
				continue
			}
			if video == nil || score(item) > score(*video) {
				video = &info.Formats[i]
			}
		}
		if hasAudio(item) && !hasVideo(item) && strings.EqualFold(strings.TrimPrefix(item.Ext, "."), "m4a") {
			if audio == nil || item.TBR > audio.TBR {
				audio = &info.Formats[i]
			}
		}
	}
	if video == nil || audio == nil {
		return Handle{}, false
	}
	vh, ah := stringMap(video.HTTPHeaders), stringMap(audio.HTTPHeaders)
	if needsSession(video.URL, vh) || needsSession(audio.URL, ah) {
		return Handle{}, false
	}
	return Handle{
		SourceURL:   rawURL,
		FormatID:    "preview",
		MimeType:    "video/mp4",
		Filesize:    video.size(),
		FileName:    title + ".mp4",
		UpstreamURL: video.URL,
		AudioURL:    audio.URL,
		Headers:     publicHeaders(baseHeaders(rawURL), vh),
	}, true
}
