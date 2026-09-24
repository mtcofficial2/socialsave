package storage

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
)

func TestS3PutVerifiesAndPresignsWithoutSecret(t *testing.T) {
	var sawPut, sawHead bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.Header.Get("Authorization"), "secret-value") {
			t.Fatal("secret leaked into Authorization as raw text")
		}
		switch r.Method {
		case http.MethodPut:
			sawPut = true
			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		case http.MethodHead:
			sawHead = true
			w.WriteHeader(http.StatusOK)
		default:
			http.Error(w, "unexpected", http.StatusMethodNotAllowed)
		}
	}))
	defer server.Close()

	file, err := os.CreateTemp(t.TempDir(), "video-*.mp4")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = file.WriteString("video-bytes")
	_ = file.Close()

	client := NewS3(config.Config{
		S3Endpoint:        server.URL,
		S3Region:          "auto",
		S3Bucket:          "socialsave",
		S3AccessKeyID:     "access-key",
		S3SecretAccessKey: "secret-value",
		S3URLTTL:          time.Hour,
	})
	client.now = func() time.Time { return time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC) }
	got, err := client.Put(context.Background(), file.Name(), "clip.mp4", "video/mp4")
	if err != nil {
		t.Fatal(err)
	}
	if !sawPut || !sawHead {
		t.Fatalf("put=%v head=%v", sawPut, sawHead)
	}
	if strings.Contains(got, "secret-value") || !strings.Contains(got, "X-Amz-Signature") {
		t.Fatalf("url = %s", got)
	}
}

func TestNewFromConfigUsesHTTPWhenS3IsUnset(t *testing.T) {
	store := NewFromConfig(config.Config{ObjectStorageURL: "https://example.com/bucket"})
	if !store.Enabled() {
		t.Fatal("http store should stay available")
	}
	if _, ok := store.(*S3); ok {
		t.Fatal("empty S3 credentials should not select S3")
	}
}
