package providers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/security"
)

// Fetcher performs outbound HTTP with manual redirects and a public-address dialer.
type Fetcher struct {
	Client       *http.Client
	Validator    *security.Validator
	Timeout      time.Duration
	MaxRedirects int
}

// NewFetcher builds a client that refuses private and link-local addresses.
func NewFetcher(validator *security.Validator, timeout time.Duration, maxRedirects int) *Fetcher {
	if validator == nil {
		validator = security.NewValidator()
	}
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	if maxRedirects < 0 {
		maxRedirects = 3
	}
	transport := &http.Transport{
		Proxy:               nil,
		DialContext:         validator.DialContext,
		ForceAttemptHTTP2:   true,
		MaxIdleConns:        10,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	return &Fetcher{
		Validator:    validator,
		Timeout:      timeout,
		MaxRedirects: maxRedirects,
		Client: &http.Client{
			Timeout:   timeout,
			Transport: transport,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// Do issues one request and follows a limited number of redirects, re-checking each hop.
func (f *Fetcher) Do(ctx context.Context, method, rawURL string, headers map[string]string) (*http.Response, error) {
	current := rawURL
	for hop := 0; hop <= f.MaxRedirects; hop++ {
		if _, err := f.Validator.Validate(ctx, current); err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, method, current, nil)
		if err != nil {
			return nil, errs.InvalidURL("That URL is not valid.")
		}
		req.Header.Set("User-Agent", browserUA)
		req.Header.Set("Accept-Language", "en-US,en;q=0.9")
		for key, value := range headers {
			req.Header.Set(key, value)
		}
		resp, err := f.Client.Do(req)
		if err != nil {
			if errors.Is(err, security.ErrBlockedAddress) {
				return nil, errs.InvalidURL("Private or local network addresses are not allowed.")
			}
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				return nil, errs.PlatformUnavailable("")
			}
			return nil, errs.PlatformUnavailable("")
		}
		if resp.StatusCode < 300 || resp.StatusCode >= 400 {
			return resp, nil
		}
		location := resp.Header.Get("Location")
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if location == "" {
			return nil, errs.PrivateVideo("")
		}
		next, err := resolveRef(current, location)
		if err != nil {
			return nil, errs.InvalidURL("That URL is not valid.")
		}
		current = next
		if method == http.MethodHead {
			method = http.MethodGet
		}
	}
	return nil, errs.PrivateVideo("")
}

// HeadOrRange prefers HEAD and falls back to a one-byte GET when HEAD is refused.
func (f *Fetcher) HeadOrRange(ctx context.Context, rawURL string) (*http.Response, error) {
	resp, err := f.Do(ctx, http.MethodHead, rawURL, nil)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusForbidden || resp.StatusCode == http.StatusMethodNotAllowed || resp.StatusCode == http.StatusNotImplemented {
		resp.Body.Close()
		return f.Do(ctx, http.MethodGet, rawURL, map[string]string{"Range": "bytes=0-0"})
	}
	return resp, nil
}

// GetJSON fetches a JSON object from a validated URL.
func (f *Fetcher) GetJSON(ctx context.Context, rawURL string, headers map[string]string, dest any) error {
	resp, err := f.Do(ctx, http.MethodGet, rawURL, headers)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return errs.PrivateVideo("")
	}
	if resp.StatusCode == http.StatusNotFound {
		return errs.RemovedVideo()
	}
	if resp.StatusCode >= 500 {
		return errs.PlatformUnavailable("")
	}
	if resp.StatusCode >= 400 {
		return errs.PrivateVideo("")
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return errs.PlatformUnavailable("")
	}
	if err := json.Unmarshal(body, dest); err != nil {
		return errs.PlatformUnavailable("")
	}
	return nil
}

func resolveRef(base, ref string) (string, error) {
	parent, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	next, err := url.Parse(ref)
	if err != nil {
		return "", err
	}
	return parent.ResolveReference(next).String(), nil
}

func contentLength(header http.Header) *int64 {
	if cr := header.Get("Content-Range"); strings.Contains(cr, "/") {
		total := cr[strings.LastIndex(cr, "/")+1:]
		if n, err := strconv.ParseInt(strings.TrimSpace(total), 10, 64); err == nil && n >= 0 {
			return &n
		}
	}
	if cl := header.Get("Content-Length"); cl != "" {
		if n, err := strconv.ParseInt(strings.TrimSpace(cl), 10, 64); err == nil && n >= 0 {
			return &n
		}
	}
	return nil
}
