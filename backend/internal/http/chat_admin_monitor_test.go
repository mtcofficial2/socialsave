package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestAdminMonitorLists(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"+256 700 000 111","username":"ada"}`)
	ben := registerChat(t, app, `{"email":"ben7@example.com","username":"ben7"}`)
	made := postChat(app, "/api/v1/chat/groups", ada.token, `{"name":"Family"}`)
	var group struct {
		ID   string `json:"id"`
		Code string `json:"code"`
	}
	if err := json.Unmarshal(made.Body.Bytes(), &group); err != nil || made.Code != http.StatusOK || group.ID == "" || group.Code == "" {
		t.Fatalf("group %d %s", made.Code, made.Body.String())
	}
	posted := postChat(app, "/api/v1/chat/threads/"+group.ID, ada.token, `{"text":"hello group"}`)
	if posted.Code != http.StatusOK {
		t.Fatalf("group post %d %s", posted.Code, posted.Body.String())
	}
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben7"}`)
	var dm struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &dm); err != nil || opened.Code != http.StatusOK || dm.ID == "" {
		t.Fatalf("dm %d %s", opened.Code, opened.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+dm.ID, ada.token, `{"text":"private note"}`).Code != http.StatusOK {
		t.Fatal("dm post")
	}
	if postChat(app, "/api/v1/chat/report", ben.token, `{"username":"ada","reason":"spam"}`).Code != http.StatusOK {
		t.Fatal("report")
	}

	const install = "0123456789abcdef0123456789abcdef"
	if postChat(app, "/api/v1/app/opened", ada.token, `{"id":"`+install+`","platform":"android","version":"1.0.103","name":"Ada phone"}`).Code != http.StatusOK {
		t.Fatal("signed-in open")
	}
	admin := registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`)
	list := getChat(app, "/api/v1/chat/admin/users", admin.token)
	body := list.Body.Bytes()
	if list.Code != http.StatusOK {
		t.Fatalf("list %d %s", list.Code, body)
	}
	if bytesIndex(body, "hello group") >= 0 || bytesIndex(body, "private note") >= 0 || bytesIndex(body, group.Code) >= 0 {
		t.Fatalf("list leaked a message or a join code %s", body)
	}
	if bytesIndex(body, ada.token) >= 0 || bytesIndex(body, "tokenHash") >= 0 || bytesIndex(body, "passwordHash") >= 0 || bytesIndex(body, "recoveryHash") >= 0 {
		t.Fatalf("list leaked a secret %s", body)
	}
	var parsed struct {
		DeviceLimit int `json:"deviceLimit"`
		Users       []struct {
			Username    string `json:"username"`
			HasRecovery bool   `json:"hasRecovery"`
			Sessions    []struct {
				ID string `json:"id"`
			} `json:"sessions"`
		} `json:"users"`
		Devices []struct {
			ID       string `json:"id"`
			Username string `json:"username"`
			SignedIn bool   `json:"signedIn"`
		} `json:"devices"`
		Groups []struct {
			Name     string `json:"name"`
			Owner    string `json:"owner"`
			Members  int    `json:"members"`
			Announce bool   `json:"announce"`
		} `json:"groups"`
		Reports []struct {
			From   string `json:"from"`
			Target string `json:"target"`
			Reason string `json:"reason"`
		} `json:"reports"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatal(err)
	}
	if parsed.DeviceLimit != 2000 {
		t.Fatalf("limit %d", parsed.DeviceLimit)
	}
	var adaRow bool
	for _, user := range parsed.Users {
		if user.Username == "ada" {
			adaRow = user.HasRecovery && len(user.Sessions) > 0 && len(user.Sessions[0].ID) == 12
		}
		for _, session := range user.Sessions {
			if len(session.ID) > 12 {
				t.Fatalf("session id too long %s", session.ID)
			}
		}
	}
	if !adaRow {
		t.Fatalf("ada row %#v", parsed.Users)
	}
	var seenDevice bool
	for _, device := range parsed.Devices {
		if device.ID == install {
			seenDevice = device.SignedIn && device.Username == "ada"
		}
	}
	if !seenDevice {
		t.Fatalf("device %#v", parsed.Devices)
	}
	if len(parsed.Groups) != 1 || parsed.Groups[0].Name != "Family" || parsed.Groups[0].Owner != "ada" || parsed.Groups[0].Members != 1 || parsed.Groups[0].Announce {
		t.Fatalf("groups %#v", parsed.Groups)
	}
	if len(parsed.Reports) != 1 || parsed.Reports[0].From != "ben7" || parsed.Reports[0].Target != "ada" || parsed.Reports[0].Reason != "spam" {
		t.Fatalf("reports %#v", parsed.Reports)
	}

	groupRead := getChat(app, "/api/v1/chat/threads/"+group.ID, admin.token)
	if groupRead.Code != http.StatusOK || bytesIndex(groupRead.Body.Bytes(), "hello group") < 0 {
		t.Fatalf("admin group read %d %s", groupRead.Code, groupRead.Body.String())
	}
	hidden := getChat(app, "/api/v1/chat/threads/"+group.ID, ben.token)
	if hidden.Code == http.StatusOK {
		t.Fatalf("non-member read the group %s", hidden.Body.String())
	}
	dmRead := getChat(app, "/api/v1/chat/threads/"+dm.ID, admin.token)
	if dmRead.Code == http.StatusOK || bytesIndex(dmRead.Body.Bytes(), "private note") >= 0 {
		t.Fatalf("admin read a direct chat %d %s", dmRead.Code, dmRead.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+group.ID, admin.token, `{"text":"from monitor"}`).Code == http.StatusOK {
		t.Fatal("admin posted into a group they are not in")
	}

	if postChat(app, "/api/v1/app/opened", "", `{"id":"`+install+`","platform":"android","version":"1.0.103","name":"Ada phone"}`).Code != http.StatusOK {
		t.Fatal("signed-out open")
	}
	again := getChat(app, "/api/v1/chat/admin/users", admin.token)
	var after struct {
		Devices []struct {
			ID       string `json:"id"`
			Username string `json:"username"`
			SignedIn bool   `json:"signedIn"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(again.Body.Bytes(), &after); err != nil {
		t.Fatal(err)
	}
	var kept bool
	for _, device := range after.Devices {
		if device.ID == install {
			kept = device.Username == "ada" && !device.SignedIn
		}
	}
	if !kept {
		t.Fatalf("signed-out device %#v", after.Devices)
	}
	_ = ben
}

func TestAdminDisableAndSignOut(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	ada := registerChat(t, app, `{"phone":"256700000222","username":"ada"}`)
	adaAgain := registerChat(t, app, `{"phone":"256700000222","username":"ada"}`)
	ben := registerChat(t, app, `{"phone":"256700000333","username":"ben"}`)
	admin := registerChat(t, app, `{"phone":"+256 703 487 378","username":"daniel256"}`)
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben"}`)
	var thread struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &thread); err != nil || opened.Code != http.StatusOK || thread.ID == "" {
		t.Fatalf("open %d %s", opened.Code, opened.Body.String())
	}
	if postChat(app, "/api/v1/chat/admin/disable", ben.token, `{"username":"ada","disabled":true}`).Code != http.StatusForbidden {
		t.Fatal("a normal account disabled someone")
	}
	if postChat(app, "/api/v1/chat/admin/disable", admin.token, `{"username":"daniel256","disabled":true}`).Code == http.StatusOK {
		t.Fatal("admin account was disabled")
	}
	disabled := postChat(app, "/api/v1/chat/admin/disable", admin.token, `{"username":"ada","disabled":true}`)
	if disabled.Code != http.StatusOK {
		t.Fatalf("disable %d %s", disabled.Code, disabled.Body.String())
	}
	refused := postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"still here"}`)
	if refused.Code == http.StatusOK || bytesIndex(refused.Body.Bytes(), "disabled") < 0 {
		t.Fatalf("disabled send %d %s", refused.Code, refused.Body.String())
	}
	status := postChat(app, "/api/v1/chat/status", ada.token, `{"text":"out today"}`)
	if status.Code == http.StatusOK || bytesIndex(status.Body.Bytes(), "disabled") < 0 {
		t.Fatalf("disabled status %d %s", status.Code, status.Body.String())
	}
	call := postChat(app, "/api/v1/chat/calls", ada.token, `{"thread":"`+thread.ID+`","sdp":"v=0\r\n"}`)
	if call.Code == http.StatusOK || bytesIndex(call.Body.Bytes(), "disabled") < 0 {
		t.Fatalf("disabled call %d %s", call.Code, call.Body.String())
	}
	when := time.Now().Add(2 * time.Hour).UnixMilli()
	scheduled := postChat(app, "/api/v1/chat/threads/"+thread.ID+"/schedule", ada.token, `{"text":"later","sendAt":`+strconv.FormatInt(when, 10)+`}`)
	if scheduled.Code == http.StatusOK || bytesIndex(scheduled.Body.Bytes(), "disabled") < 0 {
		t.Fatalf("disabled schedule %d %s", scheduled.Code, scheduled.Body.String())
	}
	if postChat(app, "/api/v1/chat/admin/disable", admin.token, `{"username":"ada","disabled":false}`).Code != http.StatusOK {
		t.Fatal("allow")
	}
	if postChat(app, "/api/v1/chat/threads/"+thread.ID, ada.token, `{"text":"back"}`).Code != http.StatusOK {
		t.Fatal("send after allow")
	}

	list := getChat(app, "/api/v1/chat/admin/users", admin.token)
	fullAda := sha256.Sum256([]byte(ada.token))
	fullAgain := sha256.Sum256([]byte(adaAgain.token))
	if bytesIndex(list.Body.Bytes(), hex.EncodeToString(fullAda[:])) >= 0 || bytesIndex(list.Body.Bytes(), hex.EncodeToString(fullAgain[:])) >= 0 {
		t.Fatal("session list included a token hash")
	}
	end := postChat(app, "/api/v1/chat/admin/sessions/end", admin.token, `{"username":"ada","id":"`+sessionPrefix(hex.EncodeToString(fullAda[:]))+`"}`)
	if end.Code != http.StatusOK {
		t.Fatalf("end session %d %s", end.Code, end.Body.String())
	}
	if getChat(app, "/api/v1/chat/me", ada.token).Code != http.StatusUnauthorized {
		t.Fatal("ended session still worked")
	}
	if getChat(app, "/api/v1/chat/me", adaAgain.token).Code != http.StatusOK {
		t.Fatal("the other session was ended too")
	}
	if postChat(app, "/api/v1/chat/admin/sessions/all", admin.token, `{"username":"ada"}`).Code != http.StatusOK {
		t.Fatal("sign out everywhere")
	}
	if getChat(app, "/api/v1/chat/me", adaAgain.token).Code != http.StatusUnauthorized {
		t.Fatal("a session survived sign out everywhere")
	}
	if getChat(app, "/api/v1/chat/admin/users", admin.token).Code != http.StatusOK {
		t.Fatal("signing someone else out ended the admin session")
	}
	if postChat(app, "/api/v1/chat/admin/sessions/all", admin.token, `{"username":"daniel256"}`).Code != http.StatusOK {
		t.Fatal("sign out other admin devices")
	}
	if getChat(app, "/api/v1/chat/admin/users", admin.token).Code != http.StatusOK {
		t.Fatal("the admin's own session was ended")
	}
}

func bytesIndex(body []byte, part string) int {
	return bytes.Index(body, []byte(part))
}
