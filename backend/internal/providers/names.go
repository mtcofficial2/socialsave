package providers

import (
	"regexp"
	"strings"
)

var unsafeName = regexp.MustCompile(`[<>:"/\\|?*]+`)
var nonASCIIName = regexp.MustCompile(`[^A-Za-z0-9_.\-]+`)

func safeTitle(title string) string {
	cleaned := strings.TrimSpace(unsafeName.ReplaceAllString(title, "_"))
	if cleaned == "" {
		cleaned = "video"
	}
	if len(cleaned) > 80 {
		cleaned = cleaned[:80]
	}
	return strings.TrimSpace(cleaned)
}

// ASCIIFilename makes a Content-Disposition name that stays in the header charset.
func ASCIIFilename(name string) string {
	raw := strings.ReplaceAll(name, `"`, "")
	if strings.TrimSpace(raw) == "" {
		raw = "video.mp4"
	}
	cleaned := strings.Trim(nonASCIIName.ReplaceAllString(raw, "_"), "._")
	if cleaned == "" {
		cleaned = "video"
	}
	if !strings.Contains(cleaned, ".") {
		cleaned += ".mp4"
	}
	if len(cleaned) > 80 {
		cleaned = cleaned[:80]
	}
	return cleaned
}

func mimeForExt(ext string) string {
	ext = strings.TrimPrefix(strings.ToLower(ext), ".")
	if ext == "" {
		ext = "mp4"
	}
	if ext == "m4a" {
		return "audio/mp4"
	}
	return "video/" + ext
}
