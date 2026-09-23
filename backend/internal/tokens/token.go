// Package tokens issues and verifies HMAC download tickets.
//
// A token is base64url(json) + "." + base64url(hmac-sha256(secret, rawJSON)),
// without padding. Remote tickets carry url, mime, max, name, headers, size,
// and exp. Local jobs carry job, mime, name, and exp.
package tokens

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

// Claims is a verified download ticket.
type Claims struct {
	URL     string
	MIME    string
	Max     int64
	Name    string
	Headers map[string]string
	Size    *int64
	Exp     int64
	Job     string
	Proxy   bool
	Stream  string
}

// Service signs tickets with the API secret.
type Service struct {
	secret []byte
	ttl    time.Duration
	now    func() time.Time
}

// New builds a signer. ttl is how long issued tickets remain valid.
func New(secret string, ttl time.Duration) *Service {
	if ttl == 0 {
		ttl = time.Hour
	}
	return &Service{
		secret: []byte(secret),
		ttl:    ttl,
		now:    time.Now,
	}
}

// WithClock replaces the clock. Tests use it to check expiry.
func (s *Service) WithClock(now func() time.Time) *Service {
	if now != nil {
		s.now = now
	}
	return s
}

type remoteBody struct {
	URL     string            `json:"url"`
	MIME    string            `json:"mime"`
	Max     int64             `json:"max"`
	Name    string            `json:"name"`
	Headers map[string]string `json:"headers"`
	Size    *int64            `json:"size"`
	Proxy   bool              `json:"proxy,omitempty"`
	Exp     int64             `json:"exp"`
}

type jobBody struct {
	Job  string `json:"job"`
	MIME string `json:"mime"`
	Name string `json:"name"`
	Exp  int64  `json:"exp"`
}

// IssueRemote signs a ticket that redirects to an upstream media URL.
func (s *Service) IssueRemote(url, mime, name string, maxBytes int64, headers map[string]string, size *int64, proxy bool) (string, error) {
	if headers == nil {
		headers = map[string]string{}
	}
	body := remoteBody{
		URL:     url,
		MIME:    mime,
		Max:     maxBytes,
		Name:    name,
		Headers: headers,
		Size:    size,
		Proxy:   proxy,
		Exp:     s.now().UTC().Unix() + int64(s.ttl/time.Second),
	}
	return s.sign(body)
}

type playBody struct {
	Stream string `json:"stream"`
	MIME   string `json:"mime"`
	Name   string `json:"name"`
	Exp    int64  `json:"exp"`
}

// IssuePlay signs a ticket for a live in-app playback stream.
func (s *Service) IssuePlay(id, mime, name string) (string, error) {
	return s.sign(playBody{
		Stream: id,
		MIME:   mime,
		Name:   name,
		Exp:    s.now().UTC().Unix() + int64(s.ttl/time.Second),
	})
}

// IssueJob signs a ticket that serves a prepared temp file once.
func (s *Service) IssueJob(jobID, mime, name string) (string, error) {
	body := jobBody{
		Job:  jobID,
		MIME: mime,
		Name: name,
		Exp:  s.now().UTC().Unix() + int64(s.ttl/time.Second),
	}
	return s.sign(body)
}

// Parse verifies the signature and expiry. Invalid tickets are unauthorized.
func (s *Service) Parse(token string) (Claims, error) {
	raw, signature, ok := strings.Cut(token, ".")
	if !ok || raw == "" || signature == "" || strings.Contains(signature, ".") {
		return Claims{}, errs.Unauthorized()
	}
	expected := s.mac(raw)
	got, err := decode(signature)
	if err != nil || !hmac.Equal(got, expected) {
		return Claims{}, errs.Unauthorized()
	}
	payload, err := decode(raw)
	if err != nil {
		return Claims{}, errs.Unauthorized()
	}
	var generic map[string]json.RawMessage
	if err := json.Unmarshal(payload, &generic); err != nil {
		return Claims{}, errs.Unauthorized()
	}
	claims := Claims{Headers: map[string]string{}}
	_ = json.Unmarshal(generic["url"], &claims.URL)
	_ = json.Unmarshal(generic["mime"], &claims.MIME)
	_ = json.Unmarshal(generic["max"], &claims.Max)
	_ = json.Unmarshal(generic["name"], &claims.Name)
	_ = json.Unmarshal(generic["headers"], &claims.Headers)
	_ = json.Unmarshal(generic["size"], &claims.Size)
	_ = json.Unmarshal(generic["exp"], &claims.Exp)
	_ = json.Unmarshal(generic["job"], &claims.Job)
	_ = json.Unmarshal(generic["proxy"], &claims.Proxy)
	_ = json.Unmarshal(generic["stream"], &claims.Stream)
	if claims.Headers == nil {
		claims.Headers = map[string]string{}
	}
	if claims.Exp < s.now().UTC().Unix() {
		return Claims{}, errs.Unauthorized()
	}
	return claims, nil
}

func (s *Service) sign(body any) (string, error) {
	encoded, err := marshalCompact(body)
	if err != nil {
		return "", err
	}
	raw := base64.RawURLEncoding.EncodeToString(encoded)
	sig := base64.RawURLEncoding.EncodeToString(s.mac(raw))
	return raw + "." + sig, nil
}

func (s *Service) mac(raw string) []byte {
	mac := hmac.New(sha256.New, s.secret)
	_, _ = mac.Write([]byte(raw))
	return mac.Sum(nil)
}

func marshalCompact(value any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

func decode(value string) ([]byte, error) {
	if value == "" {
		return nil, errors.New("empty")
	}
	if decoded, err := base64.RawURLEncoding.DecodeString(value); err == nil {
		return decoded, nil
	}
	return base64.URLEncoding.DecodeString(value)
}
