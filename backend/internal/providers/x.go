package providers

import (
	"context"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

var tweetIDPattern = regexp.MustCompile(`/(?:status|statuses)/(\d+)`)

type xPayload struct {
	Data struct {
		Text     string `json:"text"`
		AuthorID string `json:"author_id"`
	} `json:"data"`
	Includes struct {
		Users []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"users"`
		Media []xMedia `json:"media"`
	} `json:"includes"`
}

type xMedia struct {
	Type            string     `json:"type"`
	URL             string     `json:"url"`
	PreviewImageURL string     `json:"preview_image_url"`
	DurationMS      int        `json:"duration_ms"`
	Height          int        `json:"height"`
	Width           int        `json:"width"`
	Variants        []xVariant `json:"variants"`
}

type xVariant struct {
	BitRate     int    `json:"bit_rate"`
	ContentType string `json:"content_type"`
	URL         string `json:"url"`
}

func (s *Social) analyzeX(ctx context.Context, rawURL string) (Metadata, error) {
	payload, err := s.loadTweet(ctx, rawURL)
	if err != nil {
		return Metadata{}, err
	}
	return payload.asMetadata(rawURL), nil
}

func (s *Social) downloadX(ctx context.Context, rawURL, formatID string) (Handle, bool, error) {
	payload, err := s.loadTweet(ctx, rawURL)
	if err != nil {
		return Handle{}, false, err
	}
	video := payload.video()
	variant := video.bestMP4()
	if variant == nil {
		return Handle{}, false, nil
	}
	meta := payload.asMetadata(rawURL)
	ext := "mp4"
	return Handle{
		SourceURL:   rawURL,
		FormatID:    formatID,
		MimeType:    "video/mp4",
		FileName:    safeTitle(meta.Title) + "." + ext,
		UpstreamURL: variant.URL,
		Headers:     baseHeaders(rawURL),
	}, true, nil
}

func (s *Social) loadTweet(ctx context.Context, rawURL string) (xPayload, error) {
	id := tweetID(rawURL)
	if id == "" {
		return xPayload{}, errs.InvalidURL("That URL is not a valid X post link.")
	}
	endpoint := "https://api.twitter.com/2/tweets/" + url.PathEscape(id) +
		"?expansions=attachments.media_keys,author_id" +
		"&tweet.fields=attachments,text" +
		"&media.fields=duration_ms,height,preview_image_url,type,url,variants,width" +
		"&user.fields=name,username"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return xPayload{}, errs.InvalidURL("That URL is not valid.")
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.XBearerToken)
	req.Header.Set("User-Agent", browserUA)
	if _, err := s.fetch.Validator.Validate(ctx, endpoint); err != nil {
		return xPayload{}, err
	}
	resp, err := s.fetch.Client.Do(req)
	if err != nil {
		return xPayload{}, errs.PlatformUnavailable("")
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode == http.StatusNotFound {
		return xPayload{}, errs.RemovedVideo()
	}
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return xPayload{}, errs.PlatformUnavailable("")
	}
	if resp.StatusCode >= 500 || resp.StatusCode >= 400 {
		return xPayload{}, errs.PlatformUnavailable("")
	}
	var payload xPayload
	if err := jsonUnmarshal(body, &payload); err != nil || strings.TrimSpace(payload.Data.Text) == "" && len(payload.Includes.Media) == 0 {
		return xPayload{}, errs.PlatformUnavailable("")
	}
	return payload, nil
}

func (p xPayload) asMetadata(rawURL string) Metadata {
	title := strings.TrimSpace(p.Data.Text)
	if title == "" {
		title = "X post"
	}
	if len(title) > 140 {
		title = strings.TrimSpace(title[:140])
	}
	meta := Metadata{
		Platform:  "x",
		Title:     title,
		SourceURL: rawURL,
		Formats:   []models.MediaFormat{},
	}
	for _, user := range p.Includes.Users {
		if user.ID == p.Data.AuthorID && strings.TrimSpace(user.Name) != "" {
			name := user.Name
			meta.Author = &name
			break
		}
	}
	video := p.video()
	if video == nil || video.bestMP4() == nil {
		meta.CanDownload = false
		meta.DownloadRestrictedReason = reasonPtr("This post does not contain a public downloadable video.")
		return meta
	}
	if video.PreviewImageURL != "" {
		thumb := video.PreviewImageURL
		meta.Thumbnail = &thumb
	}
	if video.DurationMS > 0 {
		seconds := video.DurationMS / 1000
		meta.Duration = &seconds
	}
	height := video.Height
	width := video.Width
	meta.Formats = []models.MediaFormat{{
		ID:       "original",
		Quality:  "original",
		Format:   "mp4",
		Width:    positive(width),
		Height:   positive(height),
		HasAudio: true,
		HasVideo: true,
	}, {
		ID:       "auto",
		Quality:  "auto",
		Format:   "mp4",
		Width:    positive(width),
		Height:   positive(height),
		HasAudio: true,
		HasVideo: true,
	}}
	if height > 0 {
		label := heightLabel(height)
		meta.Formats = append(meta.Formats, models.MediaFormat{
			ID:       label,
			Quality:  label,
			Format:   "mp4",
			Width:    positive(width),
			Height:   positive(height),
			HasAudio: true,
			HasVideo: true,
		})
	}
	meta.CanDownload = true
	return meta
}

func (p xPayload) video() *xMedia {
	for i := range p.Includes.Media {
		if strings.EqualFold(p.Includes.Media[i].Type, "video") || strings.EqualFold(p.Includes.Media[i].Type, "animated_gif") {
			return &p.Includes.Media[i]
		}
	}
	return nil
}

func (m *xMedia) bestMP4() *xVariant {
	if m == nil {
		return nil
	}
	var best *xVariant
	for i := range m.Variants {
		item := &m.Variants[i]
		if !strings.HasPrefix(item.URL, "http") {
			continue
		}
		if !strings.Contains(strings.ToLower(item.ContentType), "mp4") {
			continue
		}
		if best == nil || item.BitRate > best.BitRate {
			best = item
		}
	}
	return best
}

func tweetID(rawURL string) string {
	match := tweetIDPattern.FindStringSubmatch(rawURL)
	if match == nil {
		return ""
	}
	return match[1]
}

func positive(n int) *int {
	if n <= 0 {
		return nil
	}
	return &n
}

func heightLabel(height int) string {
	steps := []int{360, 480, 720, 1080, 1440, 2160}
	for _, step := range steps {
		if height <= step {
			return itoa(step) + "p"
		}
	}
	return "2160p"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
