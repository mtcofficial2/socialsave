package server

import (
	"compress/gzip"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// Package tests save at once so they can read storage right after a change.
func init() { chatBlobDelay = 0 }

type countingBlob struct {
	mu   sync.Mutex
	puts int
	last []byte
}

func (b *countingBlob) PutBytes(_ context.Context, _ string, body []byte) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.puts++
	b.last = append([]byte(nil), body...)
	return nil
}

func (b *countingBlob) GetBytes(_ context.Context, _ string) ([]byte, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.last, nil
}

func (b *countingBlob) count() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.puts
}

func TestChatStoreUploadsAreBatchedAndFlushed(t *testing.T) {
	old := chatBlobDelay
	chatBlobDelay = 150 * time.Millisecond
	defer func() { chatBlobDelay = old }()
	blob := &countingBlob{}
	room := &chatRoom{blob: blob, file: t.TempDir() + "/chat.json", seenSaved: map[string]int64{}}
	room.data.Users = []chatUser{{ID: "u1", Username: "ann"}}
	for i := 0; i < 20; i++ {
		room.mu.Lock()
		room.data.Users[0].LastSeen = int64(i + 1)
		room.mu.Unlock()
		room.persist(context.Background())
	}
	if got := blob.count(); got != 0 {
		t.Fatalf("uploaded %d times before the batch window ended", got)
	}
	time.Sleep(400 * time.Millisecond)
	if got := blob.count(); got != 1 {
		t.Fatalf("want one batched upload, got %d", got)
	}
	// Nothing changed, so a new save sends nothing.
	room.persist(context.Background())
	time.Sleep(400 * time.Millisecond)
	if got := blob.count(); got != 1 {
		t.Fatalf("an unchanged store was uploaded again (%d)", got)
	}
	// A change waiting in the batch is sent when the server stops.
	room.mu.Lock()
	room.data.Users[0].LastSeen = 99
	room.mu.Unlock()
	room.persist(context.Background())
	room.flushStore(context.Background())
	if got := blob.count(); got != 2 {
		t.Fatalf("flush on stop did not upload the waiting change (%d)", got)
	}
	if decodeChat(blob.last).Users[0].LastSeen != 99 {
		t.Fatal("flushed copy is not the newest")
	}
}

func TestJSONResponsesAreGzippedWhenAsked(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/api/v1/platforms", nil)
	request.Header.Set("Accept-Encoding", "gzip")
	response := httptest.NewRecorder()
	testApp(t).Router().ServeHTTP(response, request)
	if response.Header().Get("Content-Encoding") != "gzip" {
		t.Fatalf("want gzip, got %q", response.Header().Get("Content-Encoding"))
	}
	reader, err := gzip.NewReader(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(reader)
	if !strings.Contains(string(body), `"platforms"`) {
		t.Fatalf("unexpected body %s", body)
	}
	plain := httptest.NewRecorder()
	testApp(t).Router().ServeHTTP(plain, httptest.NewRequest(http.MethodGet, "/api/v1/platforms", nil))
	if plain.Header().Get("Content-Encoding") != "" || !strings.Contains(plain.Body.String(), `"platforms"`) {
		t.Fatal("clients that do not ask for gzip must get plain JSON")
	}
}
