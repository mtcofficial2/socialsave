package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/models"
	"github.com/aviation256444-boop/socialsave/backend/internal/storage"
)

const (
	chatKeep        = 200
	chatTextMax     = 400
	chatPostRate    = 20
	chatJoinRate    = 8
	chatKey         = "chat/accounts.json"
	chatTokenHeader = "X-Chat-Token"
)

// chatBlob is optional durable storage. The Render disk is wiped when the
// service sleeps, so accounts and chats are also written to object storage.
type chatBlob interface {
	PutBytes(ctx context.Context, key string, body []byte) error
	GetBytes(ctx context.Context, key string) ([]byte, error)
}

type chatUser struct {
	ID        string `json:"id"`
	Phone     string `json:"phone,omitempty"`
	Email     string `json:"email,omitempty"`
	Username  string `json:"username"`
	TokenHash string `json:"tokenHash"`
	Created   int64  `json:"created"`
}

type chatMessage struct {
	ID    int64    `json:"id"`
	From  string   `json:"from"`
	Name  string   `json:"name"`
	Text  string   `json:"text"`
	Links []string `json:"links,omitempty"`
	At    int64    `json:"at"`
}

type chatThread struct {
	ID       string        `json:"id"`
	A        string        `json:"a"`
	B        string        `json:"b"`
	Next     int64         `json:"next"`
	Messages []chatMessage `json:"messages"`
}

type chatData struct {
	Users   []chatUser   `json:"users"`
	Threads []chatThread `json:"threads"`
}

type chatInboxItem struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	LastText string `json:"lastText,omitempty"`
	LastAt   int64  `json:"lastAt,omitempty"`
}

type chatRoom struct {
	mu     sync.Mutex
	saveMu sync.Mutex
	load   sync.Once
	data   chatData
	posts  map[string][]time.Time
	joins  map[string][]time.Time
	last   map[string]string
	blob   chatBlob
	file   string
}

func newChatRoom(up storage.Uploader) *chatRoom {
	var blob chatBlob
	if value, ok := up.(chatBlob); ok {
		blob = value
	}
	return &chatRoom{
		posts: map[string][]time.Time{},
		joins: map[string][]time.Time{},
		last:  map[string]string{},
		blob:  blob,
		file:  filepath.Join(os.TempDir(), "socialsave-chat-accounts.json"),
	}
}

func (c *chatRoom) register(ctx context.Context, ip, phone, email, username string) (chatUser, string, error) {
	c.ensure(ctx)
	phone, email, username, err := cleanAccount(phone, email, username)
	if err != nil {
		return chatUser{}, "", err
	}
	plain, hash, err := newChatToken()
	if err != nil {
		return chatUser{}, "", err
	}
	c.mu.Lock()
	if !c.allowLocked(c.joins, ip, chatJoinRate) {
		c.mu.Unlock()
		return chatUser{}, "", errs.RateLimited()
	}
	for _, user := range c.data.Users {
		if phone != "" && user.Phone == phone {
			c.mu.Unlock()
			return chatUser{}, "", chatRejected("That phone number already has a Social Save username.")
		}
		if email != "" && user.Email == email {
			c.mu.Unlock()
			return chatUser{}, "", chatRejected("That email already has a Social Save username.")
		}
		if user.Username == username {
			c.mu.Unlock()
			return chatUser{}, "", chatRejected("That username is taken.")
		}
	}
	user := chatUser{
		ID:        newChatID("u"),
		Phone:     phone,
		Email:     email,
		Username:  username,
		TokenHash: hash,
		Created:   time.Now().UnixMilli(),
	}
	c.data.Users = append(c.data.Users, user)
	c.mu.Unlock()
	c.persist(ctx)
	user.TokenHash = ""
	return user, plain, nil
}

func (c *chatRoom) userByToken(ctx context.Context, plain string) (chatUser, bool) {
	c.ensure(ctx)
	sum := sha256.Sum256([]byte(strings.TrimSpace(plain)))
	want := hex.EncodeToString(sum[:])
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, user := range c.data.Users {
		if subtle.ConstantTimeCompare([]byte(user.TokenHash), []byte(want)) == 1 {
			user.TokenHash = ""
			return user, true
		}
	}
	return chatUser{}, false
}

