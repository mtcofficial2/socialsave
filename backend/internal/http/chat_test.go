package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestChatRegisterPhoneOrEmailAndMessage(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")

	ada := registerChat(t, app, `{"phone":"+256 700 000 111","username":"Ada"}`)
	if ada.user.Username != "ada" || ada.user.Phone != "256700000111" || ada.user.Email != "" || ada.token == "" {
		t.Fatalf("ada %#v token %q", ada.user, ada.token)
	}
	ben := registerChat(t, app, `{"email":"Ben@Example.com","username":"@ben_1"}`)
	if ben.user.Email != "ben@example.com" || ben.user.Username != "ben_1" {
		t.Fatalf("ben %#v", ben.user)
	}

	taken := postChat(app, "/api/v1/chat/register", "", `{"email":"other@example.com","username":"ada"}`)
	if taken.Code != http.StatusBadRequest {
		t.Fatalf("taken %d %s", taken.Code, taken.Body.String())
	}
	neither := postChat(app, "/api/v1/chat/register", "", `{"username":"cara"}`)
	if neither.Code != http.StatusBadRequest {
		t.Fatalf("neither %d %s", neither.Code, neither.Body.String())
	}

	lookup := getChat(app, "/api/v1/chat/lookup?username=ada", ada.token)
	var found struct {
		Found    bool   `json:"found"`
		Username string `json:"username"`
		Phone    string `json:"phone"`
	}
	if err := json.Unmarshal(lookup.Body.Bytes(), &found); err != nil {
		t.Fatal(err)
	}
	if !found.Found || found.Username != "ada" || found.Phone != "" {
		t.Fatalf("lookup %#v body %s", found, lookup.Body.String())
	}

	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben_1"}`)
	if opened.Code != http.StatusOK {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	var thread struct {
		ID       string `json:"id"`
		Username string `json:"username"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil {
		t.Fatal(err)
	}
	sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"Save https://www.youtube.com/watch?v=abcdefghijk."}`)
	if sent.Code != http.StatusOK {
		t.Fatalf("send %d %s", sent.Code, sent.Body.String())
	}
	var created struct {
		Message struct {
			Name  string   `json:"name"`
			Links []string `json:"links"`
		} `json:"message"`
	}
	if err := json.Unmarshal(sent.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Message.Name != "ada" || len(created.Message.Links) != 1 {
		t.Fatalf("message %#v", created.Message)
	}

	seen := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ben.token)
	if seen.Code != http.StatusOK || !bytes.Contains(seen.Body.Bytes(), []byte("abcdefghijk")) {
		t.Fatalf("seen %d %s", seen.Code, seen.Body.String())
	}
	delivered := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ada.token)
	if !bytes.Contains(delivered.Body.Bytes(), []byte(`"status":"delivered"`)) {
		t.Fatalf("delivered %s", delivered.Body.String())
	}
	marked := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/read", ben.token, `{"id":1}`)
	if marked.Code != http.StatusOK {
		t.Fatalf("read %d %s", marked.Code, marked.Body.String())
	}
	read := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ada.token)
	if !bytes.Contains(read.Body.Bytes(), []byte(`"status":"read"`)) {
		t.Fatalf("read ticks %s", read.Body.String())
	}
	stranger := registerChat(t, app, `{"phone":"15550001111","username":"cara"}`)
	hidden := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", stranger.token)
	if hidden.Code != http.StatusBadRequest {
		t.Fatalf("hidden %d %s", hidden.Code, hidden.Body.String())
	}

	inbox := getChat(app, "/api/v1/chat/threads", ben.token)
	if !bytes.Contains(inbox.Body.Bytes(), []byte(`"username":"ada"`)) || !bytes.Contains(inbox.Body.Bytes(), []byte(`"lastFrom":"ada"`)) || bytes.Contains(inbox.Body.Bytes(), []byte(`"unread"`)) {
		t.Fatalf("inbox %s", inbox.Body.String())
	}
	again := postChat(app, "/api/v1/chat/threads", ben.token, `{"username":"ada"}`)
	var same struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(again.Body.Bytes(), &same); err != nil {
		t.Fatal(err)
	}
	if same.ID != thread.ID {
		t.Fatalf("reopen %s want %s", same.ID, thread.ID)
	}
}

func TestChatRegisterDirect(t *testing.T) {
	room := newChatRoom(nil)
	room.file = filepath.Join(t.TempDir(), "missing.json")
	user, token, err := room.register(context.Background(), "1.2.3.4", "", "a@b.co", "sam")
	if err != nil || user.Username != "sam" || token == "" {
		t.Fatalf("%v %#v", err, user)
	}
	got, ok := room.userByToken(context.Background(), token)
	if !ok || got.Email != "a@b.co" || got.TokenHash != "" {
		t.Fatalf("token user %#v ok %v", got, ok)
	}
}

type registeredChat struct {
	token string
	user  struct {
		Username string `json:"username"`
		Phone    string `json:"phone"`
		Email    string `json:"email"`
	}
}

