package server

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

const (
	chatCallKeep = 50
	chatSDPMax   = 12000
	chatICEMax   = 2000
	// JSON escapes every newline, so the POST is larger than the SDP itself.
	chatCallBodyMax = chatSDPMax*4 + 1024
)

func (c *chatRoom) hasRecovery(ctx context.Context, userID string) bool {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, user := range c.data.Users {
		if user.ID == userID {
			return user.RecoveryHash != ""
		}
	}
	return false
}

func chatTokenHash(plain string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(plain)))
	return hex.EncodeToString(sum[:])
}

func sessionPrefix(hash string) string {
	if len(hash) <= 12 {
		return hash
	}
	return hash[:12]
}

func (s *Server) chatRecoveryRotate(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	code, err := s.chat.rotateRecovery(r.Context(), user.ID)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "recovery": code})
}

func (c *chatRoom) rotateRecovery(ctx context.Context, userID string) (string, error) {
	plain, hash, err := newRecovery()
	if err != nil {
		return "", err
	}
	c.ensure(ctx)
	c.mu.Lock()
	if c.joins == nil {
		c.joins = map[string][]time.Time{}
	}
	if !c.allowLocked(c.joins, "recovery:"+userID, 3) {
		c.mu.Unlock()
		return "", errs.RateLimited()
	}
	found := false
	for i := range c.data.Users {
		if c.data.Users[i].ID != userID {
			continue
		}
		c.data.Users[i].RecoveryHash = hash
		c.data.Users[i].RecoveryPlain = ""
		found = true
		break
	}
	c.mu.Unlock()
	if !found {
		return "", chatRejected("Sign in again.")
	}
	c.persist(ctx)
	return plain, nil
}

