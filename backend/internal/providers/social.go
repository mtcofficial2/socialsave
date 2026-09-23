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
