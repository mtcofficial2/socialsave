package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

// Staff roles. The owner is the fixed @daniel256 account and always has every
// permission; the others are given by the owner and stored on the account.
const (
	roleOwner     = "owner"
	roleAdmin     = "admin"
	roleModerator = "moderator"
	roleSupport   = "support"
)

// Permissions checked on the server for every Monitor request.
const (
	permUsersView      = "users.view"
	permUsersContact   = "users.contact"
	permUsersDisable   = "users.disable"
	permSessionsEnd    = "sessions.end"
	permDevicesView    = "devices.view"
	permGroupsView     = "groups.view"
	permReportsView    = "reports.view"
	permReportsDismiss = "reports.dismiss"
	permMessagesRemove = "messages.remove"
	permRolesManage    = "roles.manage"
	permAuditView      = "audit.view"
)

var chatAllPermissions = []string{
	permUsersView, permUsersContact, permUsersDisable, permSessionsEnd,
	permDevicesView, permGroupsView, permReportsView, permReportsDismiss,
	permMessagesRemove, permRolesManage, permAuditView,
}

var chatRolePermissions = map[string][]string{
	roleAdmin: {
		permUsersView, permUsersContact, permUsersDisable, permSessionsEnd,
		permDevicesView, permGroupsView, permReportsView, permReportsDismiss,
		permMessagesRemove, permAuditView,
	},
	roleModerator: {
		permUsersView, permUsersDisable, permGroupsView, permReportsView,
		permReportsDismiss, permMessagesRemove,
	},
	roleSupport: {
		permUsersView, permUsersContact, permSessionsEnd, permDevicesView,
	},
}

const chatAuditKeep = 300

type chatAudit struct {
	At     int64  `json:"at"`
	Actor  string `json:"actor"`
	Action string `json:"action"`
	Target string `json:"target,omitempty"`
	Detail string `json:"detail,omitempty"`
}

// chatRole is the account's staff role, or "" for a normal account.
func chatRole(user chatUser) string {
	if chatIsAdmin(user) {
		return roleOwner
	}
	switch user.Role {
	case roleAdmin, roleModerator, roleSupport:
		return user.Role
	}
	return ""
}

func chatRoleRank(role string) int {
	switch role {
	case roleOwner:
		return 4
	case roleAdmin:
		return 3
	case roleModerator:
		return 2
	case roleSupport:
		return 1
	}
	return 0
}

// chatOutranks is true when actor may act on target: a higher role only.
func chatOutranks(actor, target chatUser) bool {
	return chatRoleRank(chatRole(actor)) > chatRoleRank(chatRole(target))
}

func chatCan(user chatUser, perm string) bool {
	role := chatRole(user)
	if role == roleOwner {
		return true
	}
	for _, p := range chatRolePermissions[role] {
		if p == perm {
			return true
		}
	}
	return false
}

func chatPermissionList(user chatUser) []string {
	out := make([]string, 0, len(chatAllPermissions))
	for _, p := range chatAllPermissions {
		if chatCan(user, p) {
			out = append(out, p)
		}
	}
	return out
}

func chatIsStaff(user chatUser) bool { return chatRole(user) != "" }

// auditLocked records a staff action. Call with c.mu held.
func (c *chatRoom) auditLocked(actor chatUser, action, target, detail string) {
	if len(detail) > 160 {
		detail = detail[:160]
	}
	c.data.Audit = append(c.data.Audit, chatAudit{
		At:     time.Now().UnixMilli(),
		Actor:  actor.Username,
		Action: action,
		Target: target,
		Detail: detail,
	})
	if len(c.data.Audit) > chatAuditKeep {
		c.data.Audit = append([]chatAudit(nil), c.data.Audit[len(c.data.Audit)-chatAuditKeep:]...)
	}
}

func (c *chatRoom) audit(ctx context.Context, actor chatUser, action, target, detail string) {
	c.mu.Lock()
	c.auditLocked(actor, action, target, detail)
	c.mu.Unlock()
	c.persist(ctx)
}

func (c *chatRoom) adminAudit(ctx context.Context) []chatAudit {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]chatAudit, len(c.data.Audit))
	for i := range c.data.Audit {
		out[len(out)-1-i] = c.data.Audit[i]
	}
	return out
}

// chatStaffActor lets the request through only when the signed-in account
// has perm. Everyone else gets 403, whatever the app shows.
func (s *Server) chatStaffActor(w http.ResponseWriter, r *http.Request, perm string) (chatUser, bool) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return chatUser{}, false
	}
	if !chatCan(user, perm) {
		writeChatError(w, http.StatusForbidden, "You do not have permission to do that.")
		return chatUser{}, false
	}
	return user, true
}