func (s *Server) chatRecover(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Username string `json:"username"`
		Code     string `json:"code"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter your username and recovery code.")
		return
	}
	user, token, code, err := s.chat.recover(r.Context(), body.Username, body.Code, body.Password)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success":  true,
		"token":    token,
		"user":     chatPublicUser(user, true),
		"recovery": code,
	})
}

func (c *chatRoom) recover(ctx context.Context, username, code, password string) (chatUser, string, string, error) {
	name, err := cleanChatUsername(username)
	if err != nil {
		return chatUser{}, "", "", err
	}
	clean, err := cleanChatPassword(password)
	if err != nil {
		return chatUser{}, "", "", err
	}
	hashed, err := newPasswordHash(clean)
	if err != nil {
		return chatUser{}, "", "", err
	}
	plain, tokenHash, err := newChatToken()
	if err != nil {
		return chatUser{}, "", "", err
	}
	nextCode, nextHash, err := newRecovery()
	if err != nil {
		return chatUser{}, "", "", err
	}
	c.ensure(ctx)
	c.mu.Lock()
	if c.joins == nil {
		c.joins = map[string][]time.Time{}
	}
	if !c.allowLocked(c.joins, "recover:"+name, 5) {
		c.mu.Unlock()
		return chatUser{}, "", "", errs.RateLimited()
	}
	index := -1
	for i := range c.data.Users {
		if c.data.Users[i].Username == name {
			index = i
			break
		}
	}
	if index < 0 || !recoveryMatches(c.data.Users[index].RecoveryHash, code) {
		c.mu.Unlock()
		return chatUser{}, "", "", chatRejected("That recovery code does not match.")
	}
	now := time.Now().UnixMilli()
	user := &c.data.Users[index]
	user.PasswordHash = hashed
	user.TokenHash = tokenHash
	user.Sessions = []string{tokenHash}
	user.Devices = []chatDevice{{Hash: tokenHash, Created: now, Seen: now}}
	user.RecoveryHash = nextHash
	user.RecoveryPlain = ""
	signed := *user
	c.mu.Unlock()
	c.persist(ctx)
	signed.TokenHash = ""
	signed.Sessions = nil
	signed.PasswordHash = ""
	signed.RecoveryHash = ""
	signed.Saved = nil
	signed.Devices = nil
	return signed, plain, nextCode, nil
}

type chatSessionView struct {
	ID       string `json:"id"`
	Name     string `json:"name,omitempty"`
	Platform string `json:"platform,omitempty"`
	Current  bool   `json:"current,omitempty"`
	Seen     int64  `json:"seen,omitempty"`
}

func (s *Server) chatSessionList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	views := s.chat.sessionViews(r.Context(), user.ID, chatTokenHash(r.Header.Get(chatTokenHeader)))
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "sessions": views})
}

func (c *chatRoom) sessionViews(ctx context.Context, userID, current string) []chatSessionView {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := range c.data.Users {
		if c.data.Users[i].ID != userID {
			continue
		}
		return sessionViewsLocked(&c.data.Users[i], current)
	}
	return []chatSessionView{}
}

func sessionViewsLocked(user *chatUser, current string) []chatSessionView {
	out := make([]chatSessionView, 0, len(user.Sessions))
	seen := map[string]bool{}
	add := func(hash string) {
		if hash == "" || seen[hash] {
			return
		}
		seen[hash] = true
		view := chatSessionView{ID: sessionPrefix(hash), Seen: 0}
		if subtle.ConstantTimeCompare([]byte(hash), []byte(current)) == 1 {
			view.Current = true
		}
		for _, device := range user.Devices {
			if subtle.ConstantTimeCompare([]byte(device.Hash), []byte(hash)) == 1 {
				view.Name = device.Name
				view.Platform = device.Platform
				view.Seen = device.Seen
				break
			}
		}
		out = append(out, view)
	}
	for _, hash := range user.Sessions {
		add(hash)
	}
	add(user.TokenHash)
	return out
}

func (s *Server) chatSessionTouch(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Name     string `json:"name"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That device could not be saved.")
		return
	}
	if err := s.chat.touchSession(r.Context(), user.ID, chatTokenHash(r.Header.Get(chatTokenHeader)), body.Name, body.Platform); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) touchSession(ctx context.Context, userID, hash, name, platform string) error {
	if hash == "" {
		return chatRejected("Sign in again.")
	}
	name = cleanInstallName(name)
	platform = strings.ToLower(strings.TrimSpace(platform))
	if platform != "" && !installPlatformOk(platform) {
		return chatRejected("That device could not be saved.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	index := -1
	for i := range c.data.Users {
		if c.data.Users[i].ID == userID {
			index = i
			break
		}
	}
	if index < 0 {
		c.mu.Unlock()
		return chatRejected("Sign in again.")
	}
	user := &c.data.Users[index]
	now := time.Now().UnixMilli()
	found := false
	for i := range user.Devices {
		if subtle.ConstantTimeCompare([]byte(user.Devices[i].Hash), []byte(hash)) != 1 {
			continue
		}
		user.Devices[i].Seen = now
		if name != "" {
			user.Devices[i].Name = name
		}
		if platform != "" {
			user.Devices[i].Platform = platform
		}
		found = true
		break
	}
	if !found {
		user.Devices = append(user.Devices, chatDevice{
			Hash: hash, Name: name, Platform: platform, Created: now, Seen: now,
		})
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatSessionEnd(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That device was not found.")
		return
	}
	if err := s.chat.endOtherSession(r.Context(), user.ID, chatTokenHash(r.Header.Get(chatTokenHeader)), body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) endOtherSession(ctx context.Context, userID, current, prefix string) error {
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if len(prefix) < 8 || len(prefix) > 64 || !hexPrefix(prefix) {
		return chatRejected("That device was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userPtrLocked(userID)
	if user == nil {
		c.mu.Unlock()
		return chatRejected("Sign in again.")
	}
	match := ""
	count := 0
	seen := map[string]bool{}
	consider := func(hash string) {
		if hash == "" || seen[hash] || !strings.HasPrefix(hash, prefix) {
			return
		}
		seen[hash] = true
		count++
		match = hash
	}
	for _, hash := range user.Sessions {
		consider(hash)
	}
	consider(user.TokenHash)
	if count == 0 {
		c.mu.Unlock()
		return chatRejected("That device was not found.")
	}
	if count > 1 {
		c.mu.Unlock()
		return chatRejected("Say which device.")
	}
	if subtle.ConstantTimeCompare([]byte(match), []byte(current)) == 1 {
		c.mu.Unlock()
		return chatRejected("This is the device you are using. Sign out of the others instead.")
	}
	dropSessionHash(user, match)
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatSessionOthers(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.endOtherSessions(r.Context(), user.ID, chatTokenHash(r.Header.Get(chatTokenHeader))); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) endOtherSessions(ctx context.Context, userID, current string) error {
	if current == "" {
		return chatRejected("Sign in again.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userPtrLocked(userID)
	if user == nil || !sessionMatches(*user, current) {
		c.mu.Unlock()
		return chatRejected("Sign in again.")
	}
	user.TokenHash = current
	user.Sessions = []string{current}
	kept := make([]chatDevice, 0, 1)
	now := time.Now().UnixMilli()
	for _, device := range user.Devices {
		if subtle.ConstantTimeCompare([]byte(device.Hash), []byte(current)) == 1 {
			device.Seen = now
			kept = append(kept, device)
		}
	}
	if len(kept) == 0 {
		kept = append(kept, chatDevice{Hash: current, Created: now, Seen: now})
	}
	user.Devices = kept
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) userPtrLocked(id string) *chatUser {
	for i := range c.data.Users {
		if c.data.Users[i].ID == id {
			return &c.data.Users[i]
		}
	}
	return nil
}

func dropSessionHash(user *chatUser, hash string) {
	next := make([]string, 0, len(user.Sessions))
	for _, cur := range user.Sessions {
		if subtle.ConstantTimeCompare([]byte(cur), []byte(hash)) == 1 {
			continue
		}
		next = append(next, cur)
	}
	if len(next) == 0 {
		user.Sessions = nil
	} else {
		user.Sessions = next
	}
	if subtle.ConstantTimeCompare([]byte(user.TokenHash), []byte(hash)) == 1 {
		user.TokenHash = ""
		if n := len(user.Sessions); n > 0 {
			user.TokenHash = user.Sessions[n-1]
		}
	}
	devices := make([]chatDevice, 0, len(user.Devices))
	for _, device := range user.Devices {
		if subtle.ConstantTimeCompare([]byte(device.Hash), []byte(hash)) == 1 {
			continue
		}
		devices = append(devices, device)
	}
	user.Devices = devices
}

func hexPrefix(value string) bool {
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return value != ""
}

func (s *Server) chatCallList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "calls": s.chat.callsFor(r.Context(), user.ID)})
}

func (s *Server) chatCallInvite(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Thread string `json:"thread"`
		SDP    string `json:"sdp"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, chatCallBodyMax)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "The call could not start.")
		return
	}
	call, err := s.chat.inviteCall(r.Context(), user, body.Thread, body.SDP)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "call": call})
}

func (s *Server) chatCallAnswer(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Accept bool   `json:"accept"`
		SDP    string `json:"sdp"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, chatCallBodyMax)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "The call could not be answered.")
		return
	}
	call, err := s.chat.answerCall(r.Context(), user, chi.URLParam(r, "id"), body.Accept, body.SDP)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "call": call})
}

func (s *Server) chatCallEnd(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	call, err := s.chat.endCall(r.Context(), user, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "call": call})
}

