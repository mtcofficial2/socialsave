package server

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/security"
)

func TestHealthAndSecurityHeaders(t *testing.T) {
	response := httptest.NewRecorder()
	testApp(t).Router().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status %d body %s", response.Code, response.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["status"] != "ok" || body["version"] != "meta-audio-1" {
		t.Fatalf("body = %#v", body)
	}
	if response.Header().Get("X-Content-Type-Options") != "nosniff" ||
		response.Header().Get("X-Frame-Options") != "DENY" ||
		response.Header().Get("Referrer-Policy") != "no-referrer" ||
		response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("headers = %#v", response.Header())
	}
}

func TestPlatformsAllowYouTubeDownload(t *testing.T) {
	response := httptest.NewRecorder()
	testApp(t).Router().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/platforms", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("status %d", response.Code)
	}
	var body struct {
		Success   bool `json:"success"`
		Platforms []struct {
			ID               string `json:"id"`
			SupportsDownload bool   `json:"supports_download"`
		} `json:"platforms"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if !body.Success || len(body.Platforms) != 8 {
		t.Fatalf("platforms = %#v", body.Platforms)
	}
	found := false
	for _, item := range body.Platforms {
		if item.ID == "youtube" {
			found = true
			if !item.SupportsDownload {
				t.Fatal("youtube download should be enabled")
			}
		}
	}
	if !found {
		t.Fatal("youtube missing from catalog")
	}
}

func TestAnalyzeRejectsShortURL(t *testing.T) {
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/v1/analyze", strings.NewReader(`{"url":"nope"}`))
	testApp(t).Router().ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status %d body %s", response.Code, response.Body.String())
	}
}

func TestFileRedirectsPublicURLAndRejectsLoopback(t *testing.T) {
	app := testApp(t)
	token, err := app.Tokens.IssueRemote("https://cdn.example.com/video.mp4", "video/mp4", "video.mp4", app.Config.MaxDownloadBytes, map[string]string{"User-Agent": "test"}, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/files/"+token, nil))
	if response.Code != http.StatusTemporaryRedirect {
		t.Fatalf("status %d body %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Location") != "https://cdn.example.com/video.mp4" {
		t.Fatalf("location = %s", response.Header().Get("Location"))
	}

	blocked, err := app.Tokens.IssueRemote("http://127.0.0.1/secret.mp4", "video/mp4", "secret.mp4", app.Config.MaxDownloadBytes, nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	denied := httptest.NewRecorder()
	app.Router().ServeHTTP(denied, httptest.NewRequest(http.MethodGet, "/api/v1/files/"+blocked, nil))
	if denied.Code != http.StatusBadRequest {
		t.Fatalf("loopback status %d body %s", denied.Code, denied.Body.String())
	}
	if denied.Header().Get("Location") != "" {
		t.Fatal("loopback token must not redirect")
	}
}

func TestAPIKeyRequired(t *testing.T) {
	app := testApp(t)
	app.Config.RequireAPIKey = true
	app.Config.APIKeys = []string{"desktop-key"}
	open := httptest.NewRecorder()
	app.Router().ServeHTTP(open, httptest.NewRequest(http.MethodGet, "/api/v1/platforms", nil))
	if open.Code != http.StatusUnauthorized {
		t.Fatalf("missing key status %d", open.Code)
	}
	authed := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/v1/platforms", nil)
	request.Header.Set("Authorization", "Bearer desktop-key")
	app.Router().ServeHTTP(authed, request)
	if authed.Code != http.StatusOK {
		t.Fatalf("bearer status %d", authed.Code)
	}
}

func TestWebRootServesTheSite(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<title>SocialSave</title>"), 0o644); err != nil {
		t.Fatal(err)
	}
	app := testApp(t)
	app.Config.WebRoot = dir
	home := httptest.NewRecorder()
	app.Router().ServeHTTP(home, httptest.NewRequest(http.MethodGet, "/", nil))
	if home.Code != http.StatusOK || !strings.Contains(home.Body.String(), "SocialSave") {
		t.Fatalf("home %d %s", home.Code, home.Body.String())
	}
	health := httptest.NewRecorder()
	app.Router().ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/health", nil))
	if health.Code != http.StatusOK || !strings.Contains(health.Body.String(), "ok") {
		t.Fatalf("health %d %s", health.Code, health.Body.String())
	}
}

func testApp(t *testing.T) *Server {
	t.Helper()
	enabled := map[string]struct{}{}
	for _, id := range []string{"tiktok", "instagram", "facebook", "x", "youtube", "reddit", "pinterest", "direct"} {
		enabled[id] = struct{}{}
	}
	cfg := config.Config{
		AppName:           "SocialSave API",
		SecretKey:         "test-secret",
		PublicBaseURL:     "http://127.0.0.1:8080",
		EnabledPlatforms:  enabled,
		MaxDownloadBytes:  268435456,
		DefaultMaxHeight:  1080,
		TokenTTL:          time.Hour,
		JobTTL:            10 * time.Minute,
		RequestTimeout:    5 * time.Second,
		MaxRedirects:      3,
		AnalyzeRateLimit:  30,
		DownloadRateLimit: 10,
		Port:              "8080",
	}
	validator := security.NewValidator()
	validator.Lookup = func(context.Context, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("93.184.216.34")}, nil
	}
	return New(cfg, validator, nil)
}
