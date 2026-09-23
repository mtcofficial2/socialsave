// Package jobs is the in-memory prepare-local queue and its reaper.
package jobs

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Job is one prepare-local download.
type Job struct {
	ID           string
	State        string
	Progress     float64
	FilePath     string
	MimeType     string
	FileName     string
	Filesize     *int64
	DownloadURL  string
	ErrorCode    string
	ErrorMessage string
	CreatedAt    time.Time
	ReadyAt      time.Time
}

// Store keeps jobs in memory and deletes temp files when they expire.
type Store struct {
	mu  sync.Mutex
	ttl time.Duration
	dir string
	all map[string]*Job
}

// NewStore keeps jobs for ttl (minimum one minute) under the system temp dir.
func NewStore(ttl time.Duration) *Store {
	if ttl < time.Minute {
		ttl = time.Minute
	}
	dir := filepath.Join(os.TempDir(), "socialsave-jobs")
	_ = os.MkdirAll(dir, 0o700)
	return &Store{
		ttl: ttl,
		dir: dir,
		all: map[string]*Job{},
	}
}

// Root is the temp directory prepared files must live under.
func (s *Store) Root() string {
	return s.dir
}

// Create inserts a processing job and returns a copy of it.
func (s *Store) Create() Job {
	s.Purge()
	job := &Job{
		ID:        newID(),
		State:     "processing",
		MimeType:  "video/mp4",
		FileName:  "video.mp4",
		CreatedAt: time.Now(),
	}
	s.mu.Lock()
	s.all[job.ID] = job
	s.mu.Unlock()
	return *job
}

// Get returns a copy, after dropping expired jobs.
func (s *Store) Get(id string) (Job, bool) {
	s.Purge()
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.all[id]
	if !ok {
		return Job{}, false
	}
	return *job, true
}

// Pop removes a job and returns a copy.
func (s *Store) Pop(id string) (Job, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.all[id]
	if !ok {
		return Job{}, false
	}
	delete(s.all, id)
	return *job, true
}

// SetProgress updates a processing job. Values are capped below 1 until ready.
func (s *Store) SetProgress(id string, value float64) {
	if value < 0 {
		value = 0
	}
	if value > 0.99 {
		value = 0.99
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.all[id]
	if ok && job.State == "processing" {
		job.Progress = value
	}
}

// MarkReady records a finished file or an external download URL.
func (s *Store) MarkReady(id, filePath, mime, name, downloadURL string, size *int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.all[id]
	if !ok {
		return
	}
	job.State = "ready"
	job.Progress = 1
	job.ReadyAt = time.Now()
	job.FilePath = filePath
	job.MimeType = mime
	job.FileName = name
	job.Filesize = size
	job.DownloadURL = downloadURL
}

// MarkFailed records a terminal error.
func (s *Store) MarkFailed(id, code, message string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job, ok := s.all[id]
	if !ok {
		return
	}
	job.State = "failed"
	job.ErrorCode = code
	job.ErrorMessage = message
}

// WorkDir creates a private directory for one yt-dlp run.
func (s *Store) WorkDir(id string) (string, error) {
	dir := filepath.Join(s.dir, "socialsave-"+id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return dir, nil
}

// Contains reports whether path is inside the job temp root.
func (s *Store) Contains(path string) bool {
	root, err := filepath.Abs(s.dir)
	if err != nil {
		return false
	}
	target, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// Run purges expired jobs until ctx is cancelled.
func (s *Store) Run(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.Purge()
		}
	}
}

// Purge drops expired jobs and deletes their temp files.
func (s *Store) Purge() {
	now := time.Now()
	s.mu.Lock()
	var removed []Job
	for id, job := range s.all {
		var expired bool
		switch job.State {
		case "processing":
			limit := s.ttl
			if limit < 15*time.Minute {
				limit = 15 * time.Minute
			}
			expired = now.Sub(job.CreatedAt) > limit
		case "failed":
			expired = now.Sub(job.CreatedAt) > 5*time.Minute
		default:
			start := job.ReadyAt
			if start.IsZero() {
				start = job.CreatedAt
			}
			expired = now.Sub(start) > s.ttl
		}
		if expired {
			removed = append(removed, *job)
			delete(s.all, id)
		}
	}
	s.mu.Unlock()
	for _, job := range removed {
		DeleteMedia(job.FilePath)
	}
}

// DeleteMedia removes a prepared file and its socialsave-* directory.
func DeleteMedia(path string) {
	if path == "" {
		return
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		slog.Warn("cleanup failed", "path_kind", "temp")
		return
	}
	parent := filepath.Dir(path)
	if strings.HasPrefix(filepath.Base(parent), "socialsave-") {
		_ = os.RemoveAll(parent)
	}
	slog.Info("cleanup success", "path_kind", "temp")
}

func newID() string {
	var buf [16]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return hex.EncodeToString([]byte(time.Now().UTC().Format("20060102150405.000000000")))
	}
	buf[6] = (buf[6] & 0x0f) | 0x40
	buf[8] = (buf[8] & 0x3f) | 0x80
	return hex.EncodeToString(buf[:])
}