func (c *chatRoom) callsFor(ctx context.Context, userID string) []chatCall {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]chatCall, 0)
	for _, call := range c.data.Calls {
		if call.From != userID && call.To != userID {
			continue
		}
		out = append(out, viewCall(call, userID))
	}
	return out
}

func viewCall(call chatCall, viewer string) chatCall {
	out := call
	if call.State != "ringing" || viewer != call.To {
		out.Offer = ""
	}
	if call.State != "active" || viewer != call.From {
		out.Answer = ""
	}
	return out
}

func cleanSDP(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if strings.ContainsRune(raw, 0) {
		return "", chatRejected("The call could not start.")
	}
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	raw = strings.ReplaceAll(raw, "\r", "\n")
	raw = strings.Trim(raw, "\n")
	if !strings.HasPrefix(raw, "v=0") {
		return "", chatRejected("The call could not start.")
	}
	// libwebrtc rejects a description that does not end with CRLF.
	ready := strings.ReplaceAll(raw, "\n", "\r\n") + "\r\n"
	if len(ready) > chatSDPMax {
		return "", chatRejected("The call could not start.")
	}
	return ready, nil
}

func (c *chatRoom) inviteCall(ctx context.Context, user chatUser, threadID, sdp string) (chatCall, error) {
	sdp, err := cleanSDP(sdp)
	if err != nil {
		return chatCall{}, err
	}
	c.ensure(ctx)
	c.mu.Lock()
	if c.rings == nil {
		c.rings = map[string][]time.Time{}
	}
	if !c.allowLocked(c.rings, user.ID, 6) {
		c.mu.Unlock()
		return chatCall{}, errs.RateLimited()
	}
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) || len(thread.Members) > 0 {
		c.mu.Unlock()
		return chatCall{}, chatRejected("Audio calls are between two people.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatCall{}, err
	}
	if c.holdsRequestLocked(thread) {
		c.mu.Unlock()
		return chatCall{}, chatRejected("Wait until they accept your message.")
	}
	other := thread.B
	if other == user.ID {
		other = thread.A
	}
	for _, call := range c.data.Calls {
		if call.State != "ringing" && call.State != "active" {
			continue
		}
		if call.From == user.ID || call.To == user.ID || call.From == other || call.To == other {
			c.mu.Unlock()
			return chatCall{}, chatRejected("There is already a call.")
		}
	}
	call := chatCall{
		ID: newChatID("c"), Thread: thread.ID, From: user.ID, To: other,
		FromName: user.Username, State: "ringing", At: time.Now().UnixMilli(), Offer: sdp,
	}
	c.data.Calls = append(c.data.Calls, call)
	if len(c.data.Calls) > chatCallKeep {
		c.data.Calls = append([]chatCall(nil), c.data.Calls[len(c.data.Calls)-chatCallKeep:]...)
	}
	c.mu.Unlock()
	c.persist(ctx)
	c.pushCall(call)
	return viewCall(call, user.ID), nil
}