func (c *chatRoom) setRole(ctx context.Context, actor chatUser, username, role string) error {
	if !chatCan(actor, permRolesManage) {
		return chatRejected("You do not have permission to do that.")
	}
	role = strings.ToLower(strings.TrimSpace(role))
	switch role {
	case "", roleAdmin, roleModerator, roleSupport:
	default:
		return chatRejected("That role does not exist.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return err
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userByNameLocked(name)
	if user == nil {
		c.mu.Unlock()
		return chatRejected("No Social Save user has that username.")
	}
	if chatIsAdmin(*user) {
		c.mu.Unlock()
		return chatRejected("The owner account keeps every permission.")
	}
	if user.Role == role {
		c.mu.Unlock()
		return nil
	}
	user.Role = role
	label := role
	if label == "" {
		label = "none"
	}
	c.auditLocked(actor, "role", name, label)
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) dismissReport(ctx context.Context, actor chatUser, id string) error {
	if !chatCan(actor, permReportsDismiss) {
		return chatRejected("You do not have permission to do that.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	index := -1
	for i := range c.data.Reports {
		if c.data.Reports[i].ID == id {
			index = i
			break
		}
	}
	if index < 0 {
		c.mu.Unlock()
		return chatRejected("That report was not found.")
	}
	target := usernameLocked(c, c.data.Reports[index].Target)
	c.data.Reports = append(c.data.Reports[:index], c.data.Reports[index+1:]...)
	c.auditLocked(actor, "report.dismiss", target, id)
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

type chatAdminMessage struct {
	Thread string `json:"thread"`
	ID     int64  `json:"id"`
	Text   string `json:"text,omitempty"`
	Kind   string `json:"kind"`
	At     int64  `json:"at"`
	Group  string `json:"group,omitempty"`
}

// adminUserMessages lists the newest messages one account sent, for review
// after a report.
func (c *chatRoom) adminUserMessages(ctx context.Context, actor chatUser, username string) ([]chatAdminMessage, error) {
	if !chatCan(actor, permReportsView) {
		return nil, chatRejected("You do not have permission to do that.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return nil, err
	}
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	user := c.userByNameLocked(name)
	if user == nil {
		return nil, chatRejected("No Social Save user has that username.")
	}
	rows := make([]chatAdminMessage, 0)
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		for _, msg := range thread.Messages {
			if msg.From != user.ID {
				continue
			}
			kind := "text"
			switch {
			case msg.Voice != "":
				kind = "voice"
			case msg.Photo != "":
				kind = "photo"
			case msg.Song != "":
				kind = "song"
			case msg.Poll != nil:
				kind = "poll"
			}
			text := msg.Text
			if len(text) > 280 {
				text = text[:280]
			}
			rows = append(rows, chatAdminMessage{Thread: thread.ID, ID: msg.ID, Text: text, Kind: kind, At: msg.At, Group: thread.Title})
		}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].At > rows[j].At })
	if len(rows) > 50 {
		rows = rows[:50]
	}
	return rows, nil
}

func (c *chatRoom) adminRemoveMessage(ctx context.Context, actor chatUser, threadID string, id int64) error {
	if !chatCan(actor, permMessagesRemove) {
		return chatRejected("You do not have permission to do that.")
	}
	if id < 1 {
		return chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	index := -1
	for i := range thread.Messages {
		if thread.Messages[i].ID == id {
			index = i
			break
		}
	}
	if index < 0 {
		c.mu.Unlock()
		return chatRejected("That message was not found.")
	}
	author, _ := c.userLocked(thread.Messages[index].From)
	if author.ID != "" && author.ID != actor.ID && !chatOutranks(actor, author) {
		c.mu.Unlock()
		return chatRejected("You cannot remove that person's messages.")
	}
	thread.Messages = append(thread.Messages[:index], thread.Messages[index+1:]...)
	thread.Removed = rememberRemoved(thread.Removed, id)
	thread.Pinned = dropPinned(thread.Pinned, id)
	a, b := thread.A, thread.B
	c.auditLocked(actor, "message.remove", author.Username, threadID)
	c.mu.Unlock()
	c.persist(ctx)
	c.announceRemoved(a, b, threadID, id)
	return nil
}

func (s *Server) chatAdminRole(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatStaffActor(w, r, permRolesManage)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		Role     string `json:"role"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That role could not be changed.")
		return
	}
	if err := s.chat.setRole(r.Context(), actor, body.Username, body.Role); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatAdminReportDismiss(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatStaffActor(w, r, permReportsDismiss)
	if !ok {
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That report was not found.")
		return
	}
	if err := s.chat.dismissReport(r.Context(), actor, body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatAdminMessages(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatStaffActor(w, r, permReportsView)
	if !ok {
		return
	}
	rows, err := s.chat.adminUserMessages(r.Context(), actor, r.URL.Query().Get("username"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "messages": rows})
}

func (s *Server) chatAdminMessageRemove(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatStaffActor(w, r, permMessagesRemove)
	if !ok {
		return
	}
	var body struct {
		Thread string `json:"thread"`
		ID     int64  `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That message was not found.")
		return
	}
	if err := s.chat.adminRemoveMessage(r.Context(), actor, body.Thread, body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
