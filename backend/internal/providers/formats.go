package providers

import (
	"strconv"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

var qualitySteps = []int{360, 480, 720, 1080, 1440, 2160}

// bestFormat is the highest video plus the highest audio, then a single file.
// It does not prefer a codec, a bitrate, or a frame rate.
const bestFormat = "bv*+ba/b"

// RequestedMaxHeight maps a Flutter format id onto a height cap.
// original and best are uncapped. auto uses the configured default.
func RequestedMaxHeight(formatID string, defaultMax int) *int {
	quality := strings.ToLower(strings.TrimSpace(formatID))
	if quality == "" {
		quality = "auto"
	}
	switch quality {
	case "original", "best":
		return nil
	case "auto", "default":
		return &defaultMax
	case "4k":
		height := 2160
		return &height
	}
	if strings.HasSuffix(quality, "p") {
		if n, err := strconv.Atoi(strings.TrimSuffix(quality, "p")); err == nil && n > 0 {
			return &n
		}
	}
	return &defaultMax
}

// FormatSelector is the yt-dlp -f expression for a prepare-local job.
func FormatSelector(formatID string, hasFFmpeg bool, maxHeight int) string {
	quality := strings.ToLower(strings.TrimSpace(formatID))
	if quality == "" || quality == "auto" || quality == "default" {
		quality = strconv.Itoa(maxHeight) + "p"
	}
	if hasFFmpeg {
		// Many small pieces in parallel. One combined file is what YouTube throttles.
		mapping := map[string]string{
			"360p":     dashFirst(360),
			"480p":     dashFirst(480),
			"720p":     dashFirst(720),
			"1080p":    dashFirst(1080),
			"1440p":    dashFirst(1440),
			"2160p":    dashFirst(2160),
			"4k":       dashFirst(2160),
			"original": bestFormat + "/b",
		}
		if selector, ok := mapping[quality]; ok {
			return selector
		}
		if selector, ok := mapping[strconv.Itoa(maxHeight)+"p"]; ok {
			return selector
		}
		return bestFormat
	}
	mapping := map[string]string{
		"360p":     "best[height<=360][acodec!=none][vcodec!=none]/best[height<=360]/best",
		"480p":     "best[height<=480][acodec!=none][vcodec!=none]/best[height<=480]/best",
		"720p":     "best[height<=720][acodec!=none][vcodec!=none]/best[height<=720]/best",
		"1080p":    "best[height<=1080][acodec!=none][vcodec!=none]/best[height<=1080]/best",
		"1440p":    "best[height<=1440][acodec!=none][vcodec!=none]/best[height<=1440]/best",
		"2160p":    "best[height<=2160][acodec!=none][vcodec!=none]/best[height<=2160]/best",
		"original": "best[acodec!=none][vcodec!=none]/best",
	}
	if selector, ok := mapping[quality]; ok {
		return selector
	}
	if selector, ok := mapping[strconv.Itoa(maxHeight)+"p"]; ok {
		return selector
	}
	return mapping["480p"]
}

func dashFirst(height int) string {
	limit := strconv.Itoa(height)
	return "bv*[height<=" + limit + "]+ba/" +
		"b[height<=" + limit + "][acodec!=none][vcodec!=none]/" +
		"b[height<=" + limit + "]/b"
}

type mediaInfo struct {
	Type        string         `json:"_type"`
	Title       string         `json:"title"`
	Thumbnail   string         `json:"thumbnail"`
	Duration    flexInt        `json:"duration"`
	Uploader    string         `json:"uploader"`
	Creator     string         `json:"creator"`
	Channel     string         `json:"channel"`
	Ext         string         `json:"ext"`
	Width       flexInt        `json:"width"`
	Height      flexInt        `json:"height"`
	Filesize    flexInt        `json:"filesize"`
	FilesizeAp  flexInt        `json:"filesize_approx"`
	URL         string         `json:"url"`
	VCodec      string         `json:"vcodec"`
	ACodec      string         `json:"acodec"`
	Protocol    string         `json:"protocol"`
	TBR         float64        `json:"tbr"`
	HTTPHeaders map[string]any `json:"http_headers"`
	Formats     []mediaInfo    `json:"formats"`
	Entries     []mediaInfo    `json:"entries"`
}

func (info mediaInfo) size() *int64 {
	if info.Filesize.N != nil && *info.Filesize.N > 0 {
		return info.Filesize.N
	}
	return nil
}

func bestAudioSize(formats []mediaInfo) *int64 {
	var best *int64
	for _, item := range formats {
		if !hasAudio(item) || hasVideo(item) {
			continue
		}
		size := item.size()
		if size == nil {
			continue
		}
		if best == nil || *size > *best {
			best = size
		}
	}
	return best
}

func withAudioSize(video mediaInfo, audio *int64) *int64 {
	size := video.size()
	if size == nil {
		return nil
	}
	if hasAudio(video) || audio == nil {
		return size
	}
	sum := *size + *audio
	return &sum
}

func unwrapInfo(info mediaInfo) (mediaInfo, error) {
	if info.Type == "playlist" {
		if len(info.Entries) == 0 {
			return mediaInfo{}, errs.RemovedVideo()
		}
		return info.Entries[0], nil
	}
	return info, nil
}

// BuildFormats groups yt-dlp formats into the qualities Flutter shows.
func BuildFormats(info mediaInfo) []models.MediaFormat {
	heights := map[int]mediaInfo{}
	for _, item := range info.Formats {
		if !hasVideo(item) || item.Height.N == nil || *item.Height.N <= 0 {
			continue
		}
		height := int(*item.Height.N)
		bucket := 2160
		for _, step := range qualitySteps {
			if height <= step {
				bucket = step
				break
			}
		}
		current, ok := heights[bucket]
		if !ok || item.TBR > current.TBR {
			heights[bucket] = item
		}
	}
	ext := strings.TrimPrefix(info.Ext, ".")
	if ext == "" {
		ext = "mp4"
	}
	audioSize := bestAudioSize(info.Formats)
	var originalSize *int64
	if best, ok := heights[1080]; ok {
		originalSize = withAudioSize(best, audioSize)
	} else {
		for i := len(qualitySteps) - 1; i >= 0; i-- {
			if item, ok := heights[qualitySteps[i]]; ok {
				originalSize = withAudioSize(item, audioSize)
				break
			}
		}
		if originalSize == nil {
			originalSize = withAudioSize(info, audioSize)
		}
	}
	formats := []models.MediaFormat{{
		ID:       "original",
		Quality:  "original",
		Format:   ext,
		Filesize: originalSize,
		Width:    positiveInt(info.Width.N),
		Height:   positiveInt(info.Height.N),
		HasAudio: true,
		HasVideo: true,
	}}
	for i := len(qualitySteps) - 1; i >= 0; i-- {
		step := qualitySteps[i]
		item, ok := heights[step]
		if !ok {
			continue
		}
		itemExt := strings.TrimPrefix(item.Ext, ".")
		if itemExt != "mp4" && itemExt != "webm" && itemExt != "mov" && itemExt != "m4v" && itemExt != "mkv" {
			itemExt = "mp4"
		}
		formats = append(formats, models.MediaFormat{
			ID:       strconv.Itoa(step) + "p",
			Quality:  strconv.Itoa(step) + "p",
			Format:   itemExt,
			Filesize: withAudioSize(item, audioSize),
			Width:    positiveInt(item.Width.N),
			Height:   positiveInt(item.Height.N),
			HasAudio: hasAudio(item) || audioSize != nil,
			HasVideo: true,
		})
	}
	formats = append(formats, models.MediaFormat{
		ID:       "auto",
		Quality:  "auto",
		Format:   "mp4",
		Filesize: originalSize,
		Width:    positiveInt(info.Width.N),
		Height:   positiveInt(info.Height.N),
		HasAudio: true,
		HasVideo: true,
	})
	return formats
}

type progressive struct {
	URL      string
	Ext      string
	Height   int
	Filesize *int64
	Headers  map[string]string
}

// PickProgressive chooses a single file URL that already contains audio and video.
func PickProgressive(info mediaInfo, maxHeight *int) *progressive {
	var progressiveItems []mediaInfo
	for _, item := range info.Formats {
		if !strings.HasPrefix(item.URL, "http") {
			continue
		}
		protocol := item.Protocol
		if strings.HasPrefix(protocol, "m3u8") || strings.HasPrefix(protocol, "http_dash") || strings.Contains(item.URL, ".m3u8") {
			continue
		}
		if !hasVideo(item) || !hasAudio(item) {
			continue
		}
		progressiveItems = append(progressiveItems, item)
	}
	if len(progressiveItems) == 0 && strings.HasPrefix(info.URL, "http") && hasVideo(info) && hasAudio(info) {
		return &progressive{
			URL:      info.URL,
			Ext:      fallbackExt(info.Ext),
			Height:   heightOf(info),
			Filesize: info.size(),
			Headers:  stringMap(info.HTTPHeaders),
		}
	}
	if len(progressiveItems) == 0 {
		return nil
	}
	if maxHeight != nil {
		var capped []mediaInfo
		for _, item := range progressiveItems {
			if item.Height.N == nil || int(*item.Height.N) <= *maxHeight {
				capped = append(capped, item)
			}
		}
		if len(capped) > 0 {
			progressiveItems = capped
		}
	}
	best := progressiveItems[0]
	for _, item := range progressiveItems[1:] {
		if betterStream(item, best) {
			best = item
		}
	}
	headers := stringMap(best.HTTPHeaders)
	if len(headers) == 0 {
		headers = stringMap(info.HTTPHeaders)
	}
	return &progressive{
		URL:      best.URL,
		Ext:      fallbackExt(firstNonEmpty(best.Ext, info.Ext)),
		Height:   heightOf(best),
		Filesize: best.size(),
		Headers:  headers,
	}
}

// bestVideoHeight is the tallest video at or under the requested cap.
// A nil cap means the tallest video of any size.
func bestVideoHeight(info mediaInfo, maxHeight *int) int {
	best := 0
	consider := func(item mediaInfo) {
		if !hasVideo(item) {
			return
		}
		height := heightOf(item)
		if height <= 0 {
			return
		}
		if maxHeight != nil && height > *maxHeight {
			return
		}
		if height > best {
			best = height
		}
	}
	consider(info)
	for _, item := range info.Formats {
		consider(item)
	}
	return best
}

// preferDirectFile reports whether a single-file URL is as tall as the best
// available video. A shorter file is not used in place of a taller one.
func directFromInfo(info mediaInfo, rawURL, formatID, title string, cfg config.Config) (Handle, bool, error) {
	maxHeight := RequestedMaxHeight(formatID, cfg.DefaultMaxHeight)
	stream := PickProgressive(info, maxHeight)
	if stream == nil || !strings.HasPrefix(stream.URL, "http") || needsSession(stream.URL, stream.Headers) {
		return Handle{}, false, nil
	}
	if !preferDirectFile(stream.Height, bestVideoHeight(info, maxHeight)) {
		return Handle{}, false, nil
	}
	if stream.Filesize != nil && *stream.Filesize > cfg.MaxDownloadBytes {
		return Handle{}, false, errs.FileTooLarge(cfg.MaxDownloadBytes)
	}
	ext := strings.TrimPrefix(stream.Ext, ".")
	if ext == "" {
		ext = "mp4"
	}
	return Handle{
		SourceURL:   rawURL,
		FormatID:    formatID,
		MimeType:    mimeForExt(ext),
		Filesize:    stream.Filesize,
		FileName:    title + "." + ext,
		UpstreamURL: stream.URL,
		Headers:     publicHeaders(baseHeaders(rawURL), stream.Headers),
		Proxy:       false,
	}, true, nil
}

func preferDirectFile(progressiveHeight, bestHeight int) bool {
	if bestHeight <= 0 {
		return true
	}
	if progressiveHeight <= 0 {
		return false
	}
	return progressiveHeight >= bestHeight
}

func heightOf(item mediaInfo) int {
	if item.Height.N == nil || *item.Height.N <= 0 {
		return 0
	}
	return int(*item.Height.N)
}

func betterStream(item, best mediaInfo) bool {
	ih, bh := 0, 0
	if item.Height.N != nil {
		ih = int(*item.Height.N)
	}
	if best.Height.N != nil {
		bh = int(*best.Height.N)
	}
	if ih != bh {
		return ih > bh
	}
	return item.TBR > best.TBR
}

func hasAudio(item mediaInfo) bool {
	return item.ACodec != "" && item.ACodec != "none"
}

func hasVideo(item mediaInfo) bool {
	return item.VCodec != "" && item.VCodec != "none"
}

func fallbackExt(ext string) string {
	ext = strings.TrimPrefix(ext, ".")
	if ext == "" {
		return "mp4"
	}
	return ext
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func positiveInt(n *int64) *int {
	if n == nil || *n <= 0 {
		return nil
	}
	value := int(*n)
	return &value
}

func needsSession(streamURL string, headers map[string]string) bool {
	if !strings.Contains(streamURL, "tt_chain_token") {
		return false
	}
	cookie := headers["Cookie"]
	if cookie == "" {
		cookie = headers["cookie"]
	}
	return !strings.Contains(cookie, "tt_chain_token")
}

func authorOf(info mediaInfo) *string {
	for _, value := range []string{info.Uploader, info.Creator, info.Channel} {
		if strings.TrimSpace(value) != "" {
			value = strings.TrimSpace(value)
			return &value
		}
	}
	return nil
}

func thumbnailOf(info mediaInfo) *string {
	if strings.HasPrefix(info.Thumbnail, "http") {
		value := info.Thumbnail
		return &value
	}
	return nil
}

func durationOf(info mediaInfo) *int {
	if info.Duration.N == nil || *info.Duration.N < 0 {
		return nil
	}
	value := int(*info.Duration.N)
	return &value
}
