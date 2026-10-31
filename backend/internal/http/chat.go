package server

import (
	"bytes"
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
	chatPhotoMax    = 512 * 1024
	chatVoiceMax    = 900 * 1024
	chatOnlineFor   = 35 * time.Second
	chatSeenPersist = 45 * time.Second
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
	PhotoRev  int64  `json:"photoRev,omitempty"`
	LastSeen  int64  `json:"lastSeen,omitempty"`
}

type chatMessage struct {
	ID        int64    `json:"id"`
	From      string   `json:"from"`
	Name      string   `json:"name"`
	Text      string   `json:"text"`
	Links     []string `json:"links,omitempty"`
	At        int64    `json:"at"`
	Status    string   `json:"status,omitempty"`
	Voice     string   `json:"voice,omitempty"`
	VoiceMs   int      `json:"voiceMs,omitempty"`
	VoiceType string   `json:"voiceType,omitempty"`
}

// chatSeen is how far this person has received or opened the conversation.
// Delivered is two gray ticks. Read is two blue ticks.
type chatSeen struct {
	Delivered int64 `json:"delivered,omitempty"`
	Read      int64 `json:"read,omitempty"`
}

type chatThread struct {
	ID       string              `json:"id"`
	A        string              `json:"a"`
	B        string              `json:"b"`
	Next     int64               `json:"next"`
	Messages []chatMessage       `json:"messages"`
	Seen     map[string]chatSeen `json:"seen,omitempty"`
}

type chatData struct {
	Users   []chatUser   `json:"users"`
	Threads []chatThread `json:"threads"`
}

type chatInboxItem struct {
	ID         string `json:"id"`
	Username   string `json:"username"`
	LastText   string `json:"lastText,omitempty"`
	LastAt     int64  `json:"lastAt,omitempty"`
	LastID     int64  `json:"lastId,omitempty"`
	LastFrom   string `json:"lastFrom,omitempty"`
	LastStatus string `json:"lastStatus,omitempty"`
	Unread     int    `json:"unread,omitempty"`
	LastSeen   int64  `json:"lastSeen,omitempty"`
	Online     bool   `json:"online,omitempty"`
	PhotoRev   int64  `json:"photoRev,omitempty"`
}

// chatPeerView is the other person, as far as ticks, presence, and photo go.
type chatPeerView struct {
	Delivered int64
	Read      int64
	LastSeen  int64
	Online    bool
	PhotoRev  int64
}

type chatRoom struct {
	mu        sync.Mutex
	saveMu    sync.Mutex
	load      sync.Once
	data      chatData
	posts     map[string][]time.Time
	joins     map[string][]time.Time
	last      map[string]string
	seenSaved map[string]int64
	blob      chatBlob
	file      string
}