func registerChat(t *testing.T, app *Server, body string) registeredChat {
	t.Helper()
	response := postChat(app, "/api/v1/chat/register", "", body)
	if response.Code != http.StatusOK {
		t.Fatalf("register %d %s", response.Code, response.Body.String())
	}
	var parsed struct {
		Token string `json:"token"`
		User  struct {
			Username string `json:"username"`
			Phone    string `json:"phone"`
			Email    string `json:"email"`
		} `json:"user"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &parsed); err != nil {
		t.Fatal(err)
	}
	return registeredChat{token: parsed.Token, user: parsed.User}
}

func postChat(app *Server, path, token, body string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewBufferString(body))
	if token != "" {
		request.Header.Set("X-Chat-Token", token)
	}
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	return response
}

func TestChatPhotoVoiceAndPresence(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000222","username":"ada"}`)
	ben := registerChat(t, app, `{"email":"ben@example.com","username":"ben"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || opened.Code != http.StatusOK || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}

	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x01}
	posted := postChatRaw(app, "/api/v1/chat/photo", ada.token, png, "", "")
	if posted.Code != http.StatusOK || !bytes.Contains(posted.Body.Bytes(), []byte(`"photoRev"`)) {
		t.Fatalf("photo %d %s", posted.Code, posted.Body.String())
	}
	got := getChat(app, "/api/v1/chat/photo?username=ada", ben.token)
	if got.Code != http.StatusOK || got.Header().Get("Content-Type") != "image/png" || !bytes.Equal(got.Body.Bytes(), png) {
		t.Fatalf("get photo %d %s body %d", got.Code, got.Header().Get("Content-Type"), got.Body.Len())
	}
	reject := postChatRaw(app, "/api/v1/chat/photo", ada.token, []byte("not a photo"), "", "")
	if reject.Code != http.StatusBadRequest {
		t.Fatalf("bad photo %d %s", reject.Code, reject.Body.String())
	}
	missing := getChat(app, "/api/v1/chat/photo?username=nobody", ada.token)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing photo %d %s", missing.Code, missing.Body.String())
	}

	wav := []byte("RIFF\x24\x00\x00\x00WAVEfmt ")
	voice := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/voice", ada.token, wav, "X-Voice-Ms", "1200")
	if voice.Code != http.StatusOK || !bytes.Contains(voice.Body.Bytes(), []byte(`"text":"Voice message"`)) {
		t.Fatalf("voice %d %s", voice.Code, voice.Body.String())
	}
	var created struct {
		Message struct {
			Voice string `json:"voice"`
		} `json:"message"`
	}
	if err := json.Unmarshal(voice.Body.Bytes(), &created); err != nil || created.Message.Voice == "" {
		t.Fatalf("voice id %s", voice.Body.String())
	}
	again := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/voice", ada.token, wav, "X-Voice-Ms", "1500")
	if again.Code != http.StatusOK {
		t.Fatalf("second voice %d %s", again.Code, again.Body.String())
	}
	heard := getChat(app, "/api/v1/chat/voice/"+created.Message.Voice, ben.token)
	if heard.Code != http.StatusOK || heard.Header().Get("Content-Type") != "audio/wav" || !bytes.Equal(heard.Body.Bytes(), wav) {
		t.Fatalf("heard %d %s", heard.Code, heard.Header().Get("Content-Type"))
	}
	cara := registerChat(t, app, `{"phone":"15550002222","username":"cara"}`)
	hidden := getChat(app, "/api/v1/chat/voice/"+created.Message.Voice, cara.token)
	if hidden.Code != http.StatusNotFound {
		t.Fatalf("hidden voice %d %s", hidden.Code, hidden.Body.String())
	}
	empty := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":" "}`)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty %d %s", empty.Code, empty.Body.String())
	}

	first := getChat(app, "/api/v1/chat/threads", ben.token)
	if first.Code != http.StatusOK {
		t.Fatalf("inbox %d %s", first.Code, first.Body.String())
	}
	stored, err := os.ReadFile(app.chat.file)
	if err != nil {
		t.Fatal(err)
	}
	var snap struct {
		Users []struct {
			Username string `json:"username"`
			LastSeen int64  `json:"lastSeen"`
		} `json:"users"`
	}
	if err := json.Unmarshal(stored, &snap); err != nil {
		t.Fatal(err)
	}
	var saved int64
	for _, user := range snap.Users {
		if user.Username == "ben" {
			saved = user.LastSeen
		}
	}
	if saved == 0 {
		t.Fatal("ben last seen was not stored")
	}
	time.Sleep(30 * time.Millisecond)
	if second := getChat(app, "/api/v1/chat/threads", ben.token); second.Code != http.StatusOK {
		t.Fatalf("second inbox %d", second.Code)
	}
	stored2, err := os.ReadFile(app.chat.file)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, stored2) {
		t.Fatal("presence was written again")
	}
	live := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ada.token)
	var peerBody struct {
		Peer struct {
			LastSeen int64 `json:"lastSeen"`
			Online   bool  `json:"online"`
		} `json:"peer"`
	}
	if err := json.Unmarshal(live.Body.Bytes(), &peerBody); err != nil {
		t.Fatal(err)
	}
	if !peerBody.Peer.Online || peerBody.Peer.LastSeen < saved {
		t.Fatalf("peer presence %s", live.Body.String())
	}

	app.chat.mu.Lock()
	for i := range app.chat.data.Users {
		if app.chat.data.Users[i].Username == "ben" {
			app.chat.data.Users[i].LastSeen = time.Now().Add(-2 * time.Minute).UnixMilli()
		}
	}
	app.chat.mu.Unlock()
	stale := getChat(app, "/api/v1/chat/threads", ada.token)
	if bytes.Contains(stale.Body.Bytes(), []byte(`"online"`)) || !bytes.Contains(stale.Body.Bytes(), []byte(`"lastSeen"`)) {
		t.Fatalf("stale %s", stale.Body.String())
	}
}

