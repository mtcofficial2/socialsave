package providers

import (
	"regexp"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

var extractorName = regexp.MustCompile(`\[([a-z0-9_]+)\]`)

// MapExtractorError classifies stderr from yt-dlp into the API error codes.
func MapExtractorError(text, pageURL string) *errs.Error {
	lower := strings.ToLower(text)
	extractor := ""
	if match := extractorName.FindStringSubmatch(lower); match != nil {
		extractor = match[1]
	}
	tiktokLogin := strings.Contains(lower, "not be comfortable") ||
		strings.Contains(lower, "some audiences") ||
		strings.Contains(lower, "log in for access")
	if extractor == "tiktok" || (isTikTok(pageURL) && tiktokLogin) {
		if tiktokLogin || strings.Contains(lower, "login") || strings.Contains(lower, "sign in") {
			return errs.PrivateVideo("TikTok is hiding this video behind a login or content warning. Try a fully public TikTok that opens while logged out.")
		}
	}
	if extractor == "youtube" || isYouTubeHost(hostOf(pageURL)) {
		// "Sign in to confirm you're not a bot" is YouTube rate-limiting the
		// network (the hosted server's data-centre IP gets it all the time),
		// not a private video. Each case now gets its own message.
		if containsAny(lower, "not a bot", "not a robot", "bot check") {
			return errs.PlatformUnavailable("YouTube is asking this network for a bot check, so it refused the request. The video itself is fine. Wait a minute and retry, or try another network.")
		}
		if containsAny(lower, "private video", "this video is private") {
			return errs.PrivateVideo("This YouTube video is private.")
		}
		if containsAny(lower, "members-only", "members only", "join this channel") {
			return errs.PrivateVideo("This YouTube video is for channel members only.")
		}
		if containsAny(lower, "age-restricted", "confirm your age", "inappropriate for some users") {
			return errs.PrivateVideo("This YouTube video is age-restricted, so YouTube only shows it to signed-in adults.")
		}
		if containsAny(lower, "not made this video available in your country", "not available in your country") {
			return errs.PlatformUnavailable("This YouTube video is not available in your country.")
		}
		if containsAny(lower, "video unavailable", "this video is not available", "account associated with this video has been terminated") {
			return errs.RemovedVideo()
		}
		if containsAny(lower, "live event will begin", "premieres in", "this live event") {
			return errs.PlatformUnavailable("This YouTube video has not started yet. Try again after it goes live.")
		}
		if containsAny(lower, "requested format is not available", "only images are available") {
			return errs.PlatformUnavailable("YouTube did not offer a downloadable stream for this video. Update the engine in Settings, then retry.")
		}
		if strings.Contains(lower, "sign in to confirm") {
			return errs.PlatformUnavailable("YouTube asked for a sign-in check on this request. Wait a minute and retry.")
		}
		if strings.Contains(lower, "unable to download video data") || strings.Contains(lower, "http error 403") {
			return errs.PlatformUnavailable("YouTube refused the file download. Try another quality, or try again in a moment.")
		}
	}
	if containsAny(lower, "private video", "this video is private", "login required", "members-only", "members only", "join this channel", "age-restricted") {
		return errs.PrivateVideo("")
	}
	if strings.Contains(lower, "drm") {
		return errs.PrivateVideo("This video is DRM-protected and cannot be saved.")
	}
	if containsAny(lower, "not found", "http error 404", "has been deleted") {
		return errs.RemovedVideo()
	}
	if strings.Contains(lower, "unsupported url") {
		return errs.UnsupportedPlatform()
	}
	if strings.Contains(lower, "no video could be found") || strings.Contains(lower, "no video formats") {
		return errs.PlatformUnavailable("This post does not contain a public downloadable video.")
	}
	if strings.Contains(lower, "empty media response") ||
		(strings.Contains(hostOf(pageURL), "instagram") && strings.Contains(lower, "rate-limit")) {
		return errs.PrivateVideo("This Instagram post is not available without a login. Try a fully public Reel or post.")
	}
	if strings.Contains(lower, "cannot parse data") {
		return errs.PlatformUnavailable("Facebook blocked the public parser. Try a public watch or reel link that opens logged out.")
	}
	if isTikTok(pageURL) && containsAny(lower, "unable to extract", "webpage video data", "universal data") {
		return errs.PlatformUnavailable("TikTok blocked the public parser. Try a fully public video, or try again in a moment.")
	}
	if strings.Contains(lower, "unable to download video data") || strings.Contains(lower, "http error 403") {
		return errs.PlatformUnavailable("The source refused the video file. Try another quality, or try again.")
	}
	summary := strings.TrimSpace(text)
	if lines := strings.Split(summary, "\n"); len(lines) > 0 {
		summary = strings.TrimSpace(lines[len(lines)-1])
	}
	if len(summary) > 240 {
		summary = summary[:240]
	}
	if summary == "" {
		return errs.PlatformUnavailable("")
	}
	return errs.PlatformUnavailable("Could not fetch this video from the source. " + summary)
}

func isTikTok(rawURL string) bool {
	return strings.Contains(hostOf(rawURL), "tiktok.com")
}

func containsAny(text string, parts ...string) bool {
	for _, part := range parts {
		if strings.Contains(text, part) {
			return true
		}
	}
	return false
}