func newChatRoom(up storage.Uploader) *chatRoom {
	var blob chatBlob
	if value, ok := up.(chatBlob); ok {
		blob = value
	}
	return &chatRoom{
		posts:     map[string][]time.Time{},
		joins:     map[string][]time.Time{},
		last:      map[string]string{},
		seenSaved: map[string]int64{},
		blob:      blob,
		file:      filepath.Join(os.TempDir(), "socialsave-chat-accounts.json"),
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
	dirty := c.touchLocked(userID)
	out := make([]chatInboxItem, 0)
	now := time.Now()
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		otherID := ""
		switch userID {
		case thread.A:
			otherID = thread.B
		case thread.B:
			otherID = thread.A
		default:
			continue
		}
		if noteDelivered(thread, userID) {
			dirty = true
		}
		other, _ := c.userLocked(otherID)
		item := chatInboxItem{
			ID:       thread.ID,
			Username: other.Username,
			Unread:   unreadCount(thread, userID),
			LastSeen: other.LastSeen,
			Online:   chatOnline(other.LastSeen, now),
			PhotoRev: other.PhotoRev,
		}
		if n := len(thread.Messages); n > 0 {
			last := thread.Messages[n-1]
			item.LastText = last.Text
			item.LastAt = last.At
			item.LastID = last.ID
			item.LastFrom = last.Name
			item.LastStatus = chatStatus(thread, userID, last)
		}
		out = append(out, item)
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].LastAt > out[j-1].LastAt; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	c.mu.Unlock()
	if dirty {
		c.persist(ctx)
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

func (c *chatRoom) since(ctx context.Context, userID, threadID string, after int64) ([]chatMessage, chatPeerView, error) {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != userID && thread.B != userID) {
		c.mu.Unlock()
		return nil, chatPeerView{}, chatRejected("That chat was not found.")
	}
	dirty := c.touchLocked(userID)
	if noteDelivered(thread, userID) {
		dirty = true
	}
	out := make([]chatMessage, 0)
	for _, item := range thread.Messages {
		if item.ID > after {
			item.Status = chatStatus(thread, userID, item)
			out = append(out, item)
		}
	}
	seen := peerSeen(thread, userID)
	otherID := thread.B
	if otherID == userID {
		otherID = thread.A
	}
	other, _ := c.userLocked(otherID)
	peer := chatPeerView{
		Delivered: seen.Delivered,
		Read:      seen.Read,
		LastSeen:  other.LastSeen,
		Online:    chatOnline(other.LastSeen, time.Now()),
		PhotoRev:  other.PhotoRev,
	}
	c.mu.Unlock()
	if dirty {
		c.persist(ctx)
	}
	return out, peer, nil
}

func (c *chatRoom) markRead(ctx context.Context, userID, threadID string, id int64) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != userID && thread.B != userID) {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	last := int64(0)
	if n := len(thread.Messages); n > 0 {
		last = thread.Messages[n-1].ID
	}
	if id <= 0 || id > last {
		id = last
	}
	if thread.Seen == nil {
		thread.Seen = map[string]chatSeen{}
	}
	cur := thread.Seen[userID]
	if cur.Read >= id && cur.Delivered >= id {
		c.mu.Unlock()
		return nil
	}
	if id > cur.Read {
		cur.Read = id
	}
	if cur.Delivered < cur.Read {
		cur.Delivered = cur.Read
	}
	thread.Seen[userID] = cur
	c.mu.Unlock()
	c.persist(ctx)
	return nil
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
	item := c.appendMessageLocked(thread, user, clean, "", 0, "")
	c.last[user.ID] = clean
	c.mu.Unlock()
	c.persist(ctx)
	item.Status = "sent"
	return item, nil
}

