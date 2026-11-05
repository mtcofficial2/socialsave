package server

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
	user, token, err := room.register(context.Background(), "1.2.3.4", "", "a@b.co", "sam", "secret1")
	if err != nil || user.Username != "sam" || token == "" {
		t.Fatalf("%v %#v", err, user)
	}
	got, ok := room.userByToken(context.Background(), token)
	if !ok || got.Email != "a@b.co" || got.TokenHash != "" {
		t.Fatalf("token user %#v ok %v", got, ok)
	}
}

func TestChatLoginAndAdminList(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")

	ada := registerChat(t, app, `{"phone":"+256 700 000 111","username":"Ada"}`)
	again := registerChat(t, app, `{"phone":"256700000111","username":"@ada"}`)
	if again.user.Username != "ada" || again.token == "" || again.token == ada.token {
		t.Fatalf("login %#v token %q", again.user, again.token)
	}
	stale := getChat(app, "/api/v1/chat/me", ada.token)
	if stale.Code != http.StatusOK {
		t.Fatalf("first device stayed signed in %d %s", stale.Code, stale.Body.String())
	}
	third := registerChat(t, app, `{"phone":"256700000111","username":"ada"}`)
	oldest := getChat(app, "/api/v1/chat/me", ada.token)
	if oldest.Code != http.StatusUnauthorized {
		t.Fatalf("third sign-in drops the oldest device %d %s", oldest.Code, oldest.Body.String())
	}
	if getChat(app, "/api/v1/chat/me", again.token).Code != http.StatusOK {
		t.Fatal("the second device stays signed in")
	}
	fresh := getChat(app, "/api/v1/chat/me", third.token)
	if fresh.Code != http.StatusOK || !bytes.Contains(fresh.Body.Bytes(), []byte(`"username":"ada"`)) {
		t.Fatalf("new token %d %s", fresh.Code, fresh.Body.String())
	}
	mismatch := postChat(app, "/api/v1/chat/register", "", `{"phone":"256700000111","username":"other"}`)
	if mismatch.Code != http.StatusBadRequest || !bytes.Contains(mismatch.Body.Bytes(), []byte("already has")) {
		t.Fatalf("mismatch %d %s", mismatch.Code, mismatch.Body.String())
	}

	stolen := postChat(app, "/api/v1/chat/register", "", `{"phone":"15550001111","username":"daniel256"}`)
	if stolen.Code != http.StatusBadRequest || !bytes.Contains(stolen.Body.Bytes(), []byte("taken")) {
		t.Fatalf("stolen name %d %s", stolen.Code, stolen.Body.String())
	}
	stolenPhone := postChat(app, "/api/v1/chat/register", "", `{"phone":"+256 703 487 378","username":"someone"}`)
	if stolenPhone.Code != http.StatusBadRequest {
		t.Fatalf("stolen phone %d %s", stolenPhone.Code, stolenPhone.Body.String())
	}
	emailAdmin := postChat(app, "/api/v1/chat/register", "", `{"email":"admin@example.com","username":"daniel256"}`)
	if emailAdmin.Code != http.StatusBadRequest {
		t.Fatalf("email admin %d %s", emailAdmin.Code, emailAdmin.Body.String())
	}

	hidden := getChat(app, "/api/v1/chat/admin/users", again.token)
	if hidden.Code != http.StatusForbidden || bytes.Contains(hidden.Body.Bytes(), []byte("256700000111")) {
		t.Fatalf("hidden list %d %s", hidden.Code, hidden.Body.String())
	}
	missing := getChat(app, "/api/v1/chat/admin/users", "")
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("missing token %d %s", missing.Code, missing.Body.String())
	}

	admin := registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`)
	if admin.user.Username != "daniel256" || admin.user.Phone != "256703487378" {
		t.Fatalf("admin %#v", admin.user)
	}
	list := getChat(app, "/api/v1/chat/admin/users", admin.token)
	if list.Code != http.StatusOK {
		t.Fatalf("list %d %s", list.Code, list.Body.String())
	}
	body := list.Body.Bytes()
	if !bytes.Contains(body, []byte(`"username":"ada"`)) || !bytes.Contains(body, []byte("256700000111")) || !bytes.Contains(body, []byte(`"username":"daniel256"`)) {
		t.Fatalf("list body %s", body)
	}
	if bytes.Contains(body, []byte("tokenHash")) || bytes.Contains(body, []byte(admin.token)) {
		t.Fatalf("list leaked a token %s", body)
	}
	signedIn := registerChat(t, app, `{"phone":"256703487378","username":"daniel256"}`)
	if signedIn.token == "" || signedIn.token == admin.token {
		t.Fatalf("admin login token %q", signedIn.token)
	}
	if getChat(app, "/api/v1/chat/admin/users", admin.token).Code != http.StatusOK {
		t.Fatal("the first admin device stays signed in")
	}
	extra := registerChat(t, app, `{"phone":"256703487378","username":"daniel256"}`)
	if getChat(app, "/api/v1/chat/admin/users", admin.token).Code != http.StatusUnauthorized {
		t.Fatal("a third sign-in drops the oldest device")
	}
	if extra.token == "" {
		t.Fatal("third admin token")
	}
	if getChat(app, "/api/v1/chat/admin/users", signedIn.token).Code != http.StatusOK {
		t.Fatal("new admin token could not list people")
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
	response := postChat(app, "/api/v1/chat/register", "", chatTestBody(body))
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

func chatTestBody(body string) string {
	if strings.Contains(body, `"password"`) {
		return body
	}
	trimmed := strings.TrimSpace(body)
	if strings.HasSuffix(trimmed, "}") {
		return trimmed[:len(trimmed)-1] + `,"password":"secret1"}`
	}
	return body
}

func TestChatPasswordAndSeenName(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000777","username":"ada"}`)
	bad := postChat(app, "/api/v1/chat/register", "", `{"phone":"256700000777","username":"ada","password":"nope12"}`)
	if bad.Code != http.StatusBadRequest || !bytes.Contains(bad.Body.Bytes(), []byte("does not match")) {
		t.Fatalf("bad password %d %s", bad.Code, bad.Body.String())
	}
	if getChat(app, "/api/v1/chat/me", ada.token).Code != http.StatusOK {
		t.Fatal("wrong password signed the account out")
	}
	short := postChat(app, "/api/v1/chat/register", "", `{"phone":"256711111111","username":"shorty","password":"123"}`)
	if short.Code != http.StatusBadRequest {
		t.Fatalf("short password %d %s", short.Code, short.Body.String())
	}
	ben := registerChat(t, app, `{"email":"ben7@example.com","username":"ben7"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben7","name":"Benny"}`)
	if opened.Code != http.StatusOK || !bytes.Contains(opened.Body.Bytes(), []byte(`"name":"Benny"`)) {
		t.Fatalf("open name %d %s", opened.Code, opened.Body.String())
	}
	inbox := getChat(app, "/api/v1/chat/threads", ada.token)
	if !bytes.Contains(inbox.Body.Bytes(), []byte(`"name":"Benny"`)) || bytes.Contains(inbox.Body.Bytes(), []byte("passwordHash")) {
		t.Fatalf("inbox name %s", inbox.Body.String())
	}
	changed := postChat(app, "/api/v1/chat/saved", ada.token, `{"username":"ben7","name":"Ben B"}`)
	if changed.Code != http.StatusOK || !bytes.Contains(changed.Body.Bytes(), []byte(`"name":"Ben B"`)) {
		t.Fatalf("saved %d %s", changed.Code, changed.Body.String())
	}
	cleared := postChat(app, "/api/v1/chat/saved", ada.token, `{"username":"@ben7","name":"ben7"}`)
	if cleared.Code != http.StatusOK || bytes.Contains(cleared.Body.Bytes(), []byte(`"name":"ben7"`)) {
		t.Fatalf("clear %d %s", cleared.Code, cleared.Body.String())
	}
	list := getChat(app, "/api/v1/chat/admin/users", registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`).token)
	if list.Code != http.StatusOK || !bytes.Contains(list.Body.Bytes(), []byte(`"hasPassword":true`)) || bytes.Contains(list.Body.Bytes(), []byte("secret1")) || bytes.Contains(list.Body.Bytes(), []byte("passwordHash")) {
		t.Fatalf("admin %d %s", list.Code, list.Body.String())
	}
	_ = ben
}

func TestAdminDevices(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	const id = "0123456789abcdef0123456789abcdef"

	bad := postChat(app, "/api/v1/app/opened", "", `{"id":"nope","platform":"android","version":"1.0.83"}`)
	if bad.Code != http.StatusBadRequest {
		t.Fatalf("bad id %d %s", bad.Code, bad.Body.String())
	}
	opened := postChat(app, "/api/v1/app/opened", "", `{"id":"`+id+`","platform":"android","version":"1.0.83"}`)
	if opened.Code != http.StatusOK {
		t.Fatalf("opened %d %s", opened.Code, opened.Body.String())
	}

	ada := registerChat(t, app, `{"phone":"+256 700 000 111","username":"ada"}`)
	hidden := getChat(app, "/api/v1/chat/admin/users", ada.token)
	if hidden.Code != http.StatusForbidden || bytes.Contains(hidden.Body.Bytes(), []byte(id)) {
		t.Fatalf("hidden devices %d %s", hidden.Code, hidden.Body.String())
	}

	admin := registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`)
	named := postChat(app, "/api/v1/app/opened", admin.token, `{"id":"`+id+`","platform":"windows","version":"1.0.83","name":"Studio PC","model":"SHARP A202SH","imei":"490154203237518"}`)
	if named.Code != http.StatusOK {
		t.Fatalf("named %d %s", named.Code, named.Body.String())
	}
	saved := postChat(app, "/api/v1/app/opened", "", `{"id":"`+id+`","platform":"windows","version":"1.0.83","name":"Studio PC","download":true}`)
	if saved.Code != http.StatusOK {
		t.Fatalf("saved %d %s", saved.Code, saved.Body.String())
	}
	list := getChat(app, "/api/v1/chat/admin/users", admin.token)
	body := list.Body.Bytes()
	if list.Code != http.StatusOK || !bytes.Contains(body, []byte(`"platform":"windows"`)) || !bytes.Contains(body, []byte(`"username":"daniel256"`)) || !bytes.Contains(body, []byte(`"name":"Studio PC"`)) || !bytes.Contains(body, []byte(`"model":"SHARP A202SH"`)) || !bytes.Contains(body, []byte(`"downloads":1`)) {
		t.Fatalf("devices %d %s", list.Code, body)
	}
	if bytes.Contains(body, []byte(admin.token)) || bytes.Contains(body, []byte("tokenHash")) || bytes.Contains(body, []byte("490154203237518")) {
		t.Fatalf("devices leaked a token or a hardware id %s", body)
	}
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
	saved, err := os.ReadFile(app.chat.file)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(saved, png) {
		t.Fatal("picture bytes were stored")
	}
	got := getChat(app, "/api/v1/chat/images/"+picture.Message.Photo, ben.token)
	if got.Code != http.StatusOK || !bytes.Equal(got.Body.Bytes(), png) {
		t.Fatalf("image %d %s", got.Code, got.Body.String())
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

func TestChatPhotoReachesTheOtherPhoneWithoutBeingStored(t *testing.T) {
	app := testApp(t)
	dir := t.TempDir()
	app.chat.file = filepath.Join(dir, "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000444","username":"ada3"}`)
	ben := registerChat(t, app, `{"email":"ben3@example.com","username":"ben3"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben3"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	srv := httptest.NewServer(app.Router())
	defer srv.Close()
	conn, reader := dialChatSocket(t, srv.URL, ben.token)
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if op, payload := readClientFrame(t, reader); op != 0x1 || !bytes.Contains(payload, []byte(`"ready"`)) {
		t.Fatalf("ready %d %s", op, payload)
	}
	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x02}
	photo := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/photo", ada.token, png, "", "")
	if photo.Code != http.StatusOK || bytes.Contains(photo.Body.Bytes(), png) {
		t.Fatalf("photo %d", photo.Code)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var got []byte
	for i := 0; i < 6; i++ {
		op, payload := readClientFrame(t, reader)
		if op == 0x2 && bytes.Contains(payload, png) {
			got = payload
			break
		}
	}
	if !bytes.Contains(got, png) {
		t.Fatal("the other phone did not receive the picture")
	}
	saved, err := os.ReadFile(app.chat.file)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(saved, png) {
		t.Fatal("picture bytes were stored")
	}
	if _, err := os.Stat(filepath.Join(dir, "chat", "images")); err != nil {
		t.Fatal("picture file was not kept for later")
	}
}

func TestChatUnsendDropsTheMessageForBothPeople(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000555","username":"ada4"}`)
	ben := registerChat(t, app, `{"email":"ben4@example.com","username":"ben4"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben4"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	first := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"Keep me"}`)
	second := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"Take me back"}`)
	if first.Code != http.StatusOK || second.Code != http.StatusOK {
		t.Fatalf("send %d %d", first.Code, second.Code)
	}
	denied := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/unsend", ben.token, `{"id":2}`)
	if denied.Code != http.StatusBadRequest {
		t.Fatalf("receiver unsend %d %s", denied.Code, denied.Body.String())
	}
	gone := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/unsend", ada.token, `{"id":2}`)
	if gone.Code != http.StatusOK {
		t.Fatalf("unsend %d %s", gone.Code, gone.Body.String())
	}
	seen := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ben.token)
	body := seen.Body.Bytes()
	if bytes.Contains(body, []byte("Take me back")) || !bytes.Contains(body, []byte("Keep me")) {
		t.Fatalf("thread %s", body)
	}
	if !bytes.Contains(body, []byte(`"removed":[2]`)) {
		t.Fatalf("removed %s", body)
	}
	inbox := getChat(app, "/api/v1/chat/threads", ben.token)
	if bytes.Contains(inbox.Body.Bytes(), []byte("Take me back")) || !bytes.Contains(inbox.Body.Bytes(), []byte("Keep me")) {
		t.Fatalf("inbox %s", inbox.Body.String())
	}
}

func TestChatLargePhotoArrivesWhole(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000666","username":"ada5"}`)
	ben := registerChat(t, app, `{"email":"ben5@example.com","username":"ben5"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben5"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %s", opened.Body.String())
	}
	srv := httptest.NewServer(app.Router())
	defer srv.Close()
	conn, reader := dialChatSocket(t, srv.URL, ben.token)
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if op, payload := readClientFrame(t, reader); op != 0x1 || !bytes.Contains(payload, []byte(`"ready"`)) {
		t.Fatalf("ready %d %s", op, payload)
	}
	jpeg := bytes.Repeat([]byte{0}, 20*1024)
	jpeg[0], jpeg[1], jpeg[2] = 0xFF, 0xD8, 0xFF
	photo := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/photo", ada.token, jpeg, "", "")
	if photo.Code != http.StatusOK {
		t.Fatalf("photo %d %s", photo.Code, photo.Body.String())
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	var got []byte
	for i := 0; i < 8; i++ {
		op, payload := readClientFrame(t, reader)
		if op == 0x2 && bytes.Contains(payload, jpeg) {
			got = payload
			break
		}
	}
	if !bytes.Contains(got, jpeg) {
		t.Fatalf("picture length %d", len(got))
	}
}

func dialChatSocket(t *testing.T, rawURL, token string) (net.Conn, *bufio.Reader) {
	t.Helper()
	host := strings.TrimPrefix(rawURL, "http://")
	conn, err := net.Dial("tcp", host)
	if err != nil {
		t.Fatal(err)
	}
	req := "GET /api/v1/chat/live HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-Chat-Token: " + token + "\r\n\r\n"
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	status, err := reader.ReadString('\n')
	if err != nil || !strings.Contains(status, "101") {
		t.Fatalf("upgrade %q %v", status, err)
	}
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" {
			break
		}
	}
	return conn, reader
}

func readClientFrame(t *testing.T, r *bufio.Reader) (byte, []byte) {
	t.Helper()
	var op byte
	var buf []byte
	for {
		fin, opcode, payload, err := readFrame(r, chatPhotoMax+512)
		if err != nil {
			t.Fatal(err)
		}
		if opcode >= 0x8 {
			return opcode, payload
		}
		if opcode == 0 {
			buf = append(buf, payload...)
		} else {
			op = opcode
			buf = append([]byte(nil), payload...)
		}
		if fin {
			return op, buf
		}
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

func TestChatThreadReportsLastIDSoClientsCanResetTheirCursor(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000561","username":"ada9"}`)
	ben := registerChat(t, app, `{"email":"ben9@example.com","username":"ben9"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"@BEN9"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	back := postChat(app, "/api/v1/chat/threads", ben.token, `{"username":"ada9"}`)
	if !bytes.Contains(back.Body.Bytes(), []byte(thread.ID)) {
		t.Fatalf("reply side opened another thread: %s", back.Body.String())
	}
	for _, text := range []string{"one", "two"} {
		if sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"`+text+`"}`); sent.Code != http.StatusOK {
			t.Fatalf("send %d %s", sent.Code, sent.Body.String())
		}
	}
	var got struct {
		LastID   int64             `json:"lastId"`
		Messages []json.RawMessage `json:"messages"`
	}
	res := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=50", ben.token)
	if err := json.Unmarshal(res.Body.Bytes(), &got); err != nil {
		t.Fatalf("list %s", res.Body.String())
	}
	if got.LastID != 2 || len(got.Messages) != 0 {
		t.Fatalf("lastId %d messages %d", got.LastID, len(got.Messages))
	}
}

