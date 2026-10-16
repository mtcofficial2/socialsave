package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
)

// Relay: "nearby share" for the web build. One browser uploads a file and
// gets a 6-character code; another opens the site, enters the code and
// downloads it. Files live in a temp dir and are deleted after relayTTL or
// relayMaxDownloads downloads, whichever comes first. Size and disk are
// capped so a free Render instance stays safe.
const (
	relayMaxFile      = 200 << 20 // 200 MB per file
	relayDiskCap      = 1 << 30   // 1 GB across all files
	relayTTL          = 30 * time.Minute
	relayMaxDownloads = 3
	relayUploadsPerIP = 6  // per relayUploadWindow
	relayReadsPerIP   = 120 // per minute
	relayUploadWindow = 10 * time.Minute
)

type relayEntry struct {
	code        string
	name        string
	contentType string
	size        int64
	path        string
	expires     time.Time
	downloads   int
	active      int
}

type relayStore struct {
	mu       sync.Mutex
	dir      string
	entries  map[string]*relayEntry
	reserved int64
	hits     map[string][]time.Time
	once     sync.Once
	now      func() time.Time
	maxFile  int64
	diskCap  int64
}

func newRelayStore(dir string) *relayStore {
	if dir == "" {
		dir = filepath.Join(os.TempDir(), "socialsave-relay")
	}
	return &relayStore{
		dir:     dir,
		entries: map[string]*relayEntry{},
		hits:    map[string][]time.Time{},
		now:     time.Now,
		maxFile: relayMaxFile,
		diskCap: relayDiskCap,
	}
}

func (s *relayStore) start() {
	s.once.Do(func() {
		_ = os.RemoveAll(s.dir)
		_ = os.MkdirAll(s.dir, 0o700)
		go func() {
			ticker := time.NewTicker(time.Minute)
			defer ticker.Stop()
			for range ticker.C {
				s.sweep()
			}
		}()
	})
}

func (s *relayStore) sweep() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for code, entry := range s.entries {
		if now.After(entry.expires) && entry.active == 0 {
			s.dropLocked(code)
		}
	}
}

func (s *relayStore) dropLocked(code string) {
	entry, ok := s.entries[code]
	if !ok {
		return
	}
	delete(s.entries, code)
	s.reserved -= entry.size
	if s.reserved < 0 {
		s.reserved = 0
	}
	_ = os.Remove(entry.path)
}

// allow is a sliding-window per-IP limit.
func (s *relayStore) allow(key string, limit int, window time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	kept := s.hits[key][:0]
	for _, hit := range s.hits[key] {
		if now.Sub(hit) <= window {
			kept = append(kept, hit)
		}
	}
	if len(kept) >= limit {
		s.hits[key] = kept
		return false
	}
	s.hits[key] = append(kept, now)
	if len(s.hits) > 10000 {
		s.hits = map[string][]time.Time{}
	}
	return true
}

func (s *relayStore) reserve(n int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reserved+n > s.diskCap {
		return false
	}
	s.reserved += n
	return true
}

func (s *relayStore) release(n int64) {
	s.mu.Lock()
	s.reserved -= n
	if s.reserved < 0 {
		s.reserved = 0
	}
	s.mu.Unlock()
}

func (s *relayStore) get(code string) (*relayEntry, bool) {
	code = strings.ToUpper(strings.TrimSpace(code))
	s.mu.Lock()
	defer s.mu.Unlock()
	entry, ok := s.entries[code]
	if !ok {
		return nil, false
	}
	if s.now().After(entry.expires) || entry.downloads >= relayMaxDownloads && entry.active == 0 {
		s.dropLocked(code)
		return nil, false
	}
	copied := *entry
	return &copied, true
}

type relayInfo struct {
	Success       bool   `json:"success"`
	Code          string `json:"code"`
	Name          string `json:"name"`
	Size          int64  `json:"size"`
	ContentType   string `json:"content_type"`
	ExpiresAt     string `json:"expires_at"`
	DownloadsLeft int    `json:"downloads_left"`
}

func relayInfoOf(entry *relayEntry) relayInfo {
	left := relayMaxDownloads - entry.downloads
	if left < 0 {
		left = 0
	}
	return relayInfo{
		Success:       true,
		Code:          entry.code,
		Name:          entry.name,
		Size:          entry.size,
		ContentType:   entry.contentType,
		ExpiresAt:     entry.expires.UTC().Format(time.RFC3339),
		DownloadsLeft: left,
	}
}