func (c *chatRoom) lookup(ctx context.Context, username string) (string, bool) {
	c.ensure(ctx)
	name := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, user := range c.data.Users {
		if user.Username == name {
			return user.Username, true
		}
	}
	return "", false
}

func (c *chatRoom) inbox(ctx context.Context, userID string) []chatInboxItem {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]chatInboxItem, 0)
	for _, thread := range c.data.Threads {
		otherID := ""
		switch userID {
		case thread.A:
			otherID = thread.B
		case thread.B:
			otherID = thread.A
		default:
			continue
		}
		item := chatInboxItem{ID: thread.ID, Username: c.usernameLocked(otherID)}
		if n := len(thread.Messages); n > 0 {
			last := thread.Messages[n-1]
			item.LastText = last.Text
			item.LastAt = last.At
		}
		out = append(out, item)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].LastAt > out[j-1].LastAt; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func (c *chatRoom) open(ctx context.Context, userID, username string) (chatThread, string, error) {
	c.ensure(ctx)
	name := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	c.mu.Lock()
	var other chatUser
	found := false
	for _, user := range c.data.Users {
		if user.Username == name {
			other = user
			found = true
			break
		}
	}
	if !found {
		c.mu.Unlock()
		return chatThread{}, "", chatRejected("No Social Save user has that username.")
	}
	if other.ID == userID {
		c.mu.Unlock()
		return chatThread{}, "", chatRejected("That is your own username.")
	}
	for _, thread := range c.data.Threads {
		if threadPairs(thread, userID, other.ID) {
			c.mu.Unlock()
			return thread, other.Username, nil
		}
	}
	thread := chatThread{ID: newChatID("t"), A: userID, B: other.ID, Next: 1}
	c.data.Threads = append(c.data.Threads, thread)
	c.mu.Unlock()
	c.persist(ctx)
	return thread, other.Username, nil
}

func (c *chatRoom) since(ctx context.Context, userID, threadID string, after int64) ([]chatMessage, error) {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != userID && thread.B != userID) {
		return nil, chatRejected("That chat was not found.")
	}
	out := make([]chatMessage, 0)
	for _, item := range thread.Messages {
		if item.ID > after {
			out = append(out, item)
		}
	}
	return out, nil
}

func (c *chatRoom) post(ctx context.Context, user chatUser, threadID, text string) (chatMessage, error) {
	c.ensure(ctx)
	clean, err := cleanChatText(text)
	if err != nil {
		return chatMessage{}, err
	}
	c.mu.Lock()
	if !c.allowLocked(c.posts, user.ID, chatPostRate) {
		c.mu.Unlock()
		return chatMessage{}, errs.RateLimited()
	}
	if c.last[user.ID] == clean && c.recentSameLocked(user.ID, clean) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("You just sent that.")
	}
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != user.ID && thread.B != user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	if thread.Next < 1 {
		thread.Next = 1
	}
	item := chatMessage{
		ID:    thread.Next,
		From:  user.ID,
		Name:  user.Username,
		Text:  clean,
		Links: chatLinks(clean),
		At:    time.Now().UnixMilli(),
	}
	thread.Next++
	thread.Messages = append(thread.Messages, item)
	if len(thread.Messages) > chatKeep {
		thread.Messages = append([]chatMessage(nil), thread.Messages[len(thread.Messages)-chatKeep:]...)
	}
	c.last[user.ID] = clean
	c.mu.Unlock()
	c.persist(ctx)
	return item, nil
}

func (c *chatRoom) recentSameLocked(userID, text string) bool {
	for _, thread := range c.data.Threads {
		if thread.A != userID && thread.B != userID {
			continue
		}
		if n := len(thread.Messages); n > 0 {
			last := thread.Messages[n-1]
			if last.From == userID && last.Text == text && time.Since(time.UnixMilli(last.At)) < 15*time.Second {
				return true
			}
		}
	}
	return false
}

func (c *chatRoom) threadLocked(id string) *chatThread {
	for i := range c.data.Threads {
		if c.data.Threads[i].ID == id {
			return &c.data.Threads[i]
		}
	}
	return nil
}