func (c *chatRoom) postVoice(ctx context.Context, user chatUser, threadID string, body []byte, ms int) (chatMessage, error) {
	if len(body) == 0 || len(body) > chatVoiceMax {
		return chatMessage{}, chatRejected("That voice note is too large.")
	}
	if ms < 400 || ms > 65000 {
		return chatMessage{}, chatRejected("Voice notes can be up to one minute.")
	}
	kind, _ := voiceKind(body)
	if kind == "" {
		return chatMessage{}, chatRejected("That voice note could not be played.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	if !c.allowLocked(c.posts, user.ID, chatPostRate) {
		c.mu.Unlock()
		return chatMessage{}, errs.RateLimited()
	}
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != user.ID && thread.B != user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	c.mu.Unlock()
	id := newChatID("v")
	if err := c.putBlob(ctx, "chat/voices/"+id, body); err != nil {
		slog.Info("chat voice save failed")
		return chatMessage{}, chatRejected("That voice note could not be sent.")
	}
	c.mu.Lock()
	thread = c.threadLocked(threadID)
	if thread == nil || (thread.A != user.ID && thread.B != user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	item := c.appendMessageLocked(thread, user, "Voice message", id, ms, kind)
	c.mu.Unlock()
	c.persist(ctx)
	item.Status = "sent"
	return item, nil
}

func (c *chatRoom) appendMessageLocked(thread *chatThread, user chatUser, text, voice string, voiceMs int, voiceType string) chatMessage {
	if thread.Next < 1 {
		thread.Next = 1
	}
	item := chatMessage{
		ID:        thread.Next,
		From:      user.ID,
		Name:      user.Username,
		Text:      text,
		At:        time.Now().UnixMilli(),
		Voice:     voice,
		VoiceMs:   voiceMs,
		VoiceType: voiceType,
	}
	if voice == "" {
		item.Links = chatLinks(text)
	}
	thread.Next++
	thread.Messages = append(thread.Messages, item)
	if len(thread.Messages) > chatKeep {
		thread.Messages = append([]chatMessage(nil), thread.Messages[len(thread.Messages)-chatKeep:]...)
	}
	return item
}

func (c *chatRoom) setPhoto(ctx context.Context, userID string, body []byte) (int64, error) {
	if len(body) == 0 || len(body) > chatPhotoMax {
		return 0, chatRejected("That photo is too large.")
	}
	if imageKind(body) == "" {
		return 0, chatRejected("Choose a JPEG or PNG photo.")
	}
	c.ensure(ctx)
	if err := c.putBlob(ctx, "chat/avatars/"+userID, body); err != nil {
		slog.Info("chat photo save failed")
		return 0, chatRejected("That photo could not be saved.")
	}
	rev := time.Now().UnixMilli()
	c.mu.Lock()
	found := false
	for i := range c.data.Users {
		if c.data.Users[i].ID == userID {
			c.data.Users[i].PhotoRev = rev
			found = true
			break
		}
	}
	c.mu.Unlock()
	if !found {
		return 0, chatRejected("Register a phone number or email to use chat.")
	}
	c.persist(ctx)
	return rev, nil
}

func (c *chatRoom) photo(ctx context.Context, username string) ([]byte, string, error) {
	c.ensure(ctx)
	name := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	c.mu.Lock()
	var id string
	var rev int64
	for _, user := range c.data.Users {
		if user.Username == name {
			id = user.ID
			rev = user.PhotoRev
			break
		}
	}
	c.mu.Unlock()
	if id == "" || rev == 0 {
		return nil, "", os.ErrNotExist
	}
	body, err := c.getBlob(ctx, "chat/avatars/"+id)
	if err != nil {
		return nil, "", os.ErrNotExist
	}
	kind := imageKind(body)
	if kind == "" {
		return nil, "", os.ErrNotExist
	}
	return body, kind, nil
}

func (c *chatRoom) voiceFor(ctx context.Context, userID, voiceID string) ([]byte, string, error) {
	key, err := chatBlobKey("chat/voices/", voiceID)
	if err != nil {
		return nil, "", os.ErrNotExist
	}
	c.ensure(ctx)
	c.mu.Lock()
	kind := ""
	for _, thread := range c.data.Threads {
		if thread.A != userID && thread.B != userID {
			continue
		}
		for _, message := range thread.Messages {
			if message.Voice == voiceID {
				kind = message.VoiceType
				break
			}
		}
		if kind != "" {
			break
		}
	}
	c.mu.Unlock()
	if kind == "" {
		return nil, "", os.ErrNotExist
	}
	body, err := c.getBlob(ctx, key)
	if err != nil || len(body) == 0 {
		return nil, "", os.ErrNotExist
	}
	return body, voiceContentType(kind), nil
}

func (c *chatRoom) presence(ctx context.Context, username string) (int64, bool, int64) {
	c.ensure(ctx)
	name := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, user := range c.data.Users {
		if user.Username == name {
			return user.LastSeen, chatOnline(user.LastSeen, time.Now()), user.PhotoRev
		}
	}
	return 0, false, 0
}

// touchLocked records that this account is in the chat. It writes that time
// to storage at most once a minute, so a poll does not save the bucket.
func (c *chatRoom) touchLocked(userID string) bool {
	now := time.Now().UnixMilli()
	if c.seenSaved == nil {
		c.seenSaved = map[string]int64{}
	}
	for i := range c.data.Users {
		if c.data.Users[i].ID != userID {
			continue
		}
		c.data.Users[i].LastSeen = now
		if now-c.seenSaved[userID] < chatSeenPersist.Milliseconds() {
			return false
		}
		c.seenSaved[userID] = now
		return true
	}
	return false
}

func (c *chatRoom) userLocked(id string) (chatUser, bool) {
	for _, user := range c.data.Users {
		if user.ID == id {
			user.TokenHash = ""
			return user, true
		}
	}
	return chatUser{}, false
}

func (c *chatRoom) putBlob(ctx context.Context, key string, body []byte) error {
	if strings.Contains(key, "..") || strings.Trim(key, "/") == "" {
		return errors.New("bad object key")
	}
	if c.blob != nil {
		saveCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
		defer cancel()
		return c.blob.PutBytes(saveCtx, key, body)
	}
	path, err := c.localBlob(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, body, 0o600)
}

func (c *chatRoom) getBlob(ctx context.Context, key string) ([]byte, error) {
	if c.blob != nil {
		loadCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
		defer cancel()
		return c.blob.GetBytes(loadCtx, key)
	}
	path, err := c.localBlob(key)
	if err != nil {
		return nil, err
	}
	return os.ReadFile(path)
}

func (c *chatRoom) localBlob(key string) (string, error) {
	key = strings.Trim(key, "/")
	if key == "" || strings.Contains(key, "..") {
		return "", errors.New("bad object key")
	}
	return filepath.Join(filepath.Dir(c.file), filepath.FromSlash(key)), nil
}

func noteDelivered(thread *chatThread, userID string) bool {
	last := int64(0)
	if n := len(thread.Messages); n > 0 {
		last = thread.Messages[n-1].ID
	}
	if last == 0 {
		return false
	}
	if thread.Seen == nil {
		thread.Seen = map[string]chatSeen{}
	}
	cur := thread.Seen[userID]
	if cur.Delivered >= last {
		return false
	}
	cur.Delivered = last
	if cur.Delivered < cur.Read {
		cur.Delivered = cur.Read
	}
	thread.Seen[userID] = cur
	return true
}

func unreadCount(thread *chatThread, userID string) int {
	seen := int64(0)
	if thread.Seen != nil {
		seen = thread.Seen[userID].Read
	}
	count := 0
	for _, message := range thread.Messages {
		if message.ID > seen && message.From != userID {
			count++
		}
	}
	return count
}

func peerSeen(thread *chatThread, userID string) chatSeen {
	other := thread.A
	if other == userID {
		other = thread.B
	}
	if thread.Seen == nil {
		return chatSeen{}
	}
	return thread.Seen[other]
}

func chatStatus(thread *chatThread, viewerID string, message chatMessage) string {
	if message.From != viewerID || message.ID == 0 {
		return ""
	}
	seen := peerSeen(thread, viewerID)
	if seen.Read >= message.ID {
		return "read"
	}
	if seen.Delivered >= message.ID {
		return "delivered"
	}
	return "sent"
}

func (c *chatRoom) recentSameLocked(userID, text string) bool {
	for _, thread := range c.data.Threads {
		if thread.A != userID && thread.B != userID {
			continue
		}
		if n := len(thread.Messages); n > 0 {
			last := thread.Messages[n-1]
			if last.Voice != "" {
				continue
			}
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

func chatOnline(lastSeen int64, now time.Time) bool {
	if lastSeen <= 0 {
		return false
	}
	age := now.UnixMilli() - lastSeen
	return age >= 0 && age < chatOnlineFor.Milliseconds()
}

func chatBlobKey(prefix, id string) (string, error) {
	if id == "" || len(id) > 40 || strings.Contains(id, "..") {
		return "", os.ErrNotExist
	}
	for _, r := range id {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			return "", os.ErrNotExist
		}
	}
	return prefix + id, nil
}

func imageKind(body []byte) string {
	if len(body) >= 8 && bytes.Equal(body[:8], []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}) {
		return "image/png"
	}
	if len(body) >= 3 && body[0] == 0xFF && body[1] == 0xD8 && body[2] == 0xFF {
		return "image/jpeg"
	}
	return ""
}

func voiceKind(body []byte) (string, string) {
	if len(body) >= 12 && string(body[4:8]) == "ftyp" {
		return "m4a", "audio/mp4"
	}
	if len(body) >= 12 && string(body[:4]) == "RIFF" && string(body[8:12]) == "WAVE" {
		return "wav", "audio/wav"
	}
	if len(body) >= 4 && string(body[:4]) == "OggS" {
		return "ogg", "audio/ogg"
	}
	if len(body) >= 4 && body[0] == 0x1A && body[1] == 0x45 && body[2] == 0xDF && body[3] == 0xA3 {
		return "webm", "audio/webm"
	}
	return "", ""
}

func voiceContentType(kind string) string {
	switch kind {
	case "wav":
		return "audio/wav"
	case "ogg":
		return "audio/ogg"
	case "webm":
		return "audio/webm"
	default:
		return "audio/mp4"
	}
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
		"user":    chatPublicUser(user, true),
	})
}

func (s *Server) chatMe(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"user":    chatPublicUser(user, true),
	})
}