func TestChatReplyAndPicture(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000333","username":"ada"}`)
	ben := registerChat(t, app, `{"email":"ben2@example.com","username":"ben"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || opened.Code != http.StatusOK || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"hello there"}`)
	var created struct {
		Message struct {
			ID int64 `json:"id"`
		} `json:"message"`
	}
	if err := json.Unmarshal(sent.Body.Bytes(), &created); err != nil || sent.Code != http.StatusOK || created.Message.ID == 0 {
		t.Fatalf("sent %d %s", sent.Code, sent.Body.String())
	}
	reply := postChat(app, "/api/v1/chat/threads/"+thread.ID, ben.token, `{"text":"got it","reply":`+strconv.FormatInt(created.Message.ID, 10)+`}`)
	if reply.Code != http.StatusOK || !bytes.Contains(reply.Body.Bytes(), []byte(`"replyText":"hello there"`)) || !bytes.Contains(reply.Body.Bytes(), []byte(`"replyName":"ada"`)) {
		t.Fatalf("reply %d %s", reply.Code, reply.Body.String())
	}
	missing := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"nope","reply":99999}`)
	if missing.Code != http.StatusBadRequest || !bytes.Contains(missing.Body.Bytes(), []byte("no longer in this chat")) {
		t.Fatalf("missing reply %d %s", missing.Code, missing.Body.String())
	}
	empty := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":" "}`)
	if empty.Code != http.StatusBadRequest {
		t.Fatalf("empty %d %s", empty.Code, empty.Body.String())
	}

	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x01}
	photo := postChatHeaders(app, "/api/v1/chat/threads/"+thread.ID+"/photo", ada.token, png, map[string]string{
		"X-Chat-Caption": "look%20here",
		"X-Reply-Id":     strconv.FormatInt(created.Message.ID, 10),
	})
	if photo.Code != http.StatusOK || !bytes.Contains(photo.Body.Bytes(), []byte(`"text":"look here"`)) || !bytes.Contains(photo.Body.Bytes(), []byte(`"replyText":"hello there"`)) {
		t.Fatalf("photo %d %s", photo.Code, photo.Body.String())
	}
	var picture struct {
		Message struct {
			Photo string `json:"photo"`
		} `json:"message"`
	}
	if err := json.Unmarshal(photo.Body.Bytes(), &picture); err != nil || picture.Message.Photo == "" {
		t.Fatalf("photo id %s", photo.Body.String())
	}
	got := getChat(app, "/api/v1/chat/images/"+picture.Message.Photo, ben.token)
	if got.Code != http.StatusOK || got.Header().Get("Content-Type") != "image/png" || !bytes.Equal(got.Body.Bytes(), png) {
		t.Fatalf("image %d %s", got.Code, got.Header().Get("Content-Type"))
	}
	cara := registerChat(t, app, `{"phone":"15550003333","username":"cara"}`)
	hidden := getChat(app, "/api/v1/chat/images/"+picture.Message.Photo, cara.token)
	if hidden.Code != http.StatusNotFound {
		t.Fatalf("hidden image %d %s", hidden.Code, hidden.Body.String())
	}
	bad := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/photo", ada.token, []byte("not a photo"), "", "")
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("bad photo %d %s", bad.Code, bad.Body.String())
	}
}

func getChat(app *Server, path, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.Header.Set("X-Chat-Token", token)
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	return response
}

func postChatRaw(app *Server, path, token string, body []byte, header, value string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	if token != "" {
		request.Header.Set("X-Chat-Token", token)
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	if header != "" {
		request.Header.Set(header, value)
	}
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	return response
}

func postChatHeaders(app *Server, path, token string, body []byte, headers map[string]string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	if token != "" {
		request.Header.Set("X-Chat-Token", token)
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	for key, value := range headers {
		request.Header.Set(key, value)
	}
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	return response
}