func (c *chatRoom) usernameLocked(id string) string {
	for _, user := range c.data.Users {
		if user.ID == id {
			return user.Username
		}
	}
	return ""
}

func threadPairs(thread chatThread, a, b string) bool {
	return (thread.A == a && thread.B == b) || (thread.A == b && thread.B == a)
}

func (c *chatRoom) allowLocked(bucket map[string][]time.Time, key string, limit int) bool {
	now := time.Now()
	kept := bucket[key][:0]
	for _, hit := range bucket[key] {
		if now.Sub(hit) <= time.Minute {
			kept = append(kept, hit)
		}
	}
	if len(kept) >= limit {
		bucket[key] = kept
		return false
	}
	bucket[key] = append(kept, now)
	return true
}

func (c *chatRoom) ensure(ctx context.Context) {
	c.load.Do(func() {
		fileData := readChatFile(c.file)
		remote := chatData{}
		if c.blob != nil {
			loadCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
			body, err := c.blob.GetBytes(loadCtx, chatKey)
			cancel()
			if err == nil {
				remote = decodeChat(body)
			}
		}
		best := fileData
		if chatRicher(remote, fileData) {
			best = remote
		}
		c.mu.Lock()
		c.data = best
		c.mu.Unlock()
	})
}

func chatRicher(a, b chatData) bool {
	if len(a.Users) != len(b.Users) {
		return len(a.Users) > len(b.Users)
	}
	return chatLatest(a) > chatLatest(b)
}

func chatLatest(data chatData) int64 {
	var last int64
	for _, thread := range data.Threads {
		for _, item := range thread.Messages {
			if item.At > last {
				last = item.At
			}
		}
	}
	return last
}

func (c *chatRoom) persist(ctx context.Context) {
	c.saveMu.Lock()
	defer c.saveMu.Unlock()
	c.mu.Lock()
	body, err := json.Marshal(c.data)
	file := c.file
	blob := c.blob
	c.mu.Unlock()
	if err != nil {
		return
	}
	_ = os.WriteFile(file, body, 0o600)
	if blob == nil {
		return
	}
	saveCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	if err := blob.PutBytes(saveCtx, chatKey, body); err != nil && !errors.Is(err, os.ErrNotExist) {
		slog.Info("chat persist failed")
	}
}

func readChatFile(path string) chatData {
	body, err := os.ReadFile(path)
	if err != nil {
		return chatData{}
	}
	return decodeChat(body)
}

func decodeChat(body []byte) chatData {
	var data chatData
	if json.Unmarshal(body, &data) != nil {
		return chatData{}
	}
	return data
}

func newChatID(prefix string) string {
	var buf [12]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return prefix + strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return prefix + hex.EncodeToString(buf[:])
}

func newChatToken() (string, string, error) {
	var buf [32]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", "", err
	}
	plain := hex.EncodeToString(buf[:])
	sum := sha256.Sum256([]byte(plain))
	return plain, hex.EncodeToString(sum[:]), nil
}

func cleanAccount(phone, email, username string) (string, string, string, error) {
	var cleanPhone, cleanEmail string
	var err error
	if strings.TrimSpace(phone) != "" {
		cleanPhone, err = cleanChatPhone(phone)
		if err != nil {
			return "", "", "", err
		}
	}
	if strings.TrimSpace(email) != "" {
		cleanEmail, err = cleanChatEmail(email)
		if err != nil {
			return "", "", "", err
		}
	}
	if cleanPhone == "" && cleanEmail == "" {
		return "", "", "", chatRejected("Enter a phone number or an email.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return "", "", "", err
	}
	return cleanPhone, cleanEmail, name, nil
}

func cleanChatPhone(raw string) (string, error) {
	var b strings.Builder
	for _, r := range raw {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	digits := b.String()
	if len(digits) < 8 || len(digits) > 15 {
		return "", chatRejected("Enter a phone number with the country code.")
	}
	return digits, nil
}

var chatEmailPattern = regexp.MustCompile(`^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$`)

func cleanChatEmail(raw string) (string, error) {
	raw = strings.ToLower(strings.TrimSpace(raw))
	if len(raw) > 80 || !chatEmailPattern.MatchString(raw) {
		return "", chatRejected("Enter a valid email address.")
	}
	return raw, nil
}

var chatUsernamePattern = regexp.MustCompile(`^[a-z0-9_]{3,20}$`)

func cleanChatUsername(raw string) (string, error) {
	raw = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(raw, "@")))
	if !chatUsernamePattern.MatchString(raw) {
		return "", chatRejected("Usernames are 3 to 20 letters, numbers, or underscores.")
	}
	switch raw {
	case "admin", "socialsave", "support", "help", "system":
		return "", chatRejected("That username is taken.")
	}
	return raw, nil
}

