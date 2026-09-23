// Package storage optionally uploads a prepared file with HTTP PUT.
//
// OBJECT_STORAGE_URL is a base the API can PUT to. The object is then
// expected at that same path (or at a Location / {"url":"..."} response).
// When the variable is empty, Put is disabled and the API serves the temp
// file once through /api/v1/files/{token}.
package storage

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Store uploads prepared media when configured.
type Store struct {
	BaseURL string
	Client  *http.Client
}

// New returns a store. An empty base URL disables uploads.
func New(baseURL string) *Store {
	return &Store{
		BaseURL: strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		Client: &http.Client{
			Timeout: 2 * time.Minute,
		},
	}
}

// Enabled reports whether an upload endpoint is configured.
func (s *Store) Enabled() bool {
	return s != nil && s.BaseURL != ""
}

// Put uploads path and returns a URL the client can fetch.
func (s *Store) Put(ctx context.Context, path, name, mime string) (string, error) {
	if !s.Enabled() {
		return "", fmt.Errorf("object storage disabled")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if mime == "" {
		mime = "application/octet-stream"
	}
	endpoint := s.BaseURL + "/" + url.PathEscape(name)
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, endpoint, file)
	if err != nil {
		return "", err
	}
	req.ContentLength = info.Size()
	req.Header.Set("Content-Type", mime)
	client := s.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("object storage status %d", resp.StatusCode)
	}
	if loc := strings.TrimSpace(resp.Header.Get("Location")); loc != "" {
		return absolute(endpoint, loc), nil
	}
	var payload struct {
		URL string `json:"url"`
	}
	if json.Unmarshal(body, &payload) == nil && strings.TrimSpace(payload.URL) != "" {
		return payload.URL, nil
	}
	parsed, err := url.Parse(endpoint)
	if err != nil {
		return "", err
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String(), nil
}

func absolute(base, ref string) string {
	parsed, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	if parsed.IsAbs() {
		return parsed.String()
	}
	parent, err := url.Parse(base)
	if err != nil {
		return ref
	}
	return parent.ResolveReference(parsed).String()
}
