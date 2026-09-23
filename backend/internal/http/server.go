// Package server is the Chi HTTP API. Routes match the Flutter client.
package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"

	"github.com/aviation256444-boop/socialsave/backend/internal/auth"
	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/jobs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
	"github.com/aviation256444-boop/socialsave/backend/internal/providers"
	"github.com/aviation256444-boop/socialsave/backend/internal/security"
	"github.com/aviation256444-boop/socialsave/backend/internal/storage"
	"github.com/aviation256444-boop/socialsave/backend/internal/tokens"
)

const healthVersion = "meta-audio-1"

// Server serves the SocialSave API.
type Server struct {
	Config    config.Config
	Tokens    *tokens.Service
	Jobs      *jobs.Store
	Registry  *providers.Registry
	Validator *security.Validator
	Objects   *storage.Store
	upstream  *http.Client
	plays     sync.Map
	limiter   *rateLimiter
}

// New wires the handlers. jobs may be nil and will be created from config.
func New(cfg config.Config, validator *security.Validator, store *jobs.Store) *Server {
	if validator == nil {
		validator = security.NewValidator()
	}
	if store == nil {
		store = jobs.NewStore(cfg.JobTTL)
	}
	upstream := &http.Client{
		Transport: &http.Transport{
			Proxy:                 nil,
			DialContext:           validator.DialContext,
			DisableCompression:    true,
			ForceAttemptHTTP2:     true,
			MaxIdleConns:          32,
			MaxIdleConnsPerHost:   8,
			IdleConnTimeout:       90 * time.Second,
			ResponseHeaderTimeout: 25 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return errs.PrivateVideo("")
			}
			_, err := validator.Validate(req.Context(), req.URL.String())
			return err
		},
	}
	return &Server{
		Config:    cfg,
		Tokens:    tokens.New(cfg.SecretKey, cfg.TokenTTL),
		Jobs:      store,
		Registry:  providers.NewRegistry(cfg, validator),
		Validator: validator,
		Objects:   storage.New(cfg.ObjectStorageURL),
		upstream:  upstream,
		limiter: &rateLimiter{
			analyze:  cfg.AnalyzeRateLimit,
			download: cfg.DownloadRateLimit,
			hits:     map[string][]time.Time{},
		},
	}
}

// Router is the public HTTP handler.
func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(s.securityHeaders)
	r.Use(middleware.Recoverer)
	r.Use(cors.Handler(cors.Options{
		AllowedOrigins: []string{"*"},
		AllowedMethods: []string{http.MethodGet, http.MethodPost, http.MethodOptions},
		AllowedHeaders: []string{"Authorization", "Content-Type", "X-API-Key"},
		MaxAge:         300,
	}))
	r.Use(s.limit)
	r.Get("/health", s.health)
	r.With(s.requireKey).Post("/api/tiktok", s.tiktok)
	r.Route("/api/v1", func(r chi.Router) {
		r.With(s.requireKey).Get("/platforms", s.platforms)
		r.With(s.requireKey).Post("/analyze", s.analyze)
		r.With(s.requireKey).Post("/tiktok", s.tiktok)
		r.With(s.requireKey).Post("/download", s.download)
		r.Get("/download/{job_id}", s.jobStatus)
		r.Get("/files/{token}", s.file)
	})
	r.NotFound(func(w http.ResponseWriter, _ *http.Request) {
		writeError(w, errs.UnsupportedPlatform())
	})
	return r
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, models.HealthResponse{Status: "ok", Version: healthVersion})
}

func (s *Server) platforms(w http.ResponseWriter, _ *http.Request) {
	items := make([]models.PlatformStatus, 0, 8)
	for _, provider := range s.Registry.All() {
		enabled := s.Registry.Enabled(provider)
		notes := provider.Notes()
		var note *string
		if notes != "" {
			note = &notes
		}
		items = append(items, models.PlatformStatus{
			ID:               provider.ID(),
			Enabled:          enabled,
			SupportsMetadata: provider.SupportsMetadata(),
			SupportsDownload: provider.SupportsDownload() && enabled,
			Notes:            note,
		})
	}
	writeJSON(w, http.StatusOK, models.PlatformsResponse{Success: true, Platforms: items})
}