func TestChatGroupsReactionsBlockAndSong(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "groups.json")
	ada := registerChat(t, app, `{"phone":"256711000001","username":"ada"}`)
	ben := registerChat(t, app, `{"phone":"256711000002","username":"ben"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %s", opened.Body.String())
	}
	sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"hello"}`)
	if sent.Code != http.StatusOK {
		t.Fatalf("send %d %s", sent.Code, sent.Body.String())
	}
	react := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/react", ben.token, `{"id":1,"emoji":"👍"}`)
	if react.Code != http.StatusOK || !bytes.Contains(react.Body.Bytes(), []byte("👍")) {
		t.Fatalf("react %d %s", react.Code, react.Body.String())
	}
	edited := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/edit", ada.token, `{"id":1,"text":"hello there"}`)
	if edited.Code != http.StatusOK || !bytes.Contains(edited.Body.Bytes(), []byte("hello there")) {
		t.Fatalf("edit %d %s", edited.Code, edited.Body.String())
	}
	pinned := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/pin", ada.token, `{"id":1}`)
	if pinned.Code != http.StatusOK || !bytes.Contains(pinned.Body.Bytes(), []byte(`[1]`)) {
		t.Fatalf("pin %d %s", pinned.Code, pinned.Body.String())
	}
	info := getChat(app, "/api/v1/chat/threads/"+thread.ID+"/info?id=1", ada.token)
	if info.Code != http.StatusOK || !bytes.Contains(info.Body.Bytes(), []byte(`"id":1`)) {
		t.Fatalf("info %d %s", info.Code, info.Body.String())
	}
	blocked := postChat(app, "/api/v1/chat/block", ada.token, `{"username":"ben","on":true}`)
	if blocked.Code != http.StatusOK {
		t.Fatalf("block %d %s", blocked.Code, blocked.Body.String())
	}
	denied := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"still here"}`)
	if denied.Code != http.StatusBadRequest || !bytes.Contains(denied.Body.Bytes(), []byte("blocked")) {
		t.Fatalf("blocked send %d %s", denied.Code, denied.Body.String())
	}
	if postChat(app, "/api/v1/chat/block", ada.token, `{"username":"ben","on":false}`).Code != http.StatusOK {
		t.Fatal("unblock")
	}

	made := postChat(app, "/api/v1/chat/groups", ada.token, `{"name":"Family"}`)
	var group struct {
		ID   string `json:"id"`
		Code string `json:"code"`
	}
	if made.Code != http.StatusOK || json.Unmarshal(made.Body.Bytes(), &group) != nil || len(group.Code) != 6 {
		t.Fatalf("group %d %s", made.Code, made.Body.String())
	}
	joined := postChat(app, "/api/v1/chat/groups/join", ben.token, `{"code":"`+group.Code+`"}`)
	if joined.Code != http.StatusOK || !bytes.Contains(joined.Body.Bytes(), []byte(group.ID)) {
		t.Fatalf("join %d %s", joined.Code, joined.Body.String())
	}
	cam := registerChat(t, app, `{"phone":"256711000003","username":"cam"}`)
	added := postChat(app, "/api/v1/chat/groups/"+group.ID+"/members", ada.token, `{"username":"@cam"}`)
	if added.Code != http.StatusOK || !bytes.Contains(added.Body.Bytes(), []byte("cam")) {
		t.Fatalf("add %d %s", added.Code, added.Body.String())
	}
	camInbox := getChat(app, "/api/v1/chat/threads", cam.token)
	if !bytes.Contains(camInbox.Body.Bytes(), []byte("Family")) {
		t.Fatalf("added inbox %s", camInbox.Body.String())
	}
	missing := postChat(app, "/api/v1/chat/groups/"+group.ID+"/members", ada.token, `{"username":"nobody99"}`)
	if missing.Code != http.StatusBadRequest {
		t.Fatalf("missing user %d %s", missing.Code, missing.Body.String())
	}
	out := registerChat(t, app, `{"phone":"256711000004","username":"outsider"}`)
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/members", out.token, `{"username":"ada"}`).Code == http.StatusOK {
		t.Fatal("someone outside the group added a member")
	}
	note := postChat(app, "/api/v1/chat/threads/"+group.ID, ben.token, `{"text":"in the group"}`)
	if note.Code != http.StatusOK {
		t.Fatalf("group send %d %s", note.Code, note.Body.String())
	}
	inbox := getChat(app, "/api/v1/chat/threads", ada.token)
	if !bytes.Contains(inbox.Body.Bytes(), []byte(`"group":true`)) || !bytes.Contains(inbox.Body.Bytes(), []byte("Family")) {
		t.Fatalf("inbox %s", inbox.Body.String())
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/leave", ben.token, `{}`).Code != http.StatusOK {
		t.Fatal("leave")
	}
	song := postChatRaw(app, "/api/v1/chat/threads/"+thread.ID+"/song", ada.token, []byte("RIFF\x24\x00\x00\x00WAVEfmt "), "X-Song-Name", "Hello")
	if song.Code != http.StatusOK || !bytes.Contains(song.Body.Bytes(), []byte(`"song"`)) {
		t.Fatalf("song %d %s", song.Code, song.Body.String())
	}
}
