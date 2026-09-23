package providers

import (
	"context"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

// YouTube reads public metadata from oEmbed and, when configured, the
// official Data API. It does not download videos or call alternate frontends.
type YouTube struct {
	cfg   config.Config
	fetch *Fetcher
}

func (y *YouTube) ID() string             { return "youtube" }
func (y *YouTube) SupportsMetadata() bool { return true }
func (y *YouTube) SupportsDownload() bool { return false }
func (y *YouTube) Notes() string {
	return "Metadata comes from YouTube. Third-party download is not permitted."
}

func (y *YouTube) CanHandle(rawURL string) bool {
	return isYouTubeHost(hostOf(rawURL))
}

func (y *YouTube) Analyze(ctx context.Context, rawURL string) (Metadata, error) {
	videoID := youtubeVideoID(rawURL)
	if videoID == "" {
		return Metadata{}, errs.InvalidURL("That URL is not a valid YouTube video link.")
	}
	meta := Metadata{
		Platform:                 y.ID(),
		Title:                    "YouTube video",
		SourceURL:                rawURL,
		Formats:                  []models.MediaFormat{},
		CanDownload:              false,
		DownloadRestrictedReason: reasonPtr(errs.DownloadNotPermitted().Message),
	}
	oembed, oembedErr := y.oEmbed(ctx, rawURL)
	if oembedErr == nil {
		applyOEmbed(&meta, oembed)
	}
	var apiErr error
	if y.cfg.YouTubeAPIKey != "" {
		apiErr = y.dataAPI(ctx, videoID, &meta)
		if errorCode(apiErr) == "private_video" {
			return Metadata{}, apiErr
		}
	}
	if oembedErr == nil || meta.Title != "YouTube video" || meta.Duration != nil || meta.Author != nil {
		return meta, nil
	}
	if apiErr != nil {
		return Metadata{}, apiErr
	}
	if oembedErr != nil {
		return Metadata{}, oembedErr
	}
	return meta, nil
}

func (y *YouTube) CreateDownload(context.Context, string, string) (Handle, error) {
	return Handle{}, errs.DownloadNotPermitted()
}

func (y *YouTube) oEmbed(ctx context.Context, rawURL string) (oEmbedDoc, error) {
	endpoint := "https://www.youtube.com/oembed?format=json&url=" + url.QueryEscape(rawURL)
	var doc oEmbedDoc
	if err := y.fetch.GetJSON(ctx, endpoint, nil, &doc); err != nil {
		return oEmbedDoc{}, err
	}
	if strings.TrimSpace(doc.Title) == "" {
		return oEmbedDoc{}, errs.RemovedVideo()
	}
	return doc, nil
}

func (y *YouTube) dataAPI(ctx context.Context, videoID string, meta *Metadata) error {
	endpoint := "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails,status&id=" +
		url.QueryEscape(videoID) + "&key=" + url.QueryEscape(y.cfg.YouTubeAPIKey)
	var payload youtubeList
	if err := y.fetch.GetJSON(ctx, endpoint, nil, &payload); err != nil {
		return err
	}
	if len(payload.Items) == 0 {
		return errs.RemovedVideo()
	}
	item := payload.Items[0]
	switch strings.ToLower(item.Status.PrivacyStatus) {
	case "private":
		return errs.PrivateVideo("This YouTube video is private, age-restricted, or members-only.")
	}
	if title := strings.TrimSpace(item.Snippet.Title); title != "" {
		meta.Title = title
	}
	if author := strings.TrimSpace(item.Snippet.ChannelTitle); author != "" {
		meta.Author = &author
	}
	if thumb := item.Snippet.Thumbnails.best(); thumb != "" {
		meta.Thumbnail = &thumb
	}
	if seconds, ok := parseISODuration(item.ContentDetails.Duration); ok {
		meta.Duration = &seconds
	}
	return nil
}

type oEmbedDoc struct {
	Title        string `json:"title"`
	AuthorName   string `json:"author_name"`
	ThumbnailURL string `json:"thumbnail_url"`
}

func applyOEmbed(meta *Metadata, doc oEmbedDoc) {
	if title := strings.TrimSpace(doc.Title); title != "" {
		meta.Title = title
	}
	if author := strings.TrimSpace(doc.AuthorName); author != "" {
		meta.Author = &author
	}
	if thumb := strings.TrimSpace(doc.ThumbnailURL); strings.HasPrefix(thumb, "http") {
		meta.Thumbnail = &thumb
	}
}

type youtubeList struct {
	Items []struct {
		Snippet struct {
			Title        string `json:"title"`
			ChannelTitle string `json:"channelTitle"`
			Thumbnails   thumbs `json:"thumbnails"`
		} `json:"snippet"`
		ContentDetails struct {
			Duration string `json:"duration"`
		} `json:"contentDetails"`
		Status struct {
			PrivacyStatus string `json:"privacyStatus"`
		} `json:"status"`
	} `json:"items"`
}

type thumbs struct {
	MaxRes  thumb `json:"maxres"`
	High    thumb `json:"high"`
	Medium  thumb `json:"medium"`
	Default thumb `json:"default"`
}

type thumb struct {
	URL string `json:"url"`
}

func (t thumbs) best() string {
	for _, item := range []thumb{t.MaxRes, t.High, t.Medium, t.Default} {
		if strings.HasPrefix(item.URL, "http") {
			return item.URL
		}
	}
	return ""
}

var youtubeIDPattern = regexp.MustCompile(`(?i)(?:youtu\.be/|youtube(?:-nocookie)?\.com/(?:embed/|shorts/|live/|v/|watch\?v=))([A-Za-z0-9_-]{11})`)
var isoDuration = regexp.MustCompile(`^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$`)

func youtubeVideoID(rawURL string) string {
	if match := youtubeIDPattern.FindStringSubmatch(rawURL); match != nil {
		return match[1]
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	if id := parsed.Query().Get("v"); len(id) == 11 {
		return id
	}
	return ""
}

func parseISODuration(value string) (int, bool) {
	match := isoDuration.FindStringSubmatch(strings.ToUpper(strings.TrimSpace(value)))
	if match == nil {
		return 0, false
	}
	hours, _ := strconv.Atoi(match[1])
	minutes, _ := strconv.Atoi(match[2])
	seconds, _ := strconv.Atoi(match[3])
	total := hours*3600 + minutes*60 + seconds
	if total == 0 && value != "PT0S" && !strings.Contains(value, "0") {
		return 0, false
	}
	return total, true
}

func reasonPtr(message string) *string {
	return &message
}

func errorCode(err error) string {
	var api *errs.Error
	if errors.As(err, &api) {
		return api.Code
	}
	return ""
}