func (c *chatRoom) answerCall(ctx context.Context, user chatUser, callID string, accept bool, sdp string) (chatCall, error) {
	sdp, err := cleanSDP(sdp)
	if err != nil {
		return chatCall{}, err
	}
	c.ensure(ctx)
	now := time.Now().UnixMilli()
	c.mu.Lock()
	call := c.callPtrLocked(callID)
	if call == nil || (call.From != user.ID && call.To != user.ID) {
		c.mu.Unlock()
		return chatCall{}, chatRejected("That call was not found.")
	}
	if call.To != user.ID {
		c.mu.Unlock()
		return chatCall{}, chatRejected("Only the other person can answer.")
	}
	if call.State != "ringing" {
		snap := viewCall(*call, user.ID)
		c.mu.Unlock()
		return snap, nil
	}
	state := "active"
	if !accept {
		state = "declined"
	}
	call.State = state
	call.Ended = now
	if accept {
		call.Answered = now
		call.Ended = 0
		call.Answer = sdp
	} else {
		call.Offer = ""
	}
	snap := *call
	c.mu.Unlock()
	c.persist(ctx)
	if !accept {
		c.noteCall(ctx, snap, snap.To, "Declined audio call", "declined", 0)
	}
	c.pushCall(snap)
	return viewCall(snap, user.ID), nil
}

func (c *chatRoom) endCall(ctx context.Context, user chatUser, callID string) (chatCall, error) {
	c.ensure(ctx)
	now := time.Now().UnixMilli()
	c.mu.Lock()
	call := c.callPtrLocked(callID)
	if call == nil || (call.From != user.ID && call.To != user.ID) {
		c.mu.Unlock()
		return chatCall{}, chatRejected("That call was not found.")
	}
	if call.State != "ringing" && call.State != "active" {
		snap := viewCall(*call, user.ID)
		c.mu.Unlock()
		return snap, nil
	}
	state := "ended"
	text := "Audio call"
	author := user.ID
	dur := 0
	if call.State == "ringing" && user.ID == call.From {
		state = "cancelled"
		text = "Cancelled audio call"
		author = call.From
	} else if call.State == "ringing" {
		state = "declined"
		text = "Declined audio call"
		author = call.To
	} else if call.Answered > 0 && now >= call.Answered {
		dur = int((now - call.Answered) / 1000)
	}
	call.State = state
	call.Ended = now
	call.Dur = dur
	call.Offer = ""
	call.Answer = ""
	snap := *call
	c.mu.Unlock()
	c.persist(ctx)
	c.noteCall(ctx, snap, author, text, state, dur)
	c.pushCall(snap)
	return viewCall(snap, user.ID), nil
}

func (c *chatRoom) missStaleCalls(ctx context.Context) {
	c.ensure(ctx)
	cutoff := time.Now().Add(-chatCallRingFor).UnixMilli()
	now := time.Now().UnixMilli()
	c.mu.Lock()
	due := make([]chatCall, 0)
	for i := range c.data.Calls {
		call := &c.data.Calls[i]
		if call.State != "ringing" || call.At > cutoff {
			continue
		}
		call.State = "missed"
		call.Ended = now
		call.Offer = ""
		call.Answer = ""
		due = append(due, *call)
	}
	c.mu.Unlock()
	if len(due) == 0 {
		return
	}
	c.persist(ctx)
	for _, call := range due {
		c.noteCall(ctx, call, call.From, "Missed audio call", "missed", 0)
		c.pushCall(call)
	}
}

