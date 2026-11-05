package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestChatPrivacyStatusAndRequests(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256720000001","username":"ada"}`)
	ben := registerChat(t, app, `{"phone":"256720000002","username":"ben"}`)
	cam := registerChat(t, app, `{"phone":"256720000003","username":"cam"}`)

	first := registerChat(t, app, `{"phone":"256720000001","username":"ada"}`)
	if first.token == "" {
		t.Fatal("second sign-in")
	}
	again := postChat(app, "/api/v1/chat/register", "", `{"phone":"256720000001","username":"ada","password":"secret1"}`)
	if bytesContain(again.Body.Bytes(), `"recovery"`) {
		t.Fatalf("recovery code came back on a later sign-in: %s", again.Body.String())
	}
	ada = first

	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || thread.ID == "" {
		t.Fatalf("open %s", opened.Body.String())
	}
	inbox := getChat(app, "/api/v1/chat/threads", ben.token)
	if !bytesContain(inbox.Body.Bytes(), `"request":true`) {
		t.Fatalf("request %s", inbox.Body.String())
	}
	for i, text := range []string{"one", "two"} {
		sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"`+text+`"}`)
		if sent.Code != http.StatusOK {
			t.Fatalf("send %d %d %s", i, sent.Code, sent.Body.String())
		}
	}
	early := postChat(app, "/api/v1/chat/calls", ada.token, `{"thread":"`+thread.ID+`"}`)
	if early.Code != http.StatusBadRequest || !bytesContain(early.Body.Bytes(), "accept your message") {
		t.Fatalf("early call %d %s", early.Code, early.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+thread.ID+"/accept", ben.token, `{}`).Code != http.StatusOK {
		t.Fatal("accept")
	}
	cleared := getChat(app, "/api/v1/chat/threads", ben.token)
	if bytesContain(cleared.Body.Bytes(), `"request":true`) {
		t.Fatalf("still a request %s", cleared.Body.String())
	}

	png := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x01}
	if postChatRaw(app, "/api/v1/chat/photo", ben.token, png, "", "").Code != http.StatusOK {
		t.Fatal("photo")
	}
	hidden := postChat(app, "/api/v1/chat/privacy", ben.token, `{"online":"nobody","lastSeen":"nobody","photo":"nobody","receipts":"nobody"}`)
	if hidden.Code != http.StatusOK {
		t.Fatalf("privacy %d %s", hidden.Code, hidden.Body.String())
	}
	if getChat(app, "/api/v1/chat/photo?username=ben", ada.token).Code != http.StatusNotFound {
		t.Fatal("hidden photo was returned")
	}
	if getChat(app, "/api/v1/chat/photo?username=ben", ben.token).Code != http.StatusOK {
		t.Fatal("own photo was hidden")
	}
	sent := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"seen?"}`)
	if sent.Code != http.StatusOK {
		t.Fatalf("seen send %d %s", sent.Code, sent.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+thread.ID+"/read", ben.token, `{"id":3}`).Code != http.StatusOK {
		t.Fatal("read")
	}
	ticks := getChat(app, "/api/v1/chat/threads/"+thread.ID+"?after=0", ada.token)
	if bytesContain(ticks.Body.Bytes(), `"status":"read"`) || !bytesContain(ticks.Body.Bytes(), `"status":"delivered"`) {
		t.Fatalf("receipts %s", ticks.Body.String())
	}
	adaInbox := getChat(app, "/api/v1/chat/threads", ada.token)
	if bytesContain(adaInbox.Body.Bytes(), `"lastSeen"`) || bytesContain(adaInbox.Body.Bytes(), `"online"`) {
		t.Fatalf("presence %s", adaInbox.Body.String())
	}

	note := postChat(app, "/api/v1/chat/status", ada.token, `{"text":"out today","audience":"only","allow":["ben"]}`)
	if note.Code != http.StatusOK {
		t.Fatalf("status %d %s", note.Code, note.Body.String())
	}
	if !bytesContain(getChat(app, "/api/v1/chat/status", ben.token).Body.Bytes(), "out today") {
		t.Fatal("ben missed the update")
	}
	if bytesContain(getChat(app, "/api/v1/chat/status", cam.token).Body.Bytes(), "out today") {
		t.Fatal("cam saw a private update")
	}
	app.chat.mu.Lock()
	for i := range app.chat.data.Statuses {
		app.chat.data.Statuses[i].At = time.Now().Add(-25 * time.Hour).UnixMilli()
	}
	app.chat.mu.Unlock()
	if bytesContain(getChat(app, "/api/v1/chat/status", ada.token).Body.Bytes(), "out today") {
		t.Fatal("expired update stayed")
	}
}

