package server

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"
)

func TestAdminRolesEnforcedOnServer(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	owner := registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`)
	mod := registerChat(t, app, `{"email":"mod1@example.com","username":"mod1"}`)
	sup := registerChat(t, app, `{"email":"sup1@example.com","username":"sup1"}`)
	adm := registerChat(t, app, `{"email":"adm1@example.com","username":"adm1"}`)
	ada := registerChat(t, app, `{"email":"ada1@example.com","username":"ada1"}`)

	setRole := func(token, username, role string) int {
		return postChat(app, "/api/v1/chat/admin/role", token, `{"username":"`+username+`","role":"`+role+`"}`).Code
	}
	// A normal account sees nothing and cannot hand out roles.
	if code := getChat(app, "/api/v1/chat/admin/users", ada.token).Code; code != http.StatusForbidden {
		t.Fatalf("plain user list %d", code)
	}
	if code := setRole(ada.token, "ada1", "admin"); code != http.StatusForbidden {
		t.Fatalf("plain user set role %d", code)
	}
	for name, role := range map[string]string{"mod1": "moderator", "sup1": "support", "adm1": "admin"} {
		if code := setRole(owner.token, name, role); code != http.StatusOK {
			t.Fatalf("owner set %s %d", name, code)
		}
	}
	if code := setRole(owner.token, "ada1", "superuser"); code == http.StatusOK {
		t.Fatal("unknown role accepted")
	}
	// Only the owner manages roles, and the owner cannot be demoted.
	if code := setRole(adm.token, "ada1", "support"); code != http.StatusForbidden {
		t.Fatalf("admin set role %d", code)
	}
	if code := setRole(owner.token, "daniel256", "support"); code == http.StatusOK {
		t.Fatal("owner role changed")
	}

	// Support sees people with contact details but no reports or groups.
	var supList struct {
		Role        string   `json:"role"`
		Permissions []string `json:"permissions"`
		Users       []struct {
			Username string `json:"username"`
			Email    string `json:"email"`
			Role     string `json:"role"`
		} `json:"users"`
		Reports json.RawMessage `json:"reports"`
		Groups  json.RawMessage `json:"groups"`
		Audit   json.RawMessage `json:"audit"`
	}
	res := getChat(app, "/api/v1/chat/admin/users", sup.token)
	if res.Code != http.StatusOK {
		t.Fatalf("support list %d", res.Code)
	}
	if err := json.Unmarshal(res.Body.Bytes(), &supList); err != nil {
		t.Fatal(err)
	}
	if supList.Role != "support" || supList.Reports != nil || supList.Groups != nil || supList.Audit != nil || len(supList.Users) == 0 {
		t.Fatalf("support list %s", res.Body.String())
	}
	// Moderators see people but not their phone or email.
	res = getChat(app, "/api/v1/chat/admin/users", mod.token)
	if res.Code != http.StatusOK || bytesIndex(res.Body.Bytes(), "ada1@example.com") >= 0 {
		t.Fatalf("moderator list %d %s", res.Code, res.Body.String())
	}

	disable := func(token, username string, on bool) int {
		v := "false"
		if on {
			v = "true"
		}
		return postChat(app, "/api/v1/chat/admin/disable", token, `{"username":"`+username+`","disabled":`+v+`}`).Code
	}
	if code := disable(sup.token, "ada1", true); code != http.StatusForbidden {
		t.Fatalf("support disable %d", code)
	}
	if code := postChat(app, "/api/v1/chat/admin/sessions/all", mod.token, `{"username":"ada1"}`).Code; code != http.StatusForbidden {
		t.Fatalf("moderator end sessions %d", code)
	}
	// Nobody can act on an equal or higher role, and the owner stays open.
	if code := disable(mod.token, "adm1", true); code == http.StatusOK {
		t.Fatal("moderator disabled an admin")
	}
	if code := disable(adm.token, "daniel256", true); code == http.StatusOK {
		t.Fatal("owner disabled")
	}
	if code := postChat(app, "/api/v1/chat/admin/sessions/all", adm.token, `{"username":"daniel256"}`).Code; code == http.StatusOK {
		t.Fatal("admin ended owner sessions")
	}
	if code := disable(mod.token, "ada1", true); code != http.StatusOK {
		t.Fatalf("moderator disable %d", code)
	}
	if code := disable(mod.token, "ada1", false); code != http.StatusOK {
		t.Fatalf("moderator enable %d", code)
	}
	if code := postChat(app, "/api/v1/chat/admin/sessions/all", sup.token, `{"username":"ada1"}`).Code; code != http.StatusOK {
		t.Fatalf("support end sessions %d", code)
	}

	// The owner's audit log records who did what, newest first.
	var audit struct {
		Audit []chatAudit `json:"audit"`
	}
	res = getChat(app, "/api/v1/chat/admin/users", owner.token)
	if err := json.Unmarshal(res.Body.Bytes(), &audit); err != nil || len(audit.Audit) < 6 {
		t.Fatalf("audit %s", res.Body.String())
	}
	if audit.Audit[0].Action != "session.end_all" || audit.Audit[0].Actor != "sup1" || audit.Audit[0].Target != "ada1" {
		t.Fatalf("audit order %+v", audit.Audit[0])
	}
	// Removing the role takes the console away.
	if code := setRole(owner.token, "sup1", ""); code != http.StatusOK {
		t.Fatalf("clear role %d", code)
	}
	if code := getChat(app, "/api/v1/chat/admin/users", sup.token).Code; code != http.StatusForbidden {
		t.Fatalf("former support list %d", code)
	}
}

func TestAdminReportsAndMessageRemoval(t *testing.T) {
	app := testApp(t)
	app.chat.file = filepath.Join(t.TempDir(), "accounts.json")
	owner := registerChat(t, app, `{"phone":"+256 703 487 378","username":"@daniel256"}`)
	ada := registerChat(t, app, `{"email":"ada2@example.com","username":"ada2"}`)
	ben := registerChat(t, app, `{"email":"ben2@example.com","username":"ben2"}`)
	sup := registerChat(t, app, `{"email":"sup2@example.com","username":"sup2"}`)
	if postChat(app, "/api/v1/chat/admin/role", owner.token, `{"username":"sup2","role":"support"}`).Code != http.StatusOK {
		t.Fatal("role")
	}
	opened := postChat(app, "/api/v1/chat/threads", ada.token, `{"username":"ben2"}`)
	var dm struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(opened.Body.Bytes(), &dm); err != nil || dm.ID == "" {
		t.Fatalf("dm %s", opened.Body.String())
	}
	if postChat(app, "/api/v1/chat/threads/"+dm.ID, ada.token, `{"text":"buy my spam"}`).Code != http.StatusOK {
		t.Fatal("post")
	}
	if postChat(app, "/api/v1/chat/report", ben.token, `{"username":"ada2","reason":"spam"}`).Code != http.StatusOK {
		t.Fatal("report")
	}
	if code := getChat(app, "/api/v1/chat/admin/messages?username=ada2", sup.token).Code; code != http.StatusForbidden {
		t.Fatalf("support messages %d", code)
	}
	res := getChat(app, "/api/v1/chat/admin/messages?username=ada2", owner.token)
	var msgs struct {
		Messages []chatAdminMessage `json:"messages"`
	}
	if err := json.Unmarshal(res.Body.Bytes(), &msgs); err != nil || len(msgs.Messages) != 1 || msgs.Messages[0].Text != "buy my spam" {
		t.Fatalf("messages %s", res.Body.String())
	}
	m := msgs.Messages[0]
	body := `{"thread":"` + m.Thread + `","id":` + itoa(m.ID) + `}`
	if code := postChat(app, "/api/v1/chat/admin/messages/remove", sup.token, body).Code; code != http.StatusForbidden {
		t.Fatalf("support remove %d", code)
	}
	if code := postChat(app, "/api/v1/chat/admin/messages/remove", owner.token, body).Code; code != http.StatusOK {
		t.Fatalf("owner remove %d", code)
	}
	res = getChat(app, "/api/v1/chat/admin/messages?username=ada2", owner.token)
	if bytesIndex(res.Body.Bytes(), "buy my spam") >= 0 {
		t.Fatal("message still there")
	}
	var list struct {
		Reports []chatAdminReport `json:"reports"`
	}
	res = getChat(app, "/api/v1/chat/admin/users", owner.token)
	if err := json.Unmarshal(res.Body.Bytes(), &list); err != nil || len(list.Reports) != 1 {
		t.Fatalf("reports %s", res.Body.String())
	}
	if code := postChat(app, "/api/v1/chat/admin/reports/dismiss", sup.token, `{"id":"`+list.Reports[0].ID+`"}`).Code; code != http.StatusForbidden {
		t.Fatalf("support dismiss %d", code)
	}
	if code := postChat(app, "/api/v1/chat/admin/reports/dismiss", owner.token, `{"id":"`+list.Reports[0].ID+`"}`).Code; code != http.StatusOK {
		t.Fatalf("dismiss %d", code)
	}
	res = getChat(app, "/api/v1/chat/admin/users", owner.token)
	list.Reports = nil
	_ = json.Unmarshal(res.Body.Bytes(), &list)
	if len(list.Reports) != 0 {
		t.Fatalf("report not dismissed %s", res.Body.String())
	}
}

func TestChatPermissionModel(t *testing.T) {
	owner := chatUser{Username: chatAdminUsername, Phone: chatAdminPhone, Role: "support"}
	if chatRole(owner) != roleOwner || len(chatPermissionList(owner)) != len(chatAllPermissions) {
		t.Fatal("owner must have every permission")
	}
	admin := chatUser{Username: "a", Role: roleAdmin}
	if chatCan(admin, permRolesManage) || !chatCan(admin, permAuditView) {
		t.Fatal("admin permissions")
	}
	mod := chatUser{Username: "m", Role: roleModerator}
	if chatCan(mod, permSessionsEnd) || chatCan(mod, permUsersContact) || !chatCan(mod, permMessagesRemove) {
		t.Fatal("moderator permissions")
	}
	sup := chatUser{Username: "s", Role: roleSupport}
	if chatCan(sup, permUsersDisable) || chatCan(sup, permReportsView) || !chatCan(sup, permSessionsEnd) {
		t.Fatal("support permissions")
	}
	bogus := chatUser{Username: "b", Role: "root"}
	if chatRole(bogus) != "" || chatCan(bogus, permUsersView) {
		t.Fatal("unknown role must have nothing")
	}
	if !chatOutranks(admin, mod) || chatOutranks(mod, admin) || chatOutranks(admin, chatUser{Role: roleAdmin}) || chatOutranks(admin, owner) {
		t.Fatal("rank order")
	}
}
