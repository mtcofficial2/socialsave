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

func TestS3PublicURLIsCollisionSafeAndKeepsMIME(t *testing.T) {
	var keys []string
	var mime string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPut:
			keys = append(keys, r.URL.Path)
			mime = r.Header.Get("Content-Type")
			_, _ = io.Copy(io.Discard, r.Body)
			w.WriteHeader(http.StatusOK)
		case http.MethodHead:
			w.WriteHeader(http.StatusOK)
		default:
			http.Error(w, "unexpected", http.StatusMethodNotAllowed)
		}
	}))
	defer server.Close()

	file := writeTempVideo(t, "video-bytes")
	client := NewS3(config.Config{
		S3Endpoint:        server.URL,
		S3Region:          "auto",
		S3Bucket:          "socialsave",
		S3AccessKeyID:     "access-key",
		S3SecretAccessKey: "secret-value",
		S3PublicBaseURL:   "https://media.example.com",
		S3URLTTL:          time.Hour,
	})
	first, err := client.Put(context.Background(), file, "clip.mp4", "video/mp4")
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.Put(context.Background(), file, "clip.mp4", "video/webm")
	if err != nil {
		t.Fatal(err)
	}
	if mime != "video/webm" {
		t.Fatalf("content-type = %s", mime)
	}
	for _, got := range []string{first, second} {
		if !strings.HasPrefix(got, "https://media.example.com/videos/") || strings.Contains(got, "X-Amz-") || strings.Contains(got, "secret-value") {
			t.Fatalf("public url = %s", got)
		}
	}
	if first == second || len(keys) != 2 || keys[0] == keys[1] {
		t.Fatalf("keys = %#v urls %s %s", keys, first, second)
	}
	for _, key := range keys {
		if !strings.Contains(key, "/socialsave/videos/") || !strings.Contains(key, "/clip.mp4") {
			t.Fatalf("key = %s", key)
		}
	}
}

func TestS3UploadFailureDoesNotReturnURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer server.Close()
	client := NewS3(config.Config{
		S3Endpoint:        server.URL,
		S3Region:          "auto",
		S3Bucket:          "socialsave",
		S3AccessKeyID:     "access-key",
		S3SecretAccessKey: "secret-value",
		S3PublicBaseURL:   "https://media.example.com",
	})
	_, err := client.Put(context.Background(), writeTempVideo(t, "video-bytes"), "clip.mp4", "video/mp4")
	if err == nil || strings.Contains(err.Error(), "secret-value") {
		t.Fatalf("err = %v", err)
	}
}

func TestS3VerifyFailureDoesNotReturnURL(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	client := NewS3(config.Config{
		S3Endpoint:        server.URL,
		S3Region:          "auto",
		S3Bucket:          "socialsave",
		S3AccessKeyID:     "access-key",
		S3SecretAccessKey: "secret-value",
	})
	_, err := client.Put(context.Background(), writeTempVideo(t, "video-bytes"), "clip.mp4", "video/mp4")
	if err == nil || !strings.Contains(err.Error(), "verify") {
		t.Fatalf("err = %v", err)
	}
}

func writeTempVideo(t *testing.T, body string) string {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "video-*.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(body); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return file.Name()
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