func relayFail(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, status, map[string]any{
		"success": false,
		"error":   map[string]string{"code": code, "message": message},
	})
}

// relaySafeType keeps only media types that are safe to show inline on this
// origin. Anything else (HTML, SVG, scripts...) is served as a download.
func relaySafeType(raw, name string) (string, bool) {
	value, _, err := mime.ParseMediaType(raw)
	if err != nil || value == "" || value == "application/octet-stream" {
		value = mime.TypeByExtension(strings.ToLower(filepath.Ext(name)))
		value, _, _ = mime.ParseMediaType(value)
	}
	value = strings.ToLower(value)
	switch {
	case strings.HasPrefix(value, "video/"), strings.HasPrefix(value, "audio/"):
		return value, true
	case value == "image/png", value == "image/jpeg", value == "image/gif", value == "image/webp":
		return value, true
	}
	return "application/octet-stream", false
}

func relayCleanName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	name = strings.Map(func(r rune) rune {
		if r < 32 || r == 127 || strings.ContainsRune(`/\:*?"<>|`, r) {
			return '_'
		}
		return r
	}, name)
	name = strings.TrimSpace(name)
	if name == "" || name == "." || name == ".." {
		name = "file"
	}
	if len(name) > 150 {
		ext := filepath.Ext(name)
		if len(ext) > 12 {
			ext = ""
		}
		name = name[:150-len(ext)] + ext
	}
	return name
}

func (s *Server) relayUpload(w http.ResponseWriter, r *http.Request) {
	store := s.relay
	store.start()
	if !store.allow("up:"+clientIP(r), relayUploadsPerIP, relayUploadWindow) {
		relayFail(w, http.StatusTooManyRequests, "rate_limited", "Too many uploads. Wait a few minutes and try again.")
		return
	}
	if r.ContentLength > store.maxFile+(1<<20) {
		relayFail(w, http.StatusRequestEntityTooLarge, "too_large", "That file is over the 200 MB limit.")
		return
	}
	// The server's 30 s ReadTimeout is too short for a big upload.
	_ = http.NewResponseController(w).SetReadDeadline(time.Now().Add(20 * time.Minute))

	reserve := store.maxFile
	if r.ContentLength > 0 && r.ContentLength < reserve {
		reserve = r.ContentLength
	}
	if !store.reserve(reserve) {
		relayFail(w, http.StatusServiceUnavailable, "busy", "The share space is full right now. Try again in a few minutes.")
		return
	}
	reserved := reserve
	defer func() { store.release(reserved) }()

	r.Body = http.MaxBytesReader(w, r.Body, store.maxFile+(1<<20))
	reader, err := r.MultipartReader()
	if err != nil {
		relayFail(w, http.StatusBadRequest, "bad_request", "Send the file as multipart form data.")
		return
	}
	var part interface {
		io.Reader
		FileName() string
		Close() error
	}
	var partType string
	for {
		next, err := reader.NextPart()
		if err != nil {
			relayFail(w, http.StatusBadRequest, "bad_request", "No file in the upload.")
			return
		}
		if next.FormName() == "file" && next.FileName() != "" {
			part = next
			partType = next.Header.Get("Content-Type")
			break
		}
		_ = next.Close()
	}
	defer part.Close()

	name := relayCleanName(part.FileName())
	tmp, err := os.CreateTemp(store.dir, "up-*")
	if err != nil {
		_ = os.MkdirAll(store.dir, 0o700)
		tmp, err = os.CreateTemp(store.dir, "up-*")
		if err != nil {
			relayFail(w, http.StatusServiceUnavailable, "busy", "Could not store the file. Try again.")
			return
		}
	}
	written, err := io.Copy(tmp, io.LimitReader(part, store.maxFile+1))
	closeErr := tmp.Close()
	if err != nil || closeErr != nil || written == 0 || written > store.maxFile {
		_ = os.Remove(tmp.Name())
		var tooBig *http.MaxBytesError
		if written > store.maxFile || errors.As(err, &tooBig) {
			relayFail(w, http.StatusRequestEntityTooLarge, "too_large", "That file is over the 200 MB limit.")
			return
		}
		relayFail(w, http.StatusBadRequest, "bad_request", "The upload did not finish. Try again.")
		return
	}
	contentType, _ := relaySafeType(partType, name)

	store.mu.Lock()
	// Swap the up-front reservation for the real size.
	store.reserved += written - reserved
	reserved = 0
	if store.reserved > store.diskCap {
		store.reserved -= written
		store.mu.Unlock()
		_ = os.Remove(tmp.Name())
		relayFail(w, http.StatusServiceUnavailable, "busy", "The share space is full right now. Try again in a few minutes.")
		return
	}
	code := pairCode()
	for _, taken := store.entries[code]; taken; _, taken = store.entries[code] {
		code = pairCode()
	}
	entry := &relayEntry{
		code:        code,
		name:        name,
		contentType: contentType,
		size:        written,
		path:        tmp.Name(),
		expires:     store.now().Add(relayTTL),
	}
	store.entries[code] = entry
	info := relayInfoOf(entry)
	store.mu.Unlock()

	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, info)
}

