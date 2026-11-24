package server

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

// flakyBlob fails the first few uploads, like a storage outage.
type flakyBlob struct {
	mu    sync.Mutex
	fails int
	puts  int
	last  []byte
}

func (b *flakyBlob) PutBytes(_ context.Context, _ string, body []byte) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.fails > 0 {
		b.fails--
		return errors.New("storage down")
	}
	b.puts++
	b.last = append([]byte(nil), body...)
	return nil
}

func (b *flakyBlob) GetBytes(_ context.Context, _ string) ([]byte, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.last, nil
}

func (b *flakyBlob) saved() (int, []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.puts, b.last
}

func TestChatStoreRetriesAFailedUploadWithBackoff(t *testing.T) {
	oldBase, oldMax := chatBlobRetryBase, chatBlobRetryMax
	chatBlobRetryBase, chatBlobRetryMax = 40*time.Millisecond, 200*time.Millisecond
	defer func() { chatBlobRetryBase, chatBlobRetryMax = oldBase, oldMax }()
	blob := &flakyBlob{fails: 2}
	room := &chatRoom{blob: blob, file: t.TempDir() + "/chat.json", seenSaved: map[string]int64{}}
	room.data.Users = []chatUser{{ID: "u1", Username: "ann"}}
	room.persist(context.Background()) // fails, retry planned
	if n, _ := blob.saved(); n != 0 {
		t.Fatal("upload should have failed")
	}
	room.blobMu.Lock()
	dirty := room.blobDirty
	room.blobMu.Unlock()
	if !dirty {
		t.Fatal("a failed upload was not marked for retry")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if n, _ := blob.saved(); n == 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	n, body := blob.saved()
	if n != 1 || decodeChat(body).Users[0].Username != "ann" {
		t.Fatalf("the change was not saved after storage came back (%d)", n)
	}
	room.blobMu.Lock()
	dirty, retry := room.blobDirty, room.blobRetry
	room.blobMu.Unlock()
	if dirty || retry != 0 {
		t.Fatal("retry state was not cleared after a good upload")
	}
}

func TestChatStoreFlushSendsAFailedUploadOnShutdown(t *testing.T) {
	oldBase := chatBlobRetryBase
	chatBlobRetryBase = time.Hour
	defer func() { chatBlobRetryBase = oldBase }()
	blob := &flakyBlob{fails: 1}
	room := &chatRoom{blob: blob, file: t.TempDir() + "/chat.json", seenSaved: map[string]int64{}}
	room.data.Users = []chatUser{{ID: "u1", Username: "ann"}}
	room.persist(context.Background())
	room.flushStore(context.Background())
	if n, _ := blob.saved(); n != 1 {
		t.Fatalf("shutdown did not send the change a failed upload left behind (%d)", n)
	}
}

func TestClientIPPrefersCloudflareHeader(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "10.0.0.1:1234"
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 9.9.9.9")
	r.Header.Set("CF-Connecting-IP", "41.210.1.2")
	if got := clientIP(r); got != "41.210.1.2" {
		t.Fatalf("got %s", got)
	}
	r.Header.Set("CF-Connecting-IP", "not-an-ip")
	if got := clientIP(r); got != "1.2.3.4" {
		t.Fatalf("fallback got %s", got)
	}
}

func TestChatWrongPasswordsLockOneAccount(t *testing.T) {
	app := testApp(t)
	registerChat(t, app, `{"phone":"256711000001","username":"ann","password":"rightpass"}`)
	for i := 0; i < chatLoginFailMax; i++ {
		r := httptest.NewRequest(http.MethodPost, "/api/v1/chat/register", strings.NewReader(`{"phone":"256711000001","username":"ann","password":"wrong`+string(rune('a'+i))+`x"}`))
		// A different address each time: the account limit still applies.
		r.Header.Set("CF-Connecting-IP", "41.0.0."+string(rune('1'+i%9)))
		w := httptest.NewRecorder()
		app.Router().ServeHTTP(w, r)
		if w.Code != http.StatusBadRequest || !strings.Contains(w.Body.String(), "does not match") {
			t.Fatalf("wrong %d %d %s", i, w.Code, w.Body.String())
		}
		app.chat.mu.Lock()
		app.chat.joins = map[string][]time.Time{} // keep the per-address limit out of this test
		app.chat.mu.Unlock()
	}
	locked := postChat(app, "/api/v1/chat/register", "", `{"phone":"256711000001","username":"ann","password":"rightpass"}`)
	if locked.Code == http.StatusOK || !strings.Contains(locked.Body.String(), "Too many wrong passwords") {
		t.Fatalf("not locked %d %s", locked.Code, locked.Body.String())
	}
	// Other accounts are not affected.
	registerChat(t, app, `{"phone":"256711000002","username":"bob"}`)
}

func TestChatGroupCodeGuessingIsSlowed(t *testing.T) {
	app := testApp(t)
	guesser := registerChat(t, app, `{"phone":"256711000003","username":"gus"}`)
	limited := false
	for i := 0; i < 10; i++ {
		got := postChat(app, "/api/v1/chat/groups/join", guesser.token, `{"code":"ZZZZZ`+string(rune('A'+i))+`"}`)
		if got.Code == http.StatusTooManyRequests {
			limited = true
			if i < 6 {
				t.Fatalf("limited too early at %d", i)
			}
			break
		}
	}
	if !limited {
		t.Fatal("ten quick code guesses were not slowed")
	}
}

func TestScheduledSendRetriesOnlyPassingFailures(t *testing.T) {
	now := time.Now().UnixMilli()
	item := chatSchedule{SendAt: now - 1000}
	if !scheduleRetryable(errs.RateLimited(), item, now) {
		t.Fatal("a rate limit should be retried")
	}
	if scheduleRetryable(chatRejected("That chat was not found."), item, now) {
		t.Fatal("a refused send should not be retried")
	}
	old := chatSchedule{SendAt: now - chatScheduleGiveUp.Milliseconds() - 1}
	if scheduleRetryable(errs.RateLimited(), old, now) {
		t.Fatal("a day-late message should be dropped")
	}
}
