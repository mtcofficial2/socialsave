package server

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
	"github.com/go-chi/chi/v5"
)

func (s *Server) playlist(w http.ResponseWriter, r *http.Request) {
	var body models.AnalyzeRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	raw, err := s.validPage(r, body.URL)
	if err != nil {
		writeError(w, err)
		return
	}
	items, err := s.Registry.Playlist(r.Context(), raw)
	if err != nil {
		slog.Info("playlist failed", "message", err.Error())
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, models.PlaylistResponse{Success: true, Items: items})
}

func (s *Server) summarize(w http.ResponseWriter, r *http.Request) {
	var body models.SummarizeRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	title := strings.TrimSpace(body.Title)
	if title == "" || len(title) > 300 {
		writeError(w, errs.InvalidURL("Add the title of a video that is already saved."))
		return
	}
	author := trimLimit(body.Author, 200)
	source := strings.TrimSpace(body.SourceURL)
	if source != "" {
		if len(source) > 2048 {
			writeError(w, errs.InvalidURL("That URL is not valid."))
			return
		}
		checked, err := s.Validator.Validate(r.Context(), source)
		if err != nil {
			writeError(w, err)
			return
		}
		source = checked
	}
	key := strings.TrimSpace(s.Config.XAIAPIKey)
	if key == "" {
		writeError(w, errs.PlatformUnavailable("Summaries are not configured."))
		return
	}
	summary, err := summarizeSaved(r.Context(), key, title, author, source)
	if err != nil {
		slog.Info("summarize failed", "message", "model request failed")
		writeError(w, errs.PlatformUnavailable("A summary could not be written. Try again later."))
		return
	}
	writeJSON(w, http.StatusOK, models.SummarizeResponse{Success: true, Summary: summary})
}

func (s *Server) validPage(r *http.Request, raw string) (string, error) {
	if len(strings.TrimSpace(raw)) < 8 || len(raw) > 2048 {
		return "", errs.InvalidURL("That URL is not valid.")
	}
	return s.Validator.Validate(r.Context(), raw)
}

func trimLimit(value string, max int) string {
	value = strings.TrimSpace(value)
	if len(value) > max {
		return value[:max]
	}
	return value
}

func (s *Server) createPair(w http.ResponseWriter, r *http.Request) {
	var body models.PairCreateRequest
	if err := readJSON(w, r, &body); err != nil {
		writeError(w, err)
		return
	}
	items := sanitizePairItems(body.Items)
	if len(items) == 0 {
		writeError(w, errs.InvalidURL("The library index is empty."))
		return
	}
	code, expires := s.pairs.put(items)
	writeJSON(w, http.StatusOK, models.PairCreateResponse{
		Success:   true,
		Code:      code,
		ExpiresAt: expires.UTC().Format(time.RFC3339),
	})
}

func (s *Server) readPair(w http.ResponseWriter, r *http.Request) {
	code := strings.TrimSpace(chi.URLParam(r, "code"))
	items, ok := s.pairs.get(code)
	if !ok {
		writeError(w, errs.InvalidURL("That pairing code has expired. Create a new one on the phone."))
		return
	}
	writeJSON(w, http.StatusOK, models.PairReadResponse{Success: true, Items: items})
}

func sanitizePairItems(items []models.PairItem) []models.PairItem {
	if len(items) > 200 {
		items = items[:200]
	}
	out := make([]models.PairItem, 0, len(items))
	for _, item := range items {
		title := trimLimit(item.Title, 200)
		if title == "" {
			continue
		}
		out = append(out, models.PairItem{
			Title:     title,
			Platform:  trimLimit(item.Platform, 40),
			SourceURL: trimLimit(item.SourceURL, 2048),
			Quality:   trimLimit(item.Quality, 40),
		})
	}
	return out
}

type pairRecord struct {
	items   []models.PairItem
	expires time.Time
}

type pairStore struct {
	mu    sync.Mutex
	items map[string]pairRecord
}

func (p *pairStore) put(items []models.PairItem) (string, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.items == nil {
		p.items = map[string]pairRecord{}
	}
	now := time.Now()
	for code, record := range p.items {
		if now.After(record.expires) {
			delete(p.items, code)
		}
	}
	for len(p.items) >= 100 {
		var oldest string
		var when time.Time
		for code, record := range p.items {
			if oldest == "" || record.expires.Before(when) {
				oldest = code
				when = record.expires
			}
		}
		delete(p.items, oldest)
	}
	expires := now.Add(15 * time.Minute)
	code := pairCode()
	for _, taken := p.items[code]; taken; _, taken = p.items[code] {
		code = pairCode()
	}
	copied := append([]models.PairItem(nil), items...)
	p.items[code] = pairRecord{items: copied, expires: expires}
	return code, expires
}

func (p *pairStore) get(code string) ([]models.PairItem, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	record, ok := p.items[strings.ToUpper(strings.TrimSpace(code))]
	if !ok || time.Now().After(record.expires) {
		if ok {
			delete(p.items, strings.ToUpper(strings.TrimSpace(code)))
		}
		return nil, false
	}
	return append([]models.PairItem(nil), record.items...), true
}

func pairCode() string {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var buf [6]byte
	var raw [6]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "SAVE00"
	}
	for i, value := range raw {
		buf[i] = alphabet[int(value)%len(alphabet)]
	}
	return string(buf[:])
}

func summarizeSaved(ctx context.Context, key, title, author, source string) (string, error) {
	prompt := "Title: " + title
	if author != "" {
		prompt += "\nAuthor: " + author
	}
	if source != "" {
		prompt += "\nPublic page: " + source
	}
	payload := map[string]any{
		"model": "grok-4.7",
		"store": false,
		"input": []map[string]string{
			{
				"role":    "system",
				"content": "You summarize a public video the user already saved. Use only the title, author, and page link they send. Do not claim you watched the file. Do not invent a plot. If those details are not enough, say so in one sentence. Stay under 120 words.",
			},
			{"role": "user", "content": prompt},
		},
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.x.ai/v1/responses", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+key)
	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", errs.PlatformUnavailable("")
	}
	text := outputText(raw)
	if strings.TrimSpace(text) == "" {
		return "", errs.PlatformUnavailable("")
	}
	return strings.TrimSpace(text), nil
}

func outputText(raw []byte) string {
	var payload struct {
		OutputText string `json:"output_text"`
		Output     []struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return ""
	}
	if strings.TrimSpace(payload.OutputText) != "" {
		return payload.OutputText
	}
	var parts []string
	for _, item := range payload.Output {
		for _, content := range item.Content {
			if strings.TrimSpace(content.Text) != "" {
				parts = append(parts, content.Text)
			}
		}
	}
	return strings.Join(parts, "\n")
}
