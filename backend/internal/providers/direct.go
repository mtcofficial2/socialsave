package providers

import (
	"context"
	"net/url"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

var videoExtensions = map[string]struct{}{
	".mp4": {}, ".webm": {}, ".mov": {}, ".m4v": {}, ".mkv": {},
}

var allowedMIME = map[string]string{
	"video/mp4":                "mp4",
	"video/webm":               "webm",
	"video/quicktime":          "mov",
	"video/x-m4v":              "m4v",
	"video/x-matroska":         "mkv",
	"video/mpeg":               "mpg",
	"application/octet-stream": "",
}

// Direct serves public video files and, for other pages, the shared extractor.
type Direct struct {
	cfg    config.Config
	fetch  *Fetcher
	runner *Runner
}

func (d *Direct) ID() string             { return "direct" }
func (d *Direct) SupportsMetadata() bool { return true }
func (d *Direct) SupportsDownload() bool { return true }
func (d *Direct) Notes() string {
	return "Public video files and pages that expose a downloadable video."
}

func (d *Direct) CanHandle(rawURL string) bool {
	path := strings.ToLower(pathOf(rawURL))
	for ext := range videoExtensions {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	return false
}

func (d *Direct) Analyze(ctx context.Context, rawURL string) (Metadata, error) {
	if d.CanHandle(rawURL) {
		meta, err := d.analyzeFile(ctx, rawURL)
		if err == nil {
			return meta, nil
		}
		if api, ok := err.(*errs.Error); ok && (api.Code == "file_too_large" || api.Code == "invalid_url") {
			return Metadata{}, err
		}
		if d.runner != nil {
			return d.fromExtractor(ctx, rawURL)
		}
		return Metadata{}, err
	}
	if d.runner == nil {
		return Metadata{}, errs.UnsupportedFormat()
	}
	return d.fromExtractor(ctx, rawURL)
}

func (d *Direct) CreateDownload(ctx context.Context, rawURL, formatID string) (Handle, error) {
	if d.CanHandle(rawURL) {
		meta, err := d.analyzeFile(ctx, rawURL)
		if err == nil {
			format := "mp4"
			var size *int64
			if len(meta.Formats) > 0 {
				format = meta.Formats[0].Format
				size = meta.Formats[0].Filesize
			}
			if formatID == "" {
				formatID = "original"
			}
			return Handle{
				SourceURL:   rawURL,
				FormatID:    formatID,
				MimeType:    mimeForExt(format),
				Filesize:    size,
				FileName:    safeTitle(meta.Title) + "." + format,
				UpstreamURL: rawURL,
			}, nil
		}
	}
	if formatID == "" {
		formatID = "auto"
	}
	return Handle{
		SourceURL:      rawURL,
		FormatID:       formatID,
		MimeType:       "video/mp4",
		FileName:       "video.mp4",
		PrepareLocally: true,
	}, nil
}

func (d *Direct) analyzeFile(ctx context.Context, rawURL string) (Metadata, error) {
	title := fileTitle(rawURL)
	guessed := extFromPath(rawURL)
	resp, err := d.fetch.HeadOrRange(ctx, rawURL)
	if err != nil {
		if api, ok := err.(*errs.Error); ok && api.Code == "invalid_url" {
			return Metadata{}, err
		}
		return directMeta(title, rawURL, guessed, nil), nil
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return directMeta(title, rawURL, guessed, nil), nil
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(resp.Header.Get("Content-Type"), ";")[0]))
	format, err := formatFromMIME(contentType, rawURL)
	if err != nil {
		return Metadata{}, err
	}
	length := contentLength(resp.Header)
	if length != nil && *length > d.cfg.MaxDownloadBytes {
		return Metadata{}, errs.FileTooLarge(d.cfg.MaxDownloadBytes)
	}
	return directMeta(title, rawURL, format, length), nil
}

func (d *Direct) fromExtractor(ctx context.Context, rawURL string) (Metadata, error) {
	info, err := d.runner.Extract(ctx, rawURL, d.cfg)
	if err != nil {
		return Metadata{}, err
	}
	title := strings.TrimSpace(info.Title)
	if title == "" {
		title = "Direct URL video"
	}
	return Metadata{
		Platform:    "web",
		Title:       title,
		SourceURL:   rawURL,
		Thumbnail:   thumbnailOf(info),
		Duration:    durationOf(info),
		Author:      authorOf(info),
		Formats:     BuildFormats(info),
		CanDownload: true,
	}, nil
}

func directMeta(title, rawURL, format string, size *int64) Metadata {
	return Metadata{
		Platform:  "direct",
		Title:     title,
		SourceURL: rawURL,
		Formats: []models.MediaFormat{{
			ID:       "original",
			Quality:  "original",
			Format:   format,
			Filesize: size,
			HasAudio: true,
			HasVideo: true,
		}},
		CanDownload: true,
	}
}

func formatFromMIME(contentType, rawURL string) (string, error) {
	guessed := extFromPath(rawURL)
	if contentType == "" {
		return guessed, nil
	}
	if strings.HasPrefix(contentType, "text/html") || strings.HasPrefix(contentType, "application/json") {
		return "", errs.UnsupportedFormat()
	}
	if format, ok := allowedMIME[contentType]; ok {
		if format == "" {
			return guessed, nil
		}
		return format, nil
	}
	if strings.HasPrefix(contentType, "video/") {
		return strings.TrimPrefix(contentType, "video/"), nil
	}
	return "", errs.UnsupportedFormat()
}

func extFromPath(rawURL string) string {
	path := strings.ToLower(pathOf(rawURL))
	for ext := range videoExtensions {
		if strings.HasSuffix(path, ext) {
			return strings.TrimPrefix(ext, ".")
		}
	}
	return "mp4"
}

func fileTitle(rawURL string) string {
	name := pathOf(rawURL)
	if i := strings.LastIndex(name, "/"); i >= 0 {
		name = name[i+1:]
	}
	if name == "" {
		return "video"
	}
	if i := strings.LastIndex(name, "."); i > 0 {
		name = name[:i]
	}
	if name == "" {
		return "video"
	}
	return name
}

func pathOf(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return parsed.Path
}
