package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/jobs"
	"github.com/aviation256444-boop/socialsave/backend/internal/providers"
	"github.com/aviation256444-boop/socialsave/backend/internal/security"
	"github.com/aviation256444-boop/socialsave/backend/internal/storage"
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
	if strings.Contains(response.Body.String(), "ftyp") || response.Body.Len() > 512 {
		t.Fatal("redirect response carried video bytes")
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

func TestPublishStoresOnR2AndDeletesRenderFile(t *testing.T) {
	var mime string
	var sawGet bool
	bucket := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			sawGet = true
			http.Error(w, "render must not download the object", http.StatusBadGateway)
			return
		}
		switch r.Method {
		case http.MethodPut:
			mime = r.Header.Get("Content-Type")
			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		case http.MethodHead:
			w.WriteHeader(http.StatusOK)
		default:
			http.Error(w, "unexpected", http.StatusMethodNotAllowed)
		}
	}))
	defer bucket.Close()

	logs := captureLogs(t)
	app := testApp(t)
	app.Config.AllowRenderFileProxy = false
	app.Objects = storage.NewS3(config.Config{
		S3Endpoint:        bucket.URL,
		S3Region:          "auto",
		S3Bucket:          "socialsave",
		S3AccessKeyID:     "access-key",
		S3SecretAccessKey: "secret-value",
		S3PublicBaseURL:   "https://media.example.com",
		S3URLTTL:          time.Hour,
	})
	path := writeJobVideo(t, app, "video-bytes")
	job := app.Jobs.Create()
	app.publishPrepared(context.Background(), job.ID, providers.DownloadResult{
		Path: path, MIME: "video/mp4", Name: "clip.mp4", Filesize: 11,
	}, "https://socialsave-api.onrender.com")
	got, ok := app.Jobs.Get(job.ID)
	if !ok || got.State != "ready" || got.FilePath != "" {
		t.Fatalf("job = %#v ok=%v", got, ok)
	}
	if !strings.HasPrefix(got.DownloadURL, "https://media.example.com/videos/") || strings.Contains(got.DownloadURL, "onrender.com") {
		t.Fatalf("download url = %s", got.DownloadURL)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("render temp file was kept")
	}
	if mime != "video/mp4" || sawGet {
		t.Fatalf("mime=%s sawGet=%v", mime, sawGet)
	}
	text := logs.String()
	if !strings.Contains(text, "download delivery=object_storage") || strings.Contains(text, "download delivery=proxy_file") || strings.Contains(text, "secret-value") || strings.Contains(text, "X-Amz-Signature") {
		t.Fatalf("logs = %s", text)
	}
}

func TestR2FailureDoesNotProxyWhenDisabled(t *testing.T) {
	logs := captureLogs(t)
	app := testApp(t)
	app.Config.AllowRenderFileProxy = false
	app.Objects = &fakeUploader{enabled: true, err: errors.New("object storage status 500")}
	path := writeJobVideo(t, app, "video-bytes")
	job := app.Jobs.Create()
	app.publishPrepared(context.Background(), job.ID, providers.DownloadResult{
		Path: path, MIME: "video/mp4", Name: "clip.mp4", Filesize: 11,
	}, "https://socialsave-api.onrender.com")
	got, ok := app.Jobs.Get(job.ID)
	if !ok || got.State != "failed" || got.DownloadURL != "" || got.ErrorCode != "platform_unavailable" {
		t.Fatalf("job = %#v", got)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("temp file survived a failed upload")
	}
	text := logs.String()
	if strings.Contains(text, "download delivery=proxy_file") || !strings.Contains(text, "download delivery=prepare_local_failed") {
		t.Fatalf("logs = %s", text)
	}
}