func cleanChatText(raw string) (string, error) {
	raw = strings.Join(strings.Fields(stripControls(raw)), " ")
	if raw == "" {
		return "", chatRejected("Write a message first.")
	}
	if utf8.RuneCountInString(raw) > chatTextMax {
		return "", chatRejected("That message is too long.")
	}
	return raw, nil
}

func stripControls(raw string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || r == 127 {
			return -1
		}
		return r
	}, raw)
}

var chatLinkPattern = regexp.MustCompile(`https?://[^\s<>"']+`)

func chatLinks(text string) []string {
	found := chatLinkPattern.FindAllString(text, 8)
	out := make([]string, 0, len(found))
	for _, raw := range found {
		raw = strings.TrimRight(raw, ".,);]}>'\"")
		if len(raw) > 300 || len(raw) < 12 {
			continue
		}
		out = append(out, raw)
		if len(out) == 3 {
			break
		}
	}
	return out
}

type chatClientError struct {
	message string
}

func (e *chatClientError) Error() string { return e.message }

func chatRejected(message string) error {
	return &chatClientError{message: message}
}

func (s *Server) chatRegister(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Phone    string `json:"phone"`
		Email    string `json:"email"`
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter a phone number or an email, and a username.")
		return
	}
	user, token, err := s.chat.register(r.Context(), clientIP(r), body.Phone, body.Email, body.Username)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"token":   token,
		"user": map[string]any{
			"id":       user.ID,
			"username": user.Username,
			"phone":    user.Phone,
			"email":    user.Email,
		},
	})
}

func (s *Server) chatMe(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"user": map[string]any{
			"id":       user.ID,
			"username": user.Username,
			"phone":    user.Phone,
			"email":    user.Email,
		},
	})
}

func (s *Server) chatLookup(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.chatActor(w, r); !ok {
		return
	}
	name, found := s.chat.lookup(r.Context(), r.URL.Query().Get("username"))
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "found": found, "username": name})
}

func (s *Server) chatThreads(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"threads": s.chat.inbox(r.Context(), user.ID),
	})
}

func (s *Server) chatOpen(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 2048)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter a username.")
		return
	}
	thread, name, err := s.chat.open(r.Context(), user.ID, body.Username)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success":  true,
		"id":       thread.ID,
		"username": name,
	})
}

func (s *Server) chatThreadList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if after < 0 {
		after = 0
	}
	items, err := s.chat.since(r.Context(), user.ID, chi.URLParam(r, "id"), after)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "messages": items})
}

func (s *Server) chatThreadPost(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Write a message first.")
		return
	}
	item, err := s.chat.post(r.Context(), user, chi.URLParam(r, "id"), body.Text)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatActor(w http.ResponseWriter, r *http.Request) (chatUser, bool) {
	user, ok := s.chat.userByToken(r.Context(), r.Header.Get(chatTokenHeader))
	if !ok {
		writeChatError(w, http.StatusUnauthorized, "Register a phone number or email to use chat.")
		return chatUser{}, false
	}
	return user, true
}

func writeChatFailure(w http.ResponseWriter, err error) {
	var rejected *chatClientError
	if errors.As(err, &rejected) {
		writeChatError(w, http.StatusBadRequest, rejected.message)
		return
	}
	writeError(w, err)
}

func writeChatError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, models.ErrorResponse{
		Success: false,
		Error:   models.ErrorBody{Code: "bad_request", Message: message},
	})
}
