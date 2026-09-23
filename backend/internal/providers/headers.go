package providers

import (
	"net/url"
	"strings"
)

const browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

func hostOf(rawURL string) string {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(strings.ToLower(parsed.Hostname()), "www.")
}

func hostMatches(host string, names ...string) bool {
	host = strings.TrimPrefix(strings.ToLower(host), "www.")
	for _, name := range names {
		if host == name || strings.HasSuffix(host, "."+name) {
			return true
		}
	}
	return false
}

// Referer is the page origin a public CDN usually expects.
func Referer(rawURL string) (referer, origin string) {
	host := hostOf(rawURL)
	switch {
	case strings.Contains(host, "tiktok.com"):
		return "https://www.tiktok.com/", ""
	case strings.Contains(host, "instagram.com") || strings.HasSuffix(host, "instagr.am"):
		return "https://www.instagram.com/", "https://www.instagram.com"
	case isYouTubeHost(host):
		return "https://www.youtube.com/", ""
	case strings.Contains(host, "reddit.com") || strings.HasSuffix(host, "redd.it"):
		return "https://www.reddit.com/", ""
	case strings.Contains(host, "facebook.com") || strings.HasSuffix(host, "fb.watch") || strings.HasSuffix(host, "fb.com"):
		return "https://www.facebook.com/", "https://www.facebook.com"
	case strings.Contains(host, "pinterest.com") || strings.HasSuffix(host, "pin.it"):
		return "https://www.pinterest.com/", ""
	case host == "x.com" || host == "twitter.com" || strings.HasSuffix(host, ".x.com") || strings.HasSuffix(host, ".twitter.com"):
		return "https://x.com/", ""
	default:
		return "", ""
	}
}

func isYouTubeHost(host string) bool {
	host = strings.TrimPrefix(strings.ToLower(host), "www.")
	switch host {
	case "youtu.be", "youtube.com", "youtube-nocookie.com":
		return true
	default:
		return strings.HasSuffix(host, ".youtube.com") ||
			strings.HasSuffix(host, ".youtube-nocookie.com") ||
			strings.HasSuffix(host, ".youtu.be")
	}
}

func baseHeaders(rawURL string) map[string]string {
	headers := map[string]string{
		"User-Agent":      browserUA,
		"Accept-Language": "en-US,en;q=0.9",
	}
	referer, origin := Referer(rawURL)
	if referer != "" {
		headers["Referer"] = referer
	}
	if origin != "" {
		headers["Origin"] = origin
	}
	return headers
}

func publicHeaders(base, extra map[string]string) map[string]string {
	out := map[string]string{}
	for _, src := range []map[string]string{base, extra} {
		for key, value := range src {
			if value == "" || sensitiveHeader(key) {
				continue
			}
			out[key] = value
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func sensitiveHeader(key string) bool {
	switch strings.ToLower(key) {
	case "cookie", "set-cookie", "authorization", "proxy-authorization":
		return true
	default:
		return false
	}
}

func stringMap(raw map[string]any) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	out := make(map[string]string, len(raw))
	for key, value := range raw {
		text, ok := value.(string)
		if !ok || text == "" {
			continue
		}
		out[key] = text
	}
	return out
}