func (s *Server) analyze(w http.ResponseWriter, r *http.Request) {
	var body models.AnalyzeRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	if len(strings.TrimSpace(body.URL)) < 8 || len(body.URL) > 2048 {
		writeError(w, errs.InvalidURL("That URL is not valid."))
		return
	}
	raw, err := s.Validator.Validate(r.Context(), body.URL)
	if err != nil {
		writeError(w, err)
		return
	}
	provider, err := s.Registry.Resolve(raw)
	if err != nil {
		writeError(w, err)
		return
	}
	meta, err := provider.Analyze(r.Context(), raw)
	if err != nil {
		slog.Info("analyze failed", "platform", provider.ID(), "message", err.Error())
		writeError(w, err)
		return
	}
	if meta.Formats == nil {
		meta.Formats = []models.MediaFormat{}
	}
	writeJSON(w, http.StatusOK, models.AnalyzeResponse{
		Success:                  true,
		Platform:                 meta.Platform,
		Title:                    meta.Title,
		Thumbnail:                meta.Thumbnail,
		Duration:                 meta.Duration,
		Author:                   meta.Author,
		URL:                      meta.SourceURL,
		Formats:                  meta.Formats,
		CanDownload:              meta.CanDownload,
		DownloadRestrictedReason: meta.DownloadRestrictedReason,
	})
}

func (s *Server) tiktok(w http.ResponseWriter, r *http.Request) {
	var body models.AnalyzeRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	if len(strings.TrimSpace(body.URL)) < 8 || len(body.URL) > 2048 {
		writeError(w, errs.InvalidURL("That URL is not valid."))
		return
	}
	raw, err := s.Validator.Validate(r.Context(), body.URL)
	if err != nil {
		writeError(w, err)
		return
	}
	provider, err := s.Registry.Resolve(raw)
	if err != nil {
		writeError(w, err)
		return
	}
	tiktok, ok := provider.(*providers.TikTok)
	if !ok {
		writeError(w, errs.InvalidURL("Paste a TikTok video link."))
		return
	}
	media, err := tiktok.Lookup(r.Context(), raw)
	if err != nil {
		slog.Info("tiktok resolve failed", "message", err.Error())
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, media.Response())
}

