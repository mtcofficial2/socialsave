package providers

import (
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
)

func testSettings(enabled string) config.Config {
	set := map[string]struct{}{}
	for _, item := range strings.Split(enabled, ",") {
		item = strings.TrimSpace(item)
		if item != "" {
			set[item] = struct{}{}
		}
	}
	return config.Config{
		EnabledPlatforms: set,
		MaxDownloadBytes: 268435456,
		DefaultMaxHeight: 1080,
	}
}