func (s *Server) relayInfo(w http.ResponseWriter, r *http.Request) {
	if !s.relay.allow("rd:"+clientIP(r), relayReadsPerIP, time.Minute) {
		relayFail(w, http.StatusTooManyRequests, "rate_limited", "Too many tries. Wait a minute.")
		return
	}
	entry, ok := s.relay.get(chi.URLParam(r, "code"))
	if !ok {
		relayFail(w, http.StatusNotFound, "not_found", "That code has expired or is wrong. Ask for a new one.")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, relayInfoOf(entry))
}

func (s *Server) relayFile(w http.ResponseWriter, r *http.Request) {
	store := s.relay
	if !store.allow("rd:"+clientIP(r), relayReadsPerIP, time.Minute) {
		relayFail(w, http.StatusTooManyRequests, "rate_limited", "Too many tries. Wait a minute.")
		return
	}
	code := strings.ToUpper(strings.TrimSpace(chi.URLParam(r, "code")))
	// A new download is a request for the start of the file; later byte
	// ranges (a video seeking) belong to the same download.
	rangeHeader := strings.TrimSpace(r.Header.Get("Range"))
	fresh := r.Method == http.MethodGet && (rangeHeader == "" || rangeHeader == "bytes=0-")

	store.mu.Lock()
	entry, ok := store.entries[code]
	if ok && store.now().After(entry.expires) {
		ok = false
	}
	if ok && fresh && entry.downloads >= relayMaxDownloads {
		ok = false
	}
	if !ok {
		if entry != nil && entry.active == 0 {
			store.dropLocked(code)
		}
		store.mu.Unlock()
		relayFail(w, http.StatusNotFound, "not_found", "That code has expired or was used up. Ask for a new one.")
		return
	}
	if fresh {
		entry.downloads++
	}
	entry.active++
	path, name, contentType := entry.path, entry.name, entry.contentType
	store.mu.Unlock()

	defer func() {
		store.mu.Lock()
		entry.active--
		// Keep the last download's range requests working for a moment.
		if entry.downloads >= relayMaxDownloads && entry.active == 0 {
			if left := entry.expires.Sub(store.now()); left > 2*time.Minute {
				entry.expires = store.now().Add(2 * time.Minute)
			}
		}
		store.mu.Unlock()
	}()

	file, err := os.Open(path)
	if err != nil {
		relayFail(w, http.StatusNotFound, "not_found", "That file is gone. Ask for a new code.")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		relayFail(w, http.StatusNotFound, "not_found", "That file is gone. Ask for a new code.")
		return
	}
	_, inline := relaySafeType(contentType, name)
	disposition := "attachment"
	if inline && r.URL.Query().Get("dl") == "" {
		disposition = "inline"
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Disposition", fmt.Sprintf("%s; filename=%q; filename*=UTF-8''%s",
		disposition, strings.Map(func(r rune) rune {
			if r > 126 || r == '"' {
				return '_'
			}
			return r
		}, name), url.PathEscape(name)))
	w.Header().Set("Content-Security-Policy", "sandbox; default-src 'none'; media-src 'self'")
	w.Header().Set("Cache-Control", "private, no-store")
	http.ServeContent(w, r, "", info.ModTime(), file)
}

// relayErrorJSON is used by tests.
func relayErrorJSON(body []byte) string {
	var parsed struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &parsed)
	return parsed.Error.Code
}