func (s *Server) download(w http.ResponseWriter, r *http.Request) {
	var body models.DownloadRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	if len(strings.TrimSpace(body.URL)) < 8 || len(body.URL) > 2048 {
		writeError(w, errs.InvalidURL("That URL is not valid."))
		return
	}
	formatID := strings.TrimSpace(body.FormatID)
	if formatID == "" || len(formatID) > 64 {
		writeError(w, errs.UnsupportedFormat())
		return
	}
	raw, err := s.Validator.Validate(r.Context(), body.URL)
	if err != nil {
		writeError(w, err)
		return
	}
	provider, err := s.Registry.Resolve(raw)
	if err != nil {
		writeError(w, err)
		return
	}
	if !provider.SupportsDownload() {
		writeError(w, errs.DownloadNotPermitted())
		return
	}
	handle, err := provider.CreateDownload(r.Context(), raw, formatID)
	if err != nil {
		writeError(w, err)
		return
	}
	base := publicBase(r, s.Config)
	if handle.Stream {
		s.beginPlay(w, raw, base)
		return
	}
	if handle.Filesize != nil && *handle.Filesize > s.Config.MaxDownloadBytes {
		writeError(w, errs.FileTooLarge(s.Config.MaxDownloadBytes))
		return
	}
	if handle.PrepareLocally {
		job := s.Jobs.Create()
		slog.Info("download delivery=prepare_local", "job", job.ID[:8], "size", handle.Filesize)
		go s.prepare(job.ID, raw, handle.FormatID, base)
		mime := handle.MimeType
		name := handle.FileName
		if mime == "" {
			mime = "video/mp4"
		}
		if name == "" {
			name = "video.mp4"
		}
		id := job.ID
		writeJSON(w, http.StatusOK, models.DownloadResponse{
			Success:     true,
			DownloadURL: "",
			ID:          &id,
			State:       "processing",
			MimeType:    &mime,
			FileName:    &name,
		})
		return
	}
	if handle.UpstreamURL == "" {
		writeError(w, errs.DownloadNotPermitted())
		return
	}
	if _, err := s.Validator.Validate(r.Context(), handle.UpstreamURL); err != nil {
		writeError(w, err)
		return
	}
	token, err := s.Tokens.IssueRemote(handle.UpstreamURL, handle.MimeType, handle.FileName, s.Config.MaxDownloadBytes, handle.Headers, handle.Filesize, handle.Proxy || proxyHost(handle.UpstreamURL))
	if err != nil {
		writeError(w, errs.PlatformUnavailable(""))
		return
	}
	expires := time.Now().UTC().Add(s.Config.TokenTTL).Format(time.RFC3339)
	id := token
	if len(id) > 12 {
		id = id[:12]
	}
	host := "unknown"
	if parsed, err := url.Parse(handle.UpstreamURL); err == nil && parsed.Hostname() != "" {
		host = parsed.Hostname()
	}
	slog.Info("download delivery=direct", "host", host, "size", handle.Filesize, "prepare_local", false)
	mime := handle.MimeType
	name := handle.FileName
	response := models.DownloadResponse{
		Success:        true,
		DownloadURL:    base + "/api/v1/files/" + token,
		ID:             &id,
		State:          "ready",
		ExpiresAt:      &expires,
		MimeType:       &mime,
		Filesize:       handle.Filesize,
		FileName:       &name,
		RequestHeaders: handle.Headers,
	}
	if !handle.Proxy && !proxyHost(handle.UpstreamURL) {
		direct := handle.UpstreamURL
		response.DirectURL = &direct
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) jobStatus(w http.ResponseWriter, r *http.Request) {
	job, ok := s.Jobs.Get(chi.URLParam(r, "job_id"))
	if !ok {
		writeError(w, errs.Unauthorized())
		return
	}
	body := models.JobStatusResponse{
		Success:     true,
		ID:          job.ID,
		State:       job.State,
		DownloadURL: job.DownloadURL,
		Progress:    job.Progress,
		Filesize:    job.Filesize,
		FileName:    job.FileName,
	}
	if job.ErrorCode != "" {
		body.Error = &models.ErrorBody{Code: job.ErrorCode, Message: job.ErrorMessage}
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) file(w http.ResponseWriter, r *http.Request) {
	claims, err := s.Tokens.Parse(chi.URLParam(r, "token"))
	if err != nil {
		writeError(w, err)
		return
	}
	if claims.Stream != "" {
		s.servePlay(w, r, claims.Stream)
		return
	}
	if claims.Job != "" {
		s.serveJob(w, r, claims)
		return
	}
	if claims.URL == "" {
		writeError(w, errs.Unauthorized())
		return
	}
	if _, err := s.Validator.Validate(r.Context(), claims.URL); err != nil {
		writeError(w, err)
		return
	}
	if claims.Size != nil && *claims.Size > s.Config.MaxDownloadBytes {
		writeError(w, errs.FileTooLarge(s.Config.MaxDownloadBytes))
		return
	}
	host := "unknown"
	if parsed, parseErr := url.Parse(claims.URL); parseErr == nil && parsed.Hostname() != "" {
		host = parsed.Hostname()
	}
	slog.Info("download delivery=redirect", "host", host, "size", claims.Size)
	http.Redirect(w, r, claims.URL, http.StatusTemporaryRedirect)
}

func proxyHost(rawURL string) bool {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return strings.Contains(host, "googlevideo.com") || strings.Contains(host, "youtube.com") || strings.HasSuffix(host, "youtu.be")
}

func (s *Server) serveJob(w http.ResponseWriter, r *http.Request, claims tokens.Claims) {
	job, ok := s.Jobs.Get(claims.Job)
	if !ok || job.FilePath == "" || !s.Jobs.Contains(job.FilePath) {
		writeError(w, errs.Unauthorized())
		return
	}
	file, err := os.Open(job.FilePath)
	if err != nil {
		writeError(w, errs.Unauthorized())
		return
	}
	info, err := file.Stat()
	if err != nil || info.IsDir() {
		file.Close()
		writeError(w, errs.Unauthorized())
		return
	}
	name := providers.ASCIIFilename(firstNonEmpty(job.FileName, claims.Name, "video.mp4"))
	mime := job.MimeType
	if mime == "" {
		mime = claims.MIME
	}
	if mime == "" {
		mime = "video/mp4"
	}
	short := job.ID
	if len(short) > 8 {
		short = short[:8]
	}
	slog.Info("download delivery=proxy_file", "job", short, "bytes", info.Size(), "range", r.Header.Get("Range") != "")
	w.Header().Set("Content-Type", mime)
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	http.ServeContent(w, r, name, info.ModTime(), file)
	file.Close()
	// The phone probes with a tiny range, then downloads the file in several
	// pieces. Deleting on that first check made the real save look unauthorized.
	if r.Header.Get("Range") == "" {
		s.Jobs.Pop(job.ID)
		jobs.DeleteMedia(job.FilePath)
	}
}

func (s *Server) prepare(jobID, rawURL, formatID, publicBase string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	work, err := s.Jobs.WorkDir(jobID)
	if err != nil {
		s.Jobs.MarkFailed(jobID, "platform_unavailable", errs.PlatformUnavailable("").Message)
		return
	}
	result, err := s.Registry.Prepare(ctx, rawURL, formatID, work, func(value float64) {
		s.Jobs.SetProgress(jobID, value)
	})
	if err != nil {
		_ = os.RemoveAll(work)
		s.failJob(jobID, err)
		return
	}
	if result.Filesize > s.Config.MaxDownloadBytes {
		jobs.DeleteMedia(result.Path)
		s.Jobs.MarkFailed(jobID, "file_too_large", errs.FileTooLarge(s.Config.MaxDownloadBytes).Message)
		return
	}
	size := result.Filesize
	if s.Objects != nil && s.Objects.Enabled() {
		signed, putErr := s.Objects.Put(ctx, result.Path, result.Name, result.MIME)
		if putErr == nil {
			if _, valid := s.Validator.Validate(ctx, signed); valid == nil {
				s.Jobs.MarkReady(jobID, "", result.MIME, result.Name, signed, &size)
				jobs.DeleteMedia(result.Path)
				slog.Info("download delivery=object_store", "size", size)
				return
			}
		}
		slog.Info("object storage skipped", "err", putErr)
	}
	token, err := s.Tokens.IssueJob(jobID, result.MIME, result.Name)
	if err != nil {
		jobs.DeleteMedia(result.Path)
		s.Jobs.MarkFailed(jobID, "platform_unavailable", errs.PlatformUnavailable("").Message)
		return
	}
	s.Jobs.MarkReady(jobID, result.Path, result.MIME, result.Name, strings.TrimRight(publicBase, "/")+"/api/v1/files/"+token, &size)
	slog.Info("download delivery=proxy_file", "size", size)
}

func (s *Server) failJob(id string, err error) {
	var api *errs.Error
	if errors.As(err, &api) {
		s.Jobs.MarkFailed(id, api.Code, api.Message)
		slog.Info("download delivery=prepare_local_failed", "code", api.Code, "message", api.Message)
		return
	}
	fallback := errs.PlatformUnavailable("")
	s.Jobs.MarkFailed(id, fallback.Code, fallback.Message)
	slog.Info("download delivery=prepare_local_failed", "code", fallback.Code)
}

func (s *Server) requireKey(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := auth.Authorize(r, s.Config); err != nil {
			writeError(w, err)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		next.ServeHTTP(&secureWriter{ResponseWriter: w, path: r.URL.Path}, r)
	})
}

type secureWriter struct {
	http.ResponseWriter
	path  string
	wrote bool
}

func (w *secureWriter) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.wrote = true
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if strings.HasPrefix(w.path, "/api/") || w.path == "/health" {
		w.Header().Set("Cache-Control", "no-store")
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *secureWriter) Write(p []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(p)
}

func (w *secureWriter) Flush() {
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *Server) limit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit, ok := s.limiter.limitFor(r.URL.Path)
		if !ok {
			next.ServeHTTP(w, r)
			return
		}
		if !s.limiter.allow(clientIP(r), r.URL.Path, limit) {
			writeError(w, errs.RateLimited())
			return
		}
		next.ServeHTTP(w, r)
	})
}

