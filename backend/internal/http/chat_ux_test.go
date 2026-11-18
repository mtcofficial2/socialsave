package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestChatPinsMarksSearchFilesAndReaders(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700111001","username":"ada"}`)
	ben := registerChat(t, app, `{"email":"ben@example.com","username":"ben"}`)
	cara := registerChat(t, app, `{"phone":"256700111003","username":"cara"}`)

	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	if opened.Code != http.StatusOK {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatal(err)
	}
	sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"The harbor code is northwind."}`)
	if sent.Code != http.StatusOK {
		t.Fatalf("send %d %s", sent.Code, sent.Body.String())
	}

	pinned := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/list-pin", ada.token, `{}`)
	if pinned.Code != http.StatusOK || !strings.Contains(pinned.Body.String(), `"pinned":true`) {
		t.Fatalf("pin %d %s", pinned.Code, pinned.Body.String())
	}
	strangerPin := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/list-pin", cara.token, `{}`)
	if strangerPin.Code == http.StatusOK {
		t.Fatalf("stranger pin %s", strangerPin.Body.String())
	}
	adaInbox := getChat(app, "/api/v1/chat/threads", ada.token)
	if !strings.Contains(adaInbox.Body.String(), `"pinned":true`) {
		t.Fatalf("ada inbox %s", adaInbox.Body.String())
	}
	benInbox := getChat(app, "/api/v1/chat/threads", ben.token)
	if strings.Contains(benInbox.Body.String(), `"pinned":true`) {
		t.Fatalf("ben should not inherit ada's pin %s", benInbox.Body.String())
	}
	again := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/list-pin", ada.token, `{}`)
	if again.Code != http.StatusOK || !strings.Contains(again.Body.String(), `"pinned":false`) {
		t.Fatalf("unpin %d %s", again.Code, again.Body.String())
	}

	if postChat(app, "/api/v1/chat/threads/"+thread.ID+"/read", ben.token, `{"id":1}`).Code != http.StatusOK {
		t.Fatal("read")
	}
	quiet := getChat(app, "/api/v1/chat/threads", ben.token)
	if strings.Contains(quiet.Body.String(), `"unread"`) || strings.Contains(quiet.Body.String(), `"marked":true`) {
		t.Fatalf("read inbox %s", quiet.Body.String())
	}
	marked := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/unread", ben.token, `{}`)
	if marked.Code != http.StatusOK {
		t.Fatalf("mark %d %s", marked.Code, marked.Body.String())
	}
	badge := getChat(app, "/api/v1/chat/threads", ben.token)
	if !strings.Contains(badge.Body.String(), `"marked":true`) || !strings.Contains(badge.Body.String(), `"unread":1`) {
		t.Fatalf("badge %s", badge.Body.String())
	}
	stillRead := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ada.token)
	if !strings.Contains(stillRead.Body.String(), `"status":"read"`) {
		t.Fatalf("cursor moved %s", stillRead.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+thread.ID+"/read", ben.token, `{"id":1}`).Code != http.StatusOK {
		t.Fatal("clear mark")
	}
	cleared := getChat(app, "/api/v1/chat/threads", ben.token)
	if strings.Contains(cleared.Body.String(), `"marked":true`) || strings.Contains(cleared.Body.String(), `"unread"`) {
		t.Fatalf("cleared %s", cleared.Body.String())
	}

	found := getChat(app, "/api/v1/chat/search?q=northwind", ada.token)
	if found.Code != http.StatusOK || !strings.Contains(found.Body.String(), "northwind") || !strings.Contains(found.Body.String(), thread.ID) {
		t.Fatalf("search %d %s", found.Code, found.Body.String())
	}
	hidden := getChat(app, "/api/v1/chat/search?q=northwind", cara.token)
	if hidden.Code != http.StatusOK || strings.Contains(hidden.Body.String(), "northwind") || strings.Contains(hidden.Body.String(), thread.ID) {
		t.Fatalf("hidden search %d %s", hidden.Code, hidden.Body.String())
	}
	short := getChat(app, "/api/v1/chat/search?q=n", ada.token)
	if short.Code == http.StatusOK {
		t.Fatalf("short search %s", short.Body.String())
	}

	file := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/file", ada.token, []byte("%PDF-1.4 notes"), map[string]string{
		"X-Chat-File-Name": "notes.pdf",
		"X-Chat-Caption":   "Harbor notes",
	})
	if file.Code != http.StatusOK || strings.Contains(file.Body.String(), "video") {
		t.Fatalf("file %d %s", file.Code, file.Body.String())
	}
	var stored struct {
		Message struct {
			File     string `json:"file"`
			FileName string `json:"fileName"`
			Text     string `json:"text"`
			Clip     bool   `json:"clip"`
		} `json:"message"`
	}
	if err := json.Unmarshal(file.Body.Bytes(), &stored); err != nil {
		t.Fatal(err)
	}
	if stored.Message.File == "" || stored.Message.FileName != "notes.pdf" || stored.Message.Text != "Harbor notes" || stored.Message.Clip {
		t.Fatalf("stored %#v", stored.Message)
	}
	got := getChat(app, "/api/v1/chat/files/"+stored.Message.File, ben.token)
	if got.Code != http.StatusOK || !strings.Contains(got.Body.String(), "%PDF-1.4") {
		t.Fatalf("download %d %s", got.Code, got.Body.String())
	}
	denied := getChat(app, "/api/v1/chat/files/"+stored.Message.File, cara.token)
	if denied.Code == http.StatusOK {
		t.Fatalf("stranger download %s", denied.Body.String())
	}
	bad := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/file", ada.token, []byte("nope"), map[string]string{
		"X-Chat-File-Name": "run.exe",
	})
	if bad.Code == http.StatusOK {
		t.Fatalf("exe %s", bad.Body.String())
	}
	clip := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/file", ada.token, []byte("clip-bytes"), map[string]string{
		"X-Chat-File-Name": "moment.mp4",
		"X-Chat-Clip":      "1",
	})
	if clip.Code != http.StatusOK || !strings.Contains(clip.Body.String(), `"clip":true`) || !strings.Contains(clip.Body.String(), "Short clip") {
		t.Fatalf("clip %d %s", clip.Code, clip.Body.String())
	}
	if strings.Contains(strings.ToLower(clip.Body.String()), "video") && !strings.Contains(clip.Body.String(), "video/mp4") {
		t.Fatalf("clip label %s", clip.Body.String())
	}

	made := postChat(app, "/api/v1/chat/groups", ada.token, `{"name":"Harbor"}`)
	var group struct {
		ID   string `json:"id"`
		Code string `json:"code"`
	}
	if made.Code != http.StatusOK || json.Unmarshal(made.Body.Bytes(), &group) != nil || group.ID == "" {
		t.Fatalf("group %d %s", made.Code, made.Body.String())
	}
	if postChat(app, "/api/v1/chat/groups/join", ben.token, `{"code":"`+group.Code+`"}`).Code != http.StatusOK {
		t.Fatal("join")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/members", ada.token, `{"username":"cara"}`).Code != http.StatusOK {
		t.Fatal("add")
	}
	posted := postChat(app, "/api/v1/chat/threads/"+group.ID, ada.token, `{"text":"Who is here"}`)
	if posted.Code != http.StatusOK {
		t.Fatalf("group post %d %s", posted.Code, posted.Body.String())
	}
	var created struct {
		Message struct {
			ID int64 `json:"id"`
		} `json:"message"`
	}
	if err := json.Unmarshal(posted.Body.Bytes(), &created); err != nil || created.Message.ID < 1 {
		t.Fatalf("id %s", posted.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+group.ID+"/read", ben.token, `{"id":1}`).Code != http.StatusOK {
		t.Fatal("ben read")
	}
	info := getChat(app, "/api/v1/chat/threads/"+group.ID+"/info?id=1", ada.token)
	if info.Code != http.StatusOK || !strings.Contains(info.Body.String(), `"name":"ben"`) || strings.Contains(info.Body.String(), `"name":"cara"`) {
		t.Fatalf("readers %d %s", info.Code, info.Body.String())
	}
	if strings.Contains(info.Body.String(), "Who is here") {
		t.Fatalf("info leaked the message %s", info.Body.String())
	}
}

func TestChatMediaOpensFromObjectStorage(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	store := &redirectBlob{}
	app.chat.blob = store
	ada := registerChat(t, app, `{"phone":"256700222001","username":"ada"}`)
	ben := registerChat(t, app, `{"email":"ben2@example.com","username":"ben"}`)
	cara := registerChat(t, app, `{"phone":"256700222003","username":"cara"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if opened.Code != http.StatusOK || json.Unmarshal(opened.Body.Bytes(), &thread) != nil || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x01}
	photo := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/photo", ada.token, png, "", "")
	var picture struct {
		Message struct {
			Photo string `json:"photo"`
		} `json:"message"`
	}
	if photo.Code != http.StatusOK || json.Unmarshal(photo.Body.Bytes(), &picture) != nil || picture.Message.Photo == "" {
		t.Fatalf("photo %d %s", photo.Code, photo.Body.String())
	}
	got := getChat(app, "/api/v1/chat/images/"+picture.Message.Photo, ben.token)
	wantObjectRedirect(t, got, "chat/images/"+picture.Message.Photo, png)
	if hidden := getChat(app, "/api/v1/chat/images/"+picture.Message.Photo, cara.token); hidden.Code != http.StatusNotFound || hidden.Header().Get("Location") != "" {
		t.Fatalf("stranger image %d %s", hidden.Code, hidden.Header().Get("Location"))
	}

	voice := make([]byte, 12)
	copy(voice[4:], "ftyp")
	sentVoice := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/voice", ada.token, voice, "X-Voice-Ms", "1000")
	var note struct {
		Message struct {
			Voice string `json:"voice"`
		} `json:"message"`
	}
	if sentVoice.Code != http.StatusOK || json.Unmarshal(sentVoice.Body.Bytes(), &note) != nil || note.Message.Voice == "" {
		t.Fatalf("voice %d %s", sentVoice.Code, sentVoice.Body.String())
	}
	wantObjectRedirect(t, getChat(app, "/api/v1/chat/voice/"+note.Message.Voice, ben.token), "chat/voices/"+note.Message.Voice, voice)

	song := []byte("ID3tiny-song")
	sentSong := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/song", ada.token, song, map[string]string{
		"X-Song-Name": "Harbor",
		"X-Song-Ms":   "1000",
	})
	var track struct {
		Message struct {
			Song string `json:"song"`
		} `json:"message"`
	}
	if sentSong.Code != http.StatusOK || json.Unmarshal(sentSong.Body.Bytes(), &track) != nil || track.Message.Song == "" {
		t.Fatalf("song %d %s", sentSong.Code, sentSong.Body.String())
	}
	wantObjectRedirect(t, getChat(app, "/api/v1/chat/songs/"+track.Message.Song, ben.token), "chat/songs/"+track.Message.Song, song)

	file := []byte("%PDF-1.4 notes")
	sentFile := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/file", ada.token, file, map[string]string{
		"X-Chat-File-Name": "notes.pdf",
	})
	var stored struct {
		Message struct {
			File string `json:"file"`
		} `json:"message"`
	}
	if sentFile.Code != http.StatusOK || json.Unmarshal(sentFile.Body.Bytes(), &stored) != nil || stored.Message.File == "" {
		t.Fatalf("file %d %s", sentFile.Code, sentFile.Body.String())
	}
	wantObjectRedirect(t, getChat(app, "/api/v1/chat/files/"+stored.Message.File, ben.token), "chat/files/"+stored.Message.File, file)

	status := postChatRaw(app, "/api/v1/chat/status/image", ada.token, png, "", "")
	var update struct {
		Status struct {
			ID string `json:"id"`
		} `json:"status"`
	}
	if status.Code != http.StatusOK || json.Unmarshal(status.Body.Bytes(), &update) != nil || update.Status.ID == "" {
		t.Fatalf("status %d %s", status.Code, status.Body.String())
	}
	wantObjectRedirect(t, getChat(app, "/api/v1/chat/status/"+update.Status.ID+"/image", ben.token), "chat/status/"+update.Status.ID, png)

	if postChatRaw(app, "/api/v1/chat/photo", ada.token, png, "", "").Code != http.StatusOK {
		t.Fatal("avatar")
	}
	wantObjectRedirect(t, getChat(app, "/api/v1/chat/photo?username=ada", ben.token), "chat/avatars/", png)
	for _, key := range store.readKeys() {
		if strings.HasPrefix(key, "chat/images/") || strings.HasPrefix(key, "chat/voices/") || strings.HasPrefix(key, "chat/songs/") || strings.HasPrefix(key, "chat/files/") || strings.HasPrefix(key, "chat/status/") || strings.HasPrefix(key, "chat/avatars/") {
			t.Fatalf("the API read %s back from object storage", key)
		}
	}
}