func (s *Server) chatPhotoPost(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, chatPhotoMax+1))
	if err != nil {
		writeChatError(w, http.StatusBadRequest, "Choose a photo.")
		return
	}
	rev, err := s.chat.setPhoto(r.Context(), user.ID, body)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "photoRev": rev})
}

func (s *Server) chatPhotoGet(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.chatActor(w, r); !ok {
		return
	}
	body, contentType, err := s.chat.photo(r.Context(), r.URL.Query().Get("username"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeChatBytes(w, contentType, body)
}

func chatPublicUser(user chatUser, withContact bool) map[string]any {
	out := map[string]any{
		"id":       user.ID,
		"username": user.Username,
		"photoRev": user.PhotoRev,
	}
	if withContact {
		out["phone"] = user.Phone
		out["email"] = user.Email
	}
	return out
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
	lastSeen, online, photoRev := s.chat.presence(r.Context(), name)
	payload := map[string]any{
		"success":  true,
		"id":       thread.ID,
		"username": name,
	}
	if lastSeen > 0 {
		payload["lastSeen"] = lastSeen
	}
	if online {
		payload["online"] = true
	}
	if photoRev > 0 {
		payload["photoRev"] = photoRev
	}
	writeJSON(w, http.StatusOK, payload)
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
	items, peer, err := s.chat.since(r.Context(), user.ID, chi.URLParam(r, "id"), after)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	peerJSON := map[string]any{
		"delivered": peer.Delivered,
		"read":      peer.Read,
	}
	if peer.LastSeen > 0 {
		peerJSON["lastSeen"] = peer.LastSeen
	}
	if peer.Online {
		peerJSON["online"] = true
	}
	if peer.PhotoRev > 0 {
		peerJSON["photoRev"] = peer.PhotoRev
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success":  true,
		"messages": items,
		"peer":     peerJSON,
	})
}

func (s *Server) chatThreadVoice(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	ms, _ := strconv.Atoi(r.Header.Get("X-Voice-Ms"))
	body, err := io.ReadAll(io.LimitReader(r.Body, chatVoiceMax+1))
	if err != nil {
		writeChatError(w, http.StatusBadRequest, "That voice note could not be sent.")
		return
	}
	item, err := s.chat.postVoice(r.Context(), user, chi.URLParam(r, "id"), body, ms)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatVoiceGet(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, contentType, err := s.chat.voiceFor(r.Context(), user.ID, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeChatBytes(w, contentType, body)
}

func (s *Server) chatThreadRead(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil && !errors.Is(err, io.EOF) {
		writeChatError(w, http.StatusBadRequest, "That chat was not found.")
		return
	}
	if err := s.chat.markRead(r.Context(), user.ID, chi.URLParam(r, "id"), body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
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
	if errors.Is(err, os.ErrNotExist) {
		writeChatError(w, http.StatusNotFound, "That file was not found.")
		return
	}
	var rejected *chatClientError
	if errors.As(err, &rejected) {
		writeChatError(w, http.StatusBadRequest, rejected.message)
		return
	}
	writeError(w, err)
}

func writeChatBytes(w http.ResponseWriter, contentType string, body []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "private, max-age=86400")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func writeChatError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, models.ErrorResponse{
		Success: false,
		Error:   models.ErrorBody{Code: "bad_request", Message: message},
	})
}
