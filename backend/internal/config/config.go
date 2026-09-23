// Package config loads SocialSave API settings from the environment and an optional .env file.
package config

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultMaxDownloadBytes int64 = 268435456 // 256 MiB, sized for free-tier hosts
	defaultMaxHeight              = 1080
	defaultTokenTTL               = 3600
	defaultJobTTL                 = 600
	defaultTimeoutSeconds         = 30
	defaultMaxRedirects           = 3
	defaultAnalyzeRate            = 30
	defaultDownloadRate           = 10
)

// Config is the process configuration. Zero values are replaced by Load.
type Config struct {
	AppName           string
	Environment       string
	SecretKey         string
	PublicBaseURL     string
	RequireAPIKey     bool
	APIKeys           []string
	EnabledPlatforms  map[string]struct{}
	MaxDownloadBytes  int64
	DefaultMaxHeight  int
	TokenTTL          time.Duration
	JobTTL            time.Duration
	RequestTimeout    time.Duration
	MaxRedirects      int
	AnalyzeRateLimit  int
	DownloadRateLimit int
	ObjectStorageURL  string
	YouTubeAPIKey     string
	InstagramToken    string
	FacebookToken     string
	XBearerToken      string
	AnyAPIKey         string
	Port              string
}

// Enabled reports whether a platform id is turned on.
func (c Config) Enabled(id string) bool {
	_, ok := c.EnabledPlatforms[strings.ToLower(id)]
	return ok
}

// Load reads .env without overriding variables that are already set, then reads the environment.
func Load() Config {
	loadDotEnv(".env")
	enabled := splitCSV(getenv("ENABLED_PLATFORMS", "tiktok,instagram,facebook,x,youtube,reddit,pinterest,direct"))
	set := make(map[string]struct{}, len(enabled))
	for _, item := range enabled {
		set[strings.ToLower(item)] = struct{}{}
	}
	return Config{
		AppName:           getenv("APP_NAME", "SocialSave API"),
		Environment:       getenv("ENVIRONMENT", "development"),
		SecretKey:         getenv("SECRET_KEY", "change-me-in-production"),
		PublicBaseURL:     publicBaseURL(),
		RequireAPIKey:     parseBool(os.Getenv("REQUIRE_API_KEY"), false),
		APIKeys:           splitCSV(os.Getenv("API_KEYS")),
		EnabledPlatforms:  set,
		MaxDownloadBytes:  parseInt64(os.Getenv("MAX_DOWNLOAD_BYTES"), defaultMaxDownloadBytes),
		DefaultMaxHeight:  parseInt(os.Getenv("DEFAULT_MAX_HEIGHT"), defaultMaxHeight),
		TokenTTL:          time.Duration(parseInt(os.Getenv("TOKEN_TTL_SECONDS"), defaultTokenTTL)) * time.Second,
		JobTTL:            time.Duration(parseInt(os.Getenv("JOB_TTL_SECONDS"), defaultJobTTL)) * time.Second,
		RequestTimeout:    time.Duration(parseInt(os.Getenv("REQUEST_TIMEOUT_SECONDS"), defaultTimeoutSeconds)) * time.Second,
		MaxRedirects:      parseInt(os.Getenv("MAX_REDIRECTS"), defaultMaxRedirects),
		AnalyzeRateLimit:  parseRate(os.Getenv("ANALYZE_RATE_LIMIT"), defaultAnalyzeRate),
		DownloadRateLimit: parseRate(os.Getenv("DOWNLOAD_RATE_LIMIT"), defaultDownloadRate),
		ObjectStorageURL:  strings.TrimSpace(os.Getenv("OBJECT_STORAGE_URL")),
		YouTubeAPIKey:     strings.TrimSpace(os.Getenv("YOUTUBE_API_KEY")),
		InstagramToken:    strings.TrimSpace(os.Getenv("INSTAGRAM_ACCESS_TOKEN")),
		FacebookToken:     strings.TrimSpace(os.Getenv("FACEBOOK_ACCESS_TOKEN")),
		XBearerToken:      strings.TrimSpace(os.Getenv("X_BEARER_TOKEN")),
		AnyAPIKey:         strings.TrimSpace(os.Getenv("ANYAPI_KEY")),
		Port:              getenv("PORT", "8080"),
	}
}

// publicBaseURL prefers PUBLIC_BASE_URL, then the URL Render injects.
// Local runs with neither set keep the loopback default.
func publicBaseURL() string {
	if value := strings.TrimSpace(os.Getenv("PUBLIC_BASE_URL")); value != "" {
		return strings.TrimRight(value, "/")
	}
	if value := strings.TrimSpace(os.Getenv("RENDER_EXTERNAL_URL")); value != "" {
		return strings.TrimRight(value, "/")
	}
	return "http://127.0.0.1:8080"
}

func getenv(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func parseBool(value string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	default:
		return fallback
	}
}

func parseInt(value string, fallback int) int {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return n
}

func parseInt64(value string, fallback int64) int64 {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n <= 0 {
		return fallback
	}
	return n
}

func parseRate(value string, fallback int) int {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return fallback
	}
	if i := strings.IndexByte(value, '/'); i >= 0 {
		value = value[:i]
	}
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n < 1 {
		return fallback
	}
	return n
}

func loadDotEnv(path string) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		if len(value) >= 2 {
			if (value[0] == '"' && value[len(value)-1] == '"') || (value[0] == '\'' && value[len(value)-1] == '\'') {
				value = value[1 : len(value)-1]
			}
		}
		if key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); exists {
			continue
		}
		_ = os.Setenv(key, value)
	}
}
