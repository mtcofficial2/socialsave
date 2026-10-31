package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
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
	stranger := registerChat(t, app, `{"phone":"15550001111","username":"cara"}`)
	hidden := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", stranger.token)
	if hidden.Code != http.StatusBadRequest {
		t.Fatalf("hidden %d %s", hidden.Code, hidden.Body.String())
	}

	inbox := getChat(app, "/api/v1/chat/threads", ben.token)
	if !bytes.Contains(inbox.Body.Bytes(), []byte(`"username":"ada"`)) {
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

func getChat(app *Server, path, token string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, path, nil)
	request.Header.Set("X-Chat-Token", token)
	response := httptest.NewRecorder()
	app.Router().ServeHTTP(response, request)
	return response
}