func (c *chatRoom) noteCall(ctx context.Context, call chatCall, authorID, text, kind string, ms int) {
	if text == "" || call.Thread == "" || authorID == "" {
		return
	}
	c.mu.Lock()
	author, ok := c.userLocked(authorID)
	c.mu.Unlock()
	if !ok {
		return
	}
	_, _ = c.deliver(ctx, author, call.Thread, text, 0, chatExtra{Call: kind, CallMs: ms})
}

func (c *chatRoom) callPtrLocked(id string) *chatCall {
	id = strings.TrimSpace(id)
	if id == "" {
		return nil
	}
	for i := range c.data.Calls {
		if c.data.Calls[i].ID == id {
			return &c.data.Calls[i]
		}
	}
	return nil
}

func (c *chatRoom) pushPendingCalls(user chatUser) {
	c.mu.Lock()
	pending := make([]chatCall, 0)
	for _, call := range c.data.Calls {
		if call.State != "ringing" && call.State != "active" {
			continue
		}
		if call.From == user.ID || call.To == user.ID {
			pending = append(pending, call)
		}
	}
	c.mu.Unlock()
	for _, call := range pending {
		c.pushCallTo(user.ID, call)
	}
}

func (c *chatRoom) pushCall(call chatCall) {
	if c == nil || c.live == nil {
		return
	}
	c.pushCallTo(call.From, call)
	if call.To != call.From {
		c.pushCallTo(call.To, call)
	}
}

func (c *chatRoom) pushCallTo(userID string, call chatCall) {
	if c.live == nil || userID == "" {
		return
	}
	view := viewCall(call, userID)
	payload := map[string]any{
		"type":   "call",
		"id":     view.ID,
		"thread": view.Thread,
		"state":  view.State,
		"from":   view.FromName,
		"fromId": view.From,
		"to":     view.To,
		"at":     view.At,
	}
	if view.Answered > 0 {
		payload["answered"] = view.Answered
	}
	if view.Dur > 0 {
		payload["dur"] = view.Dur
	}
	if view.Offer != "" {
		payload["offer"] = view.Offer
	}
	if view.Answer != "" {
		payload["answer"] = view.Answer
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return
	}
	c.live.sendWait(userID, body)
}

func (c *chatRoom) relayCallIce(user chatUser, callID, candidate string) {
	candidate = strings.TrimSpace(candidate)
	if callID == "" || candidate == "" || len(candidate) > chatICEMax || strings.ContainsRune(candidate, 0) {
		return
	}
	c.mu.Lock()
	call := c.callPtrLocked(callID)
	if call == nil || (call.State != "ringing" && call.State != "active") || (user.ID != call.From && user.ID != call.To) {
		c.mu.Unlock()
		return
	}
	other := call.To
	if user.ID == call.To {
		other = call.From
	}
	id := call.ID
	c.mu.Unlock()
	body, err := json.Marshal(map[string]any{"type": "call-ice", "call": id, "candidate": candidate})
	if err != nil || c.live == nil {
		return
	}
	c.live.sendWait(other, body)
}

func (c *chatRoom) relayCallSDP(user chatUser, callID, sdp string) {
	sdp, err := cleanSDP(sdp)
	if err != nil || sdp == "" || callID == "" {
		return
	}
	c.mu.Lock()
	call := c.callPtrLocked(callID)
	if call == nil || (call.State != "ringing" && call.State != "active") || (user.ID != call.From && user.ID != call.To) {
		c.mu.Unlock()
		return
	}
	if user.ID == call.From {
		call.Offer = sdp
	} else {
		call.Answer = sdp
	}
	other := call.To
	if user.ID == call.To {
		other = call.From
	}
	id := call.ID
	c.mu.Unlock()
	c.persist(context.Background())
	if c.live == nil {
		return
	}
	body, err := json.Marshal(map[string]any{"type": "call-sdp", "call": id, "sdp": sdp})
	if err != nil {
		return
	}
	c.live.sendWait(other, body)
}

func (c *chatRoom) relayCallHold(user chatUser, callID string, on bool) {
	if c == nil || c.live == nil || callID == "" {
		return
	}
	c.mu.Lock()
	call := c.callPtrLocked(callID)
	if call == nil || call.State != "active" || (user.ID != call.From && user.ID != call.To) {
		c.mu.Unlock()
		return
	}
	other := call.To
	if user.ID == call.To {
		other = call.From
	}
	id := call.ID
	c.mu.Unlock()
	body, err := json.Marshal(map[string]any{"type": "call-hold", "call": id, "on": on})
	if err != nil {
		return
	}
	c.live.sendWait(other, body)
}
