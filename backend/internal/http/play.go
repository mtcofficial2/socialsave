package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

type playSession struct {
	reader *io.PipeReader
	writer *io.PipeWriter
	cancel context.CancelFunc
	used   chan struct{}
	once   sync.Once
	mu     sync.Mutex
	err    error
}

func (s *Server) beginPlay(w http.ResponseWriter, pageURL, publicBase string) {
	id, err := s.startPlay(pageURL)
	if err != nil {
		writeError(w, err)
		return
	}
	token, err := s.Tokens.IssuePlay(id, "video/mp4", "preview.mp4")
	if err != nil {
		writeError(w, errs.PlatformUnavailable(""))
		return
	}
	mime := "video/mp4"
	name := "preview.mp4"
	short := id
	if len(short) > 12 {
		short = short[:12]
	}
	expires := time.Now().UTC().Add(s.Config.TokenTTL).Format(time.RFC3339)
	slog.Info("playback stream started", "id", short)
	writeJSON(w, http.StatusOK, models.DownloadResponse{
		Success:     true,
		DownloadURL: publicBase + "/api/v1/files/" + token,
		ID:          &short,
		State:       "ready",
		ExpiresAt:   &expires,
		MimeType:    &mime,
		FileName:    &name,
	})
}

func (s *Server) startPlay(pageURL string) (string, error) {
	id := newPlayID()
	reader, writer := io.Pipe()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)
	session := &playSession{reader: reader, writer: writer, cancel: cancel, used: make(chan struct{})}
	s.plays.Store(id, session)
	go func() {
		select {
		case <-session.used:
		case <-time.After(90 * time.Second):
			cancel()
		}
	}()
	go func() {
		defer cancel()
		defer writer.Close()
		err := s.Registry.WritePlayable(ctx, pageURL, writer)
		session.mu.Lock()
		session.err = err
		session.mu.Unlock()
		if err != nil {
			slog.Info("playback stream failed", "id", id[:8], "message", err.Error())
		}
		time.AfterFunc(2*time.Minute, func() {
			s.plays.Delete(id)
			reader.Close()
		})
	}()
	return id, nil
}

func (s *Server) servePlay(w http.ResponseWriter, r *http.Request, id string) {
	value, ok := s.plays.Load(id)
	if !ok {
		writeError(w, errs.PlatformUnavailable("This preview expired. Open it again."))
		return
	}
	session := value.(*playSession)
	session.once.Do(func() { close(session.used) })
	defer session.cancel()
	buffer := make([]byte, 32*1024)
	first := make(chan readResult, 1)
	go func() {
		n, err := session.reader.Read(buffer)
		first <- readResult{n: n, err: err}
	}()
	var opened readResult
	select {
	case opened = <-first:
	case <-r.Context().Done():
		return
	case <-time.After(50 * time.Second):
		writeError(w, errs.PlatformUnavailable("The video took too long to start. Try again."))
		return
	}
	if opened.n == 0 {
		session.mu.Lock()
		err := session.err
		session.mu.Unlock()
		if err != nil {
			writeError(w, err)
			return
		}
		writeError(w, errs.PlatformUnavailable("This video did not start. Try again."))
		return
	}
	header := w.Header()
	header.Set("Content-Type", "video/mp4")
	header.Del("Accept-Ranges")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	if _, err := w.Write(buffer[:opened.n]); err != nil {
		return
	}
	if flusher != nil {
		flusher.Flush()
	}
	buf := make([]byte, 256*1024)
	for {
		n, err := session.reader.Read(buf)
		if n > 0 {
			if _, writeErr := w.Write(buf[:n]); writeErr != nil {
				return
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			return
		}
	}
}

type readResult struct {
	n   int
	err error
}

func newPlayID() string {
	var buf [16]byte
	_, _ = rand.Read(buf[:])
	return hex.EncodeToString(buf[:])
}