func TestMissingStorageServesThePreparedFile(t *testing.T) {
	logs := captureLogs(t)
	app := testApp(t)
	app.Config.AllowRenderFileProxy = false
	app.Objects = storage.New("")
	path := writeJobVideo(t, app, "video-bytes")
	job := app.Jobs.Create()
	app.publishPrepared(context.Background(), job.ID, providers.DownloadResult{
		Path: path, MIME: "video/mp4", Name: "clip.mp4", Filesize: 11,
	}, "https://socialsave-api.onrender.com")
	got, _ := app.Jobs.Get(job.ID)
	if got.State != "ready" || !strings.Contains(got.DownloadURL, "/api/v1/files/") || got.FilePath == "" {
		t.Fatalf("job = %#v", got)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "download delivery=proxy_file") {
		t.Fatalf("logs = %s", logs.String())
	}
	request := httptest.NewRequest(http.MethodGet, strings.TrimPrefix(got.DownloadURL, "https://socialsave-api.onrender.com"), nil)
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "video-bytes") {
		t.Fatalf("download %d %s", response.Code, response.Body.String())
	}
}

func TestRejectedStorageURLDoesNotProxyWhenDisabled(t *testing.T) {
	app := testApp(t)
	app.Config.AllowRenderFileProxy = false
	app.Objects = &fakeUploader{enabled: true, url: "http://127.0.0.1/secret.mp4?X-Amz-Signature=deadbeef"}
	path := writeJobVideo(t, app, "video-bytes")
	job := app.Jobs.Create()
	logs := captureLogs(t)
	app.publishPrepared(context.Background(), job.ID, providers.DownloadResult{
		Path: path, MIME: "video/mp4", Name: "clip.mp4", Filesize: 11,
	}, "https://socialsave-api.onrender.com")
	got, _ := app.Jobs.Get(job.ID)
	if got.State != "failed" || got.DownloadURL != "" {
		t.Fatalf("job = %#v", got)
	}
	if strings.Contains(logs.String(), "deadbeef") || strings.Contains(logs.String(), "download delivery=proxy_file") {
		t.Fatalf("logs = %s", logs.String())
	}
}