func TestChatGroupsPollsStarsAndCalls(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256721000001","username":"ada"}`)
	ben := registerChat(t, app, `{"phone":"256721000002","username":"ben"}`)
	cam := registerChat(t, app, `{"phone":"256721000003","username":"cam"}`)

	made := postChat(app, "/api/v1/chat/groups", ada.token, `{"name":"Family"}`)
	var group struct {
		ID    string `json:"id"`
		Code  string `json:"code"`
		Owner string `json:"owner"`
	}
	if err := json.Unmarshal(made.Body.Bytes(), &group); err != nil || group.ID == "" || group.Owner == "" {
		t.Fatalf("group %s", made.Body.String())
	}
	if postChat(app, "/api/v1/chat/groups/join", ben.token, `{"code":"`+group.Code+`"}`).Code != http.StatusOK {
		t.Fatal("join")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/members", ada.token, `{"username":"cam"}`).Code != http.StatusOK {
		t.Fatal("add")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/remove", ben.token, `{"username":"cam"}`).Code == http.StatusOK {
		t.Fatal("a member removed someone")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/name", ben.token, `{"name":"Nope"}`).Code == http.StatusOK {
		t.Fatal("a member renamed the group")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/info", ada.token, `{"about":"Sunday lunch","rules":"Be kind","announce":true}`).Code != http.StatusOK {
		t.Fatal("info")
	}
	quiet := postChat(app, "/api/v1/chat/threads/"+group.ID, cam.token, `{"text":"hello"}`)
	if quiet.Code != http.StatusBadRequest || !bytesContain(quiet.Body.Bytes(), "Only admins") {
		t.Fatalf("announce %d %s", quiet.Code, quiet.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+group.ID, ada.token, `{"text":"notice"}`).Code != http.StatusOK {
		t.Fatal("admin post")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/remove", ada.token, `{"username":"ada"}`).Code == http.StatusOK {
		t.Fatal("owner removed themselves")
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/transfer", ada.token, `{"username":"ben"}`).Code != http.StatusOK {
		t.Fatal("transfer")
	}
	moved := getChat(app, "/api/v1/chat/groups/"+group.ID, ada.token)
	if bytesContain(moved.Body.Bytes(), `"owner":"`+group.Owner+`"`) {
		t.Fatalf("owner stayed %s", moved.Body.String())
	}
	if postChat(app, "/api/v1/chat/groups/"+group.ID+"/remove", ben.token, `{"username":"cam"}`).Code != http.StatusOK {
		t.Fatal("new owner remove")
	}
	rotated := postChat(app, "/api/v1/chat/groups/"+group.ID+"/invite", ben.token, `{"hours":1}`)
	var invite struct {
		Code string `json:"code"`
	}
	if rotated.Code != http.StatusOK || json.Unmarshal(rotated.Body.Bytes(), &invite) != nil || len(invite.Code) != 6 {
		t.Fatalf("invite %d %s", rotated.Code, rotated.Body.String())
	}
	app.chat.mu.Lock()
	for i := range app.chat.data.Threads {
		if app.chat.data.Threads[i].ID == group.ID {
			app.chat.data.Threads[i].InviteExp = time.Now().Add(-time.Minute).UnixMilli()
		}
	}
	app.chat.mu.Unlock()
	dee := registerChat(t, app, `{"phone":"256721000004","username":"dee"}`)
	expired := postChat(app, "/api/v1/chat/groups/join", dee.token, `{"code":"`+invite.Code+`"}`)
	if expired.Code != http.StatusBadRequest || !bytesContain(expired.Body.Bytes(), "expired") {
		t.Fatalf("expired %d %s", expired.Code, expired.Body.String())
	}

	direct := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var chat struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(direct.Body.Bytes(), &chat) != nil || chat.ID == "" {
		t.Fatalf("direct %s", direct.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+chat.ID, ben.token, `{"text":"go ahead"}`).Code != http.StatusOK {
		t.Fatal("reply")
	}
	when := time.Now().Add(2 * time.Hour).UnixMilli()
	poll := postChat(app, "/api/v1/chat/threads/"+chat.ID, ada.token, `{"poll":{"question":"Lunch","choices":["Rice","Beans"],"closes":`+itoa(when)+`}}`)
	if poll.Code != http.StatusOK || !bytesContain(poll.Body.Bytes(), "Lunch") {
		t.Fatalf("poll %d %s", poll.Code, poll.Body.String())
	}
	var polled struct {
		Message struct {
			ID int64 `json:"id"`
		} `json:"message"`
	}
	if json.Unmarshal(poll.Body.Bytes(), &polled) != nil || polled.Message.ID == 0 {
		t.Fatal("poll id")
	}
	vote := postChat(app, "/api/v1/chat/threads/"+chat.ID+"/poll", ben.token, `{"id":`+itoa(polled.Message.ID)+`,"choice":1}`)
	if vote.Code != http.StatusOK || !bytesContain(vote.Body.Bytes(), `"ben":1`) {
		t.Fatalf("vote %d %s", vote.Code, vote.Body.String())
	}
	closed := postChat(app, "/api/v1/chat/threads/"+chat.ID+"/poll", ada.token, `{"id":`+itoa(polled.Message.ID)+`,"close":true}`)
	if closed.Code != http.StatusOK || !bytesContain(closed.Body.Bytes(), `"closed":true`) {
		t.Fatalf("close %d %s", closed.Code, closed.Body.String())
	}

	card := postChat(app, "/api/v1/chat/threads/"+chat.ID, ada.token, `{"card":{"name":"Ada","phone":"+256720000099"}}`)
	if card.Code != http.StatusOK || !bytesContain(card.Body.Bytes(), "Contact: Ada") {
		t.Fatalf("card %d %s", card.Code, card.Body.String())
	}
	place := postChat(app, "/api/v1/chat/threads/"+chat.ID, ada.token, `{"place":{"lat":0.3476,"lng":32.5825,"label":"Kampala"}}`)
	if place.Code != http.StatusOK || !bytesContain(place.Body.Bytes(), "https://maps.google.com/?q=0.34760,32.58250") {
		t.Fatalf("place %d %s", place.Code, place.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+chat.ID, ada.token, `{"place":{"lat":99,"lng":0}}`).Code != http.StatusBadRequest {
		t.Fatal("bad place")
	}

	if postChat(app, "/api/v1/chat/stars", ada.token, `{"thread":"`+chat.ID+`","id":`+itoa(polled.Message.ID)+`,"on":true}`).Code != http.StatusOK {
		t.Fatal("star")
	}
	stars := getChat(app, "/api/v1/chat/stars", ada.token)
	if !bytesContain(stars.Body.Bytes(), "Lunch") {
		t.Fatalf("stars %s", stars.Body.String())
	}
	folder := postChat(app, "/api/v1/chat/labels", ada.token, `{"name":"Family","threads":["`+chat.ID+`"]}`)
	if folder.Code != http.StatusOK || !bytesContain(folder.Body.Bytes(), "Family") {
		t.Fatalf("folder %d %s", folder.Code, folder.Body.String())
	}

	sendAt := time.Now().Add(2 * time.Minute).UnixMilli()
	scheduled := postChat(app, "/api/v1/chat/threads/"+chat.ID+"/schedule", ada.token, `{"thread":"`+chat.ID+`","text":"later please","sendAt":`+itoa(sendAt)+`,"zone":"Africa/Kampala"}`)
	if scheduled.Code != http.StatusOK {
		t.Fatalf("schedule %d %s", scheduled.Code, scheduled.Body.String())
	}
	app.chat.mu.Lock()
	for i := range app.chat.data.Schedules {
		app.chat.data.Schedules[i].SendAt = time.Now().Add(-time.Second).UnixMilli()
	}
	app.chat.mu.Unlock()
	app.chat.sendDue(context.Background())
	seen := getChat(app, "/api/v1/chat/threads/"+chat.ID+"?after=0", ben.token)
	if !bytesContain(seen.Body.Bytes(), "later please") {
		t.Fatalf("due %s", seen.Body.String())
	}

	call := postChat(app, "/api/v1/chat/calls", ada.token, `{"thread":"`+chat.ID+`","sdp":"v=0"}`)
	var invited struct {
		Call struct {
			ID    string `json:"id"`
			State string `json:"state"`
		} `json:"call"`
	}
	if call.Code != http.StatusOK || json.Unmarshal(call.Body.Bytes(), &invited) != nil || invited.Call.State != "ringing" {
		t.Fatalf("call %d %s", call.Code, call.Body.String())
	}
	declined := postChat(app, "/api/v1/chat/calls/"+invited.Call.ID+"/answer", ben.token, `{"accept":false}`)
	if declined.Code != http.StatusOK || !bytesContain(declined.Body.Bytes(), `"state":"declined"`) {
		t.Fatalf("decline %d %s", declined.Code, declined.Body.String())
	}
	if !bytesContain(getChat(app, "/api/v1/chat/threads/"+chat.ID+"?after=0", ada.token).Body.Bytes(), "Declined audio call") {
		t.Fatal("decline was not kept in the chat")
	}
	second := postChat(app, "/api/v1/chat/calls", ada.token, `{"thread":"`+chat.ID+`"}`)
	var ringing struct {
		Call struct {
			ID string `json:"id"`
		} `json:"call"`
	}
	if second.Code != http.StatusOK || json.Unmarshal(second.Body.Bytes(), &ringing) != nil || ringing.Call.ID == "" {
		t.Fatalf("second call %d %s", second.Code, second.Body.String())
	}
	app.chat.mu.Lock()
	for i := range app.chat.data.Calls {
		if app.chat.data.Calls[i].ID == ringing.Call.ID {
			app.chat.data.Calls[i].At = time.Now().Add(-2 * time.Minute).UnixMilli()
		}
	}
	app.chat.mu.Unlock()
	app.chat.missStaleCalls(context.Background())
	history := getChat(app, "/api/v1/chat/calls", ada.token)
	if !bytesContain(history.Body.Bytes(), `"state":"missed"`) || !bytesContain(getChat(app, "/api/v1/chat/threads/"+chat.ID+"?after=0", ben.token).Body.Bytes(), "Missed audio call") {
		t.Fatalf("missed %s", history.Body.String())
	}
}

func TestChatRecoverySessionsAndReports(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	created := postChat(app, "/api/v1/chat/register", "", `{"phone":"256722000001","username":"ada","password":"secret1"}`)
	if created.Code != http.StatusOK {
		t.Fatalf("register %d %s", created.Code, created.Body.String())
	}
	var registered struct {
		Token    string `json:"token"`
		Recovery string `json:"recovery"`
	}
	if err := json.Unmarshal(created.Body.Bytes(), &registered); err != nil {
		t.Fatal(err)
	}
	if len(registered.Recovery) != 10 || registered.Token == "" || bytesContain(created.Body.Bytes(), "recoveryHash") || bytesContain(created.Body.Bytes(), "secret1") {
		t.Fatalf("recovery response leaked or was empty")
	}
	ada := registeredChat{token: registered.Token}
	ben := registerChat(t, app, `{"phone":"256722000002","username":"ben"}`)
	other := registerChat(t, app, `{"phone":"256722000001","username":"ada"}`)
	if other.token == "" || other.token == ada.token {
		t.Fatal("second device")
	}
	touch := postChat(app, "/api/v1/chat/sessions/touch", other.token, `{"name":"Studio PC","platform":"windows","imei":"490154203237518"}`)
	if touch.Code != http.StatusOK {
		t.Fatalf("touch %d %s", touch.Code, touch.Body.String())
	}
	listed := getChat(app, "/api/v1/chat/sessions", other.token)
	sum := sha256.Sum256([]byte(other.token))
	full := hex.EncodeToString(sum[:])
	if !bytesContain(listed.Body.Bytes(), "Studio PC") || !bytesContain(listed.Body.Bytes(), `"current":true`) || bytesContain(listed.Body.Bytes(), full) || bytesContain(listed.Body.Bytes(), "490154203237518") {
		t.Fatalf("sessions %s", listed.Body.String())
	}
	var sessions struct {
		Sessions []struct {
			ID      string `json:"id"`
			Current bool   `json:"current"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal(listed.Body.Bytes(), &sessions); err != nil || len(sessions.Sessions) != 2 {
		t.Fatalf("session count %s", listed.Body.String())
	}
	for _, item := range sessions.Sessions {
		if len(item.ID) != 12 {
			t.Fatalf("prefix %q", item.ID)
		}
		if item.Current {
			self := postChat(app, "/api/v1/chat/sessions/end", other.token, `{"id":"`+item.ID+`"}`)
			if self.Code != http.StatusBadRequest {
				t.Fatalf("end current %d %s", self.Code, self.Body.String())
			}
		}
	}
	if postChat(app, "/api/v1/chat/sessions/others", other.token, `{}`).Code != http.StatusOK {
		t.Fatal("sign out others")
	}
	if getChat(app, "/api/v1/chat/me", ada.token).Code != http.StatusUnauthorized {
		t.Fatal("the other device stayed signed in")
	}
	if getChat(app, "/api/v1/chat/me", other.token).Code != http.StatusOK {
		t.Fatal("this device was signed out")
	}
	stored, err := os.ReadFile(app.chat.file)
	if err != nil {
		t.Fatal(err)
	}
	if bytesContain(stored, "490154203237518") {
		t.Fatal("imei was stored")
	}

	wrong := postChat(app, "/api/v1/chat/recover", "", `{"username":"ada","code":"WRONGCODE1","password":"newpass9"}`)
	if wrong.Code != http.StatusBadRequest {
		t.Fatalf("wrong code %d %s", wrong.Code, wrong.Body.String())
	}
	recovered := postChat(app, "/api/v1/chat/recover", "", `{"username":"ada","code":"`+registered.Recovery+`","password":"newpass9"}`)
	if recovered.Code != http.StatusOK || bytesContain(recovered.Body.Bytes(), "newpass9") || bytesContain(recovered.Body.Bytes(), "recoveryHash") || bytesContain(recovered.Body.Bytes(), registered.Recovery) {
		t.Fatalf("recover leaked a secret: %d", recovered.Code)
	}
	var next struct {
		Token    string `json:"token"`
		Recovery string `json:"recovery"`
	}
	if json.Unmarshal(recovered.Body.Bytes(), &next) != nil || next.Token == "" || len(next.Recovery) != 10 || next.Recovery == registered.Recovery {
		t.Fatal("new recovery code was not issued")
	}
	if getChat(app, "/api/v1/chat/me", other.token).Code != http.StatusUnauthorized {
		t.Fatal("old session survived recovery")
	}
	if getChat(app, "/api/v1/chat/me", next.Token).Code != http.StatusOK {
		t.Fatal("new session")
	}
	stale := postChat(app, "/api/v1/chat/recover", "", `{"username":"ada","code":"`+registered.Recovery+`","password":"newpass9"}`)
	if stale.Code != http.StatusBadRequest {
		t.Fatalf("old code still worked %d", stale.Code)
	}
	if postChat(app, "/api/v1/chat/register", "", `{"phone":"256722000001","username":"ada","password":"secret1"}`).Code != http.StatusBadRequest {
		t.Fatal("old password still worked")
	}

	for i := 0; i < 5; i++ {
		report := postChat(app, "/api/v1/chat/report", ben.token, `{"username":"ada","reason":"spam"}`)
		if report.Code != http.StatusOK {
			t.Fatalf("report %d %d %s", i, report.Code, report.Body.String())
		}
	}
	if postChat(app, "/api/v1/chat/report", ben.token, `{"username":"ada","reason":"spam"}`).Code != http.StatusTooManyRequests {
		t.Fatal("report rate")
	}
	fresh := postChat(app, "/api/v1/chat/threads", next.Token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if json.Unmarshal(fresh.Body.Bytes(), &thread) != nil || thread.ID == "" {
		t.Fatalf("fresh %s", fresh.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+thread.ID, next.Token, `{"text":"first"}`).Code != http.StatusOK {
		t.Fatal("first after reports")
	}
	limited := postChat(app, "/api/v1/chat/threads/"+thread.ID, next.Token, `{"text":"second"}`)
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("reported limit %d %s", limited.Code, limited.Body.String())
	}
}

func TestCleanSDPKeepsATrailingLine(t *testing.T) {
	got, err := cleanSDP("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got, "\r\n") || !strings.Contains(got, "m=audio 9") {
		t.Fatalf("sdp %q", got)
	}
	again, err := cleanSDP(strings.TrimSpace(got))
	if err != nil || again != got {
		t.Fatalf("round trip %q %v", again, err)
	}
	if _, err := cleanSDP("not-sdp"); err == nil {
		t.Fatal("accepted junk")
	}
}

func bytesContain(body []byte, part string) bool {
	return bytes.Contains(body, []byte(part))
}

func itoa(value int64) string {
	return strconv.FormatInt(value, 10)
}