type rateLimiter struct {
	mu       sync.Mutex
	analyze  int
	download int
	hits     map[string][]time.Time
}

func (l *rateLimiter) limitFor(path string) (int, bool) {
	switch {
	case strings.HasSuffix(path, "/analyze"):
		return l.analyze, true
	case strings.HasSuffix(path, "/download"):
		return l.download, true
	default:
		return 0, false
	}
}

func (l *rateLimiter) allow(ip, path string, limit int) bool {
	parts := strings.Split(path, "/")
	bucket := path
	if len(parts) > 3 {
		bucket = parts[3]
	}
	key := ip + ":" + bucket
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	window := l.hits[key]
	kept := window[:0]
	for _, hit := range window {
		if now.Sub(hit) <= time.Minute {
			kept = append(kept, hit)
		}
	}
	if len(kept) >= limit {
		l.hits[key] = kept
		return false
	}
	l.hits[key] = append(kept, now)
	return true
}

func clientIP(r *http.Request) string {
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		if ip := strings.TrimSpace(strings.Split(forwarded, ",")[0]); ip != "" {
			return ip
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		if r.RemoteAddr == "" {
			return "unknown"
		}
		return r.RemoteAddr
	}
	return host
}

func publicBase(r *http.Request, cfg config.Config) string {
	host := firstHeader(r, "X-Forwarded-Host", "Host")
	host = strings.TrimSpace(strings.Split(host, ",")[0])
	proto := firstHeader(r, "X-Forwarded-Proto", "X-Forwarded-Protocol")
	proto = strings.TrimSpace(strings.Split(proto, ",")[0])
	if proto == "" {
		if strings.Contains(host, "workers.dev") || strings.Contains(host, "cloudflare") || strings.Contains(host, "koyeb.app") || strings.Contains(host, "onrender.com") {
			proto = "https"
		} else if r.TLS != nil {
			proto = "https"
		} else {
			proto = "http"
		}
	}
	local := host == "" || strings.HasPrefix(host, "127.0.0.1") || strings.HasPrefix(host, "localhost") || strings.HasPrefix(host, "10.0.2.2") || strings.HasPrefix(host, "0.0.0.0")
	if local {
		return strings.TrimRight(cfg.PublicBaseURL, "/")
	}
	return strings.TrimRight(proto+"://"+host, "/")
}

func firstHeader(r *http.Request, names ...string) string {
	for _, name := range names {
		if value := strings.TrimSpace(r.Header.Get(name)); value != "" {
			return value
		}
	}
	return ""
}

func readJSON(w http.ResponseWriter, r *http.Request, dest any) error {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(dest); err != nil {
		return errs.InvalidURL("That URL is not valid.")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		http.Error(w, `{"success":false,"error":{"code":"platform_unavailable","message":"The source platform is temporarily unavailable. Try again later."}}`, http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

func writeError(w http.ResponseWriter, err error) {
	var api *errs.Error
	if !errors.As(err, &api) || api == nil {
		api = errs.PlatformUnavailable("")
	}
	writeJSON(w, api.StatusCode, models.ErrorResponse{
		Success: false,
		Error:   models.ErrorBody{Code: api.Code, Message: api.Message},
	})
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
