package server

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// Calls send voice straight between phones. When both sit behind a mobile
// carrier NAT that path never opens, so a TURN relay carries the audio
// instead. The relay is a separate service (Cloudflare or any coturn
// server); voice never passes through this API, which only hands out
// short-lived credentials.
//
// Configure one of these on the server:
//   - CLOUDFLARE_TURN_KEY_ID and CLOUDFLARE_TURN_KEY_API_TOKEN
//   - TURN_URLS (comma separated) and TURN_SECRET (coturn REST auth)
//   - TURN_URLS, TURN_USERNAME and TURN_CREDENTIAL (fixed account)
//
// With none set, calls keep using STUN only.

type iceServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

var iceDefaultStun = []iceServer{{URLs: []string{
	"stun:stun.cloudflare.com:3478",
	"stun:stun.l.google.com:19302",
}}}

const (
	iceCredentialTTL = 24 * time.Hour
	// Cloudflare credentials are shared until half their life is used, so a
	// call never starts with a credential about to expire.
	iceReuseFor  = 12 * time.Hour
	iceRetryWait = time.Minute
)

type iceSource struct {
	cfKeyID    string
	cfToken    string
	cfEndpoint string
	urls       []string
	secret     string
	username   string
	credential string
	client     *http.Client
	now        func() time.Time

	mu       sync.Mutex
	cached   []iceServer
	cachedAt time.Time
	failedAt time.Time
}

func newIceSourceFromEnv() *iceSource {
	return &iceSource{
		cfKeyID:    strings.TrimSpace(os.Getenv("CLOUDFLARE_TURN_KEY_ID")),
		cfToken:    strings.TrimSpace(os.Getenv("CLOUDFLARE_TURN_KEY_API_TOKEN")),
		cfEndpoint: "https://rtc.live.cloudflare.com/v1/turn/keys/",
		urls:       splitIceURLs(os.Getenv("TURN_URLS")),
		secret:     strings.TrimSpace(os.Getenv("TURN_SECRET")),
		username:   strings.TrimSpace(os.Getenv("TURN_USERNAME")),
		credential: strings.TrimSpace(os.Getenv("TURN_CREDENTIAL")),
		client:     &http.Client{Timeout: 8 * time.Second},
		now:        time.Now,
	}
}

func splitIceURLs(raw string) []string {
	out := []string{}
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, "turn:") || strings.HasPrefix(part, "turns:") || strings.HasPrefix(part, "stun:") {
			out = append(out, part)
		}
	}
	return out
}

// mode names the relay this server can hand out, for logs and the app.
func (s *iceSource) mode() string {
	switch {
	case s == nil:
		return "stun"
	case s.cfKeyID != "" && s.cfToken != "":
		return "cloudflare"
	case len(s.urls) > 0 && s.secret != "":
		return "turn-rest"
	case len(s.urls) > 0 && s.username != "" && s.credential != "":
		return "turn-static"
	}
	return "stun"
}

// servers returns the ICE servers for one signed-in user and how long the
// app may keep them.
func (s *iceSource) servers(ctx context.Context, userID string) ([]iceServer, time.Duration) {
	switch s.mode() {
	case "cloudflare":
		if list, age, ok := s.cloudflare(ctx); ok {
			return list, iceCredentialTTL - age
		}
	case "turn-rest":
		expiry := s.now().Add(iceCredentialTTL).Unix()
		name := fmt.Sprintf("%d:%s", expiry, userID)
		mac := hmac.New(sha1.New, []byte(s.secret))
		mac.Write([]byte(name))
		return append(append([]iceServer{}, iceDefaultStun...), iceServer{
			URLs:       s.urls,
			Username:   name,
			Credential: base64.StdEncoding.EncodeToString(mac.Sum(nil)),
		}), iceCredentialTTL
	case "turn-static":
		return append(append([]iceServer{}, iceDefaultStun...), iceServer{
			URLs:       s.urls,
			Username:   s.username,
			Credential: s.credential,
		}), iceCredentialTTL
	}
	return iceDefaultStun, 6 * time.Hour
}

func (s *iceSource) cloudflare(ctx context.Context) ([]iceServer, time.Duration, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	if s.cached != nil && now.Sub(s.cachedAt) < iceReuseFor {
		return s.cached, now.Sub(s.cachedAt), true
	}
	if !s.failedAt.IsZero() && now.Sub(s.failedAt) < iceRetryWait {
		return nil, 0, false
	}
	list, err := s.fetchCloudflare(ctx)
	if err != nil {
		s.failedAt = now
		slog.Warn("turn credentials failed", "error", err)
		return nil, 0, false
	}
	s.cached = list
	s.cachedAt = now
	s.failedAt = time.Time{}
	return list, 0, true
}

func (s *iceSource) fetchCloudflare(ctx context.Context) ([]iceServer, error) {
	body, _ := json.Marshal(map[string]int64{"ttl": int64(iceCredentialTTL / time.Second)})
	url := s.cfEndpoint + s.cfKeyID + "/credentials/generate-ice-servers"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+s.cfToken)
	req.Header.Set("Content-Type", "application/json")
	res, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 64<<10))
	if err != nil {
		return nil, err
	}
	if res.StatusCode < 200 || res.StatusCode > 299 {
		return nil, fmt.Errorf("cloudflare turn status %d", res.StatusCode)
	}
	var parsed struct {
		IceServers []struct {
			URLs       any    `json:"urls"`
			Username   string `json:"username"`
			Credential string `json:"credential"`
		} `json:"iceServers"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}
	out := []iceServer{}
	hasRelay := false
	for _, item := range parsed.IceServers {
		urls := []string{}
		switch v := item.URLs.(type) {
		case string:
			urls = append(urls, v)
		case []any:
			for _, u := range v {
				if text, ok := u.(string); ok {
					urls = append(urls, text)
				}
			}
		}
		kept := []string{}
		for _, u := range urls {
			// Port 53 is blocked by many networks and only adds a timeout.
			if strings.Contains(u, ":53?") || strings.HasSuffix(u, ":53") {
				continue
			}
			kept = append(kept, u)
			if strings.HasPrefix(u, "turn") {
				hasRelay = true
			}
		}
		if len(kept) > 0 {
			out = append(out, iceServer{URLs: kept, Username: item.Username, Credential: item.Credential})
		}
	}
	if !hasRelay {
		return nil, fmt.Errorf("cloudflare turn returned no relay")
	}
	return append(out, iceServer{URLs: []string{"stun:stun.l.google.com:19302"}}), nil
}

func (s *Server) chatCallIce(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	list, ttl := s.ice.servers(r.Context(), user.ID)
	relay := false
	for _, server := range list {
		for _, u := range server.URLs {
			if strings.HasPrefix(u, "turn") {
				relay = true
			}
		}
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, map[string]any{
		"success":    true,
		"iceServers": list,
		"ttl":        int64(ttl / time.Second),
		"relay":      relay,
	})
}
