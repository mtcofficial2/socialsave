package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

const tiktokResolverURL = "https://api.getanyapi.com/v1/run/tiktok.video_download"

var tiktokVideoPath = regexp.MustCompile(`(?i)/(?:video|photo)/[0-9]+`)

// TikTok resolves public TikTok videos through AnyAPI.
// It does not call yt-dlp. Other platforms do not use this type.
type TikTok struct {
	cfg      config.Config
	client   *http.Client
	endpoint string
}

// NewTikTok builds the TikTok resolver.
func NewTikTok(cfg config.Config) *TikTok {
	timeout := cfg.RequestTimeout
	if timeout <= 0 {
		timeout = 25 * time.Second
	}
	return &TikTok{
		cfg:      cfg,
		endpoint: tiktokResolverURL,
		client:   &http.Client{Timeout: timeout},
	}
}

func (t *TikTok) ID() string             { return "tiktok" }
func (t *TikTok) SupportsMetadata() bool { return true }
func (t *TikTok) SupportsDownload() bool { return true }
func (t *TikTok) Notes() string          { return publicNote }
func (t *TikTok) CanHandle(rawURL string) bool {
	return hostMatches(hostOf(rawURL), "tiktok.com")
}

// Clip is one resolved TikTok video. VideoURL is the clean file, never the watermarked copy.
type Clip struct {
	VideoURL string
	Author   string
	Caption  string
	Duration int
	Width    int
	Height   int
	CoverURL string
}

// Response is the public JSON for POST /api/tiktok.
func (c Clip) Response() models.TikTokResponse {
	return models.TikTokResponse{
		Success:     true,
		Platform:    "tiktok",
		VideoURL:    c.VideoURL,
		Author:      c.Author,
		Caption:     c.Caption,
		Duration:    c.Duration,
		Width:       c.Width,
		Height:      c.Height,
		CoverURL:    c.CoverURL,
		Watermarked: false,
	}
}

// Lookup calls the TikTok resolver. It refuses any URL that is not a TikTok video link.
func (t *TikTok) Lookup(ctx context.Context, rawURL string) (Clip, error) {
	if !ValidTikTokVideoURL(rawURL) {
		return Clip{}, errs.InvalidURL("Paste a link to a public TikTok video.")
	}
	if strings.TrimSpace(t.cfg.AnyAPIKey) == "" {
		return Clip{}, errs.PlatformUnavailable("TikTok downloads are not configured on this server.")
	}
	payload, err := json.Marshal(map[string]string{"url": rawURL})
	if err != nil {
		return Clip{}, errs.PlatformUnavailable("")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.endpoint, bytes.NewReader(payload))
	if err != nil {
		return Clip{}, errs.PlatformUnavailable("")
	}
	req.Header.Set("Authorization", "Bearer "+t.cfg.AnyAPIKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	client := t.client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return Clip{}, errs.PlatformUnavailable("TikTok could not be reached. Try again in a moment.")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return Clip{}, errs.PlatformUnavailable("")
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return Clip{}, errs.PlatformUnavailable("TikTok resolver rejected the request.")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return Clip{}, errs.PlatformUnavailable("TikTok did not return this video.")
	}
	return parseTikTokClip(body)
}

func (t *TikTok) Analyze(ctx context.Context, rawURL string) (Metadata, error) {
	clip, err := t.Lookup(ctx, rawURL)
	if err != nil {
		return Metadata{}, err
	}
	title := strings.TrimSpace(clip.Caption)
	if title == "" {
		title = "TikTok video"
	}
	quality := "original"
	if clip.Height > 0 {
		quality = strconv.Itoa(clip.Height) + "p"
	}
	format := models.MediaFormat{
		ID:       "best",
		Quality:  quality,
		Format:   "mp4",
		HasAudio: true,
		HasVideo: true,
	}
	if clip.Width > 0 {
		width := clip.Width
		format.Width = &width
	}
	if clip.Height > 0 {
		height := clip.Height
		format.Height = &height
	}
	meta := Metadata{
		Platform:    "tiktok",
		Title:       title,
		SourceURL:   rawURL,
		Formats:     []models.MediaFormat{format},
		CanDownload: true,
	}
	if clip.CoverURL != "" {
		cover := clip.CoverURL
		meta.Thumbnail = &cover
	}
	if clip.Duration > 0 {
		duration := clip.Duration
		meta.Duration = &duration
	}
	if clip.Author != "" {
		author := clip.Author
		meta.Author = &author
	}
	return meta, nil
}

func (t *TikTok) CreateDownload(ctx context.Context, rawURL, formatID string) (Handle, error) {
	clip, err := t.Lookup(ctx, rawURL)
	if err != nil {
		return Handle{}, err
	}
	title := safeTitle(firstNonEmpty(clip.Caption, "tiktok"))
	return Handle{
		SourceURL:   rawURL,
		FormatID:    firstNonEmpty(formatID, "best"),
		MimeType:    "video/mp4",
		FileName:    title + ".mp4",
		UpstreamURL: clip.VideoURL,
		Headers:     baseHeaders(rawURL),
	}, nil
}

// ValidTikTokVideoURL reports whether rawURL is a TikTok video or short link.
func ValidTikTokVideoURL(rawURL string) bool {
	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" {
		return false
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return false
	}
	host := hostOf(rawURL)
	switch host {
	case "vm.tiktok.com", "vt.tiktok.com":
		return len(strings.Trim(parsed.Path, "/")) >= 4
	}
	if !hostMatches(host, "tiktok.com") {
		return false
	}
	path := parsed.EscapedPath()
	if tiktokVideoPath.MatchString(path) {
		return true
	}
	return strings.HasPrefix(path, "/t/") && len(strings.Trim(path, "/")) > 2
}

func parseTikTokClip(body []byte) (Clip, error) {
	var root map[string]any
	if err := json.Unmarshal(body, &root); err != nil {
		return Clip{}, errs.PlatformUnavailable("TikTok returned an unreadable response.")
	}
	data, _ := root["data"].(map[string]any)
	if data == nil {
		data = root
	}
	videoURL := firstString(data, "videoUrl", "video_url", "downloadUrl")
	if videoURL == "" {
		return Clip{}, errs.PlatformUnavailable("TikTok did not return a clean video file.")
	}
	if !strings.HasPrefix(videoURL, "http://") && !strings.HasPrefix(videoURL, "https://") {
		return Clip{}, errs.PlatformUnavailable("TikTok did not return a clean video file.")
	}
	author := authorString(data["author"])
	if author == "" {
		author = authorString(data["username"])
	}
	if author != "" && !strings.HasPrefix(author, "@") {
		author = "@" + author
	}
	caption := firstString(data, "caption", "title", "desc")
	return Clip{
		VideoURL: videoURL,
		Author:   author,
		Caption:  caption,
		Duration: anyInt(data["duration"]),
		Width:    anyInt(data["width"]),
		Height:   anyInt(data["height"]),
		CoverURL: firstString(data, "coverUrl", "cover", "thumbnail"),
	}, nil
}

func firstString(data map[string]any, keys ...string) string {
	for _, key := range keys {
		if text := authorString(data[key]); text != "" {
			return text
		}
	}
	return ""
}

func authorString(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case map[string]any:
		for _, key := range []string{"uniqueId", "username", "nickname", "name"} {
			if text, ok := typed[key].(string); ok && strings.TrimSpace(text) != "" {
				return strings.TrimSpace(text)
			}
		}
	}
	return ""
}

func anyInt(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case string:
		n, err := strconv.Atoi(strings.TrimSpace(typed))
		if err == nil {
			return n
		}
	}
	return 0
}