func TestProxyEnabledFallsBackAndStillPrefersR2(t *testing.T) {
	logs := captureLogs(t)
	app := testApp(t)
	app.Config.AllowRenderFileProxy = true
	app.Objects = &fakeUploader{enabled: true, err: errors.New("object storage status 500")}
	path := writeJobVideo(t, app, "video-bytes")
	job := app.Jobs.Create()
	app.publishPrepared(context.Background(), job.ID, providers.DownloadResult{
		Path: path, MIME: "video/mp4", Name: "clip.mp4", Filesize: 11,
	}, "https://socialsave-api.onrender.com")
	got, _ := app.Jobs.Get(job.ID)
	if got.State != "ready" || !strings.Contains(got.DownloadURL, "/api/v1/files/") || got.FilePath == "" {
		t.Fatalf("job = %#v", got)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(logs.String(), "download delivery=proxy_file") {
		t.Fatalf("logs = %s", logs.String())
	}

	app.Objects = &fakeUploader{enabled: true, url: "https://media.example.com/videos/clip.mp4"}
	secondPath := writeJobVideo(t, app, "another-video")
	second := app.Jobs.Create()
	app.publishPrepared(context.Background(), second.ID, providers.DownloadResult{
		Path: secondPath, MIME: "video/mp4", Name: "clip.mp4", Filesize: 13,
	}, "https://socialsave-api.onrender.com")
	ready, _ := app.Jobs.Get(second.ID)
	if ready.DownloadURL != "https://media.example.com/videos/clip.mp4" || ready.FilePath != "" {
		t.Fatalf("ready = %#v", ready)
	}
}

func TestServeJobProxiesOnlyWhenEnabled(t *testing.T) {
	app := testApp(t)
	app.Config.AllowRenderFileProxy = false
	app.Objects = &fakeUploader{enabled: true}
	job := app.Jobs.Create()
	path := writeJobVideo(t, app, "secret-video")
	size := int64(12)
	app.Jobs.MarkReady(job.ID, path, "video/mp4", "clip.mp4", "https://socialsave-api.onrender.com/api/v1/files/x", &size)
	token, err := app.Tokens.IssueJob(job.ID, "video/mp4", "clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	logs := captureLogs(t)
	denied := httptest.NewRecorder()
	app.Router().ServeHTTP(denied, httptest.NewRequest(http.MethodGet, "/api/v1/files/"+token, nil))
	if denied.Code != http.StatusServiceUnavailable || strings.Contains(denied.Body.String(), "secret-video") {
		t.Fatalf("disabled %d %s", denied.Code, denied.Body.String())
	}
	if strings.Contains(logs.String(), "download delivery=proxy_file") {
		t.Fatalf("logs = %s", logs.String())
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("disabled proxy left the temp file in place")
	}

	app.Config.AllowRenderFileProxy = true
	again := app.Jobs.Create()
	againPath := writeJobVideo(t, app, "served-video")
	app.Jobs.MarkReady(again.ID, againPath, "video/mp4", "clip.mp4", "https://socialsave-api.onrender.com/api/v1/files/y", &size)
	againToken, err := app.Tokens.IssueJob(again.ID, "video/mp4", "clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	allowed := httptest.NewRecorder()
	app.Router().ServeHTTP(allowed, httptest.NewRequest(http.MethodGet, "/api/v1/files/"+againToken, nil))
	if allowed.Code != http.StatusOK || !strings.Contains(allowed.Body.String(), "served-video") {
		t.Fatalf("enabled %d %s", allowed.Code, allowed.Body.String())
	}
}

func TestJobStatusReturnsTheR2URL(t *testing.T) {
	app := testApp(t)
	job := app.Jobs.Create()
	stored := "https://media.example.com/videos/20261005/abc/clip.mp4"
	size := int64(11)
	app.Jobs.MarkReady(job.ID, "", "video/mp4", "clip.mp4", stored, &size)
	request := httptest.NewRequest(http.MethodGet, "/api/v1/download/"+job.ID, nil)
	request.Host = "socialsave-api.onrender.com"
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("status %d %s", response.Code, response.Body.String())
	}
	var body struct {
		DownloadURL string  `json:"download_url"`
		DirectURL   *string `json:"direct_url"`
		State       string  `json:"state"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.State != "ready" || body.DownloadURL != stored || body.DirectURL == nil || *body.DirectURL != stored {
		t.Fatalf("body = %#v", body)
	}
	if strings.Contains(body.DownloadURL, "onrender.com") || strings.Contains(body.DownloadURL, "/api/v1/files/") {
		t.Fatalf("download url points at Render: %s", body.DownloadURL)
	}
}

func TestDirectTicketLogsRedirect(t *testing.T) {
	logs := captureLogs(t)
	app := testApp(t)
	token, err := app.Tokens.IssueRemote("https://cdn.example.com/video.mp4", "video/mp4", "video.mp4", app.Config.MaxDownloadBytes, nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/v1/files/"+token, nil))
	if response.Code != http.StatusTemporaryRedirect {
		t.Fatalf("status %d", response.Code)
	}
	if !strings.Contains(logs.String(), "download delivery=redirect") || strings.Contains(logs.String(), "download delivery=proxy_file") {
		t.Fatalf("logs = %s", logs.String())
	}
}

type fakeUploader struct {
	enabled bool
	url     string
	err     error
}

func (f *fakeUploader) Enabled() bool { return f.enabled }

func (f *fakeUploader) Put(context.Context, string, string, string) (string, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.url, nil
}

func writeJobVideo(t *testing.T, app *Server, body string) string {
	t.Helper()
	job := jobs.Job{ID: "fixture"}
	dir, err := app.Jobs.WorkDir(job.ID + body)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "clip.mp4")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })
	return &buf
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
