package server

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestIceStunOnlyByDefault(t *testing.T) {
	var src *iceSource
	list, ttl := src.servers(context.Background(), "u1")
	if len(list) != 1 || ttl <= 0 || list[0].Username != "" {
		t.Fatalf("default %+v %v", list, ttl)
	}
	empty := &iceSource{now: time.Now}
	if empty.mode() != "stun" {
		t.Fatal(empty.mode())
	}
}

func TestIceTurnRestCredential(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	src := &iceSource{urls: splitIceURLs("turn:t.example.com:3478, junk ,turns:t.example.com:443?transport=tcp"), secret: "s3cret", now: func() time.Time { return now }}
	if src.mode() != "turn-rest" {
		t.Fatal(src.mode())
	}
	list, _ := src.servers(context.Background(), "u42")
	relay := list[len(list)-1]
	if len(relay.URLs) != 2 || !strings.HasSuffix(relay.Username, ":u42") {
		t.Fatalf("relay %+v", relay)
	}
	mac := hmac.New(sha1.New, []byte("s3cret"))
	mac.Write([]byte(relay.Username))
	if relay.Credential != base64.StdEncoding.EncodeToString(mac.Sum(nil)) {
		t.Fatal("credential does not match coturn REST auth")
	}
	static := &iceSource{urls: []string{"turn:x:3478"}, username: "a", credential: "b", now: time.Now}
	list, _ = static.servers(context.Background(), "u1")
	if static.mode() != "turn-static" || list[len(list)-1].Credential != "b" {
		t.Fatalf("static %+v", list)
	}
}

func TestIceCloudflareCachedAndFiltered(t *testing.T) {
	var calls atomic.Int32
	fail := atomic.Bool{}
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Authorization") != "Bearer tok" || !strings.HasSuffix(r.URL.Path, "/kid/credentials/generate-ice-servers") {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if fail.Load() {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478","stun:stun.cloudflare.com:53"]},{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turn:turn.cloudflare.com:53?transport=udp","turns:turn.cloudflare.com:443?transport=tcp"],"username":"user","credential":"pass"}]}`))
	}))
	defer api.Close()
	now := time.Unix(1_800_000_000, 0)
	src := &iceSource{cfKeyID: "kid", cfToken: "tok", cfEndpoint: api.URL + "/v1/turn/keys/", client: api.Client(), now: func() time.Time { return now }}
	list, ttl := src.servers(context.Background(), "u1")
	raw, _ := json.Marshal(list)
	if strings.Contains(string(raw), ":53") || !strings.Contains(string(raw), `"credential":"pass"`) || ttl != iceCredentialTTL {
		t.Fatalf("cloudflare list %s %v", raw, ttl)
	}
	now = now.Add(time.Hour)
	_, ttl = src.servers(context.Background(), "u2")
	if calls.Load() != 1 || ttl != iceCredentialTTL-time.Hour {
		t.Fatalf("not cached: %d calls ttl %v", calls.Load(), ttl)
	}
	// After the reuse window a failed refresh falls back to STUN and waits.
	now = now.Add(iceReuseFor)
	fail.Store(true)
	list, _ = src.servers(context.Background(), "u1")
	if len(list) != 1 || list[0].Username != "" {
		t.Fatalf("fallback %+v", list)
	}
	src.servers(context.Background(), "u1")
	if calls.Load() != 2 {
		t.Fatalf("retried too soon: %d", calls.Load())
	}
}

func TestCallIceEndpointNeedsSignIn(t *testing.T) {
	app := testApp(t)
	if code := getChat(app, "/api/v1/chat/calls/ice", "").Code; code == http.StatusOK {
		t.Fatal("ice servers without sign-in")
	}
	ada := registerChat(t, app, `{"email":"ice1@example.com","username":"ice1"}`)
	res := getChat(app, "/api/v1/chat/calls/ice", ada.token)
	var body struct {
		IceServers []iceServer `json:"iceServers"`
		TTL        int64       `json:"ttl"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &body); err != nil || res.Code != http.StatusOK || len(body.IceServers) == 0 || body.TTL <= 0 {
		t.Fatalf("ice %d %s", res.Code, res.Body.String())
	}
}