func wantObjectRedirect(t *testing.T, response *httptest.ResponseRecorder, keyPart string, secret []byte) {
	t.Helper()
	if response.Code != http.StatusTemporaryRedirect {
		t.Fatalf("redirect %d %s", response.Code, response.Body.String())
	}
	location := response.Header().Get("Location")
	if !strings.HasPrefix(location, "https://") || !strings.Contains(location, keyPart) || strings.Contains(location, "onrender.com") {
		t.Fatalf("location %s", location)
	}
	if bytes.Contains(response.Body.Bytes(), secret) {
		t.Fatal("file bytes were sent by the API")
	}
}

type redirectBlob struct {
	mu      sync.Mutex
	objects map[string][]byte
	reads   []string
}

func (b *redirectBlob) readKeys() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]string(nil), b.reads...)
}

func (b *redirectBlob) PutBytes(_ context.Context, key string, body []byte) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.objects == nil {
		b.objects = map[string][]byte{}
	}
	b.objects[key] = append([]byte(nil), body...)
	return nil
}

func (b *redirectBlob) GetBytes(_ context.Context, key string) ([]byte, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.reads = append(b.reads, key)
	body, ok := b.objects[key]
	if !ok {
		return nil, os.ErrNotExist
	}
	return append([]byte(nil), body...), nil
}

func (b *redirectBlob) PublicGet(key string) (string, error) {
	return "https://socialsave.r2.cloudflarestorage.com/" + key, nil
}
