package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

const (
	chatStatusLife    = 24 * time.Hour
	chatStatusViewMax = 200
	chatCallRingFor   = 45 * time.Second
	chatStarMax       = 200
	chatLabelMax      = 12
	chatReportMax     = 500
)

type chatPrivacy struct {
	Online   string `json:"online,omitempty"`
	LastSeen string `json:"lastSeen,omitempty"`
	Photo    string `json:"photo,omitempty"`
	Receipts string `json:"receipts,omitempty"`
	// Requests is off unless the person turns it on. A new chat is then a
	// normal chat, and an older request flag is ignored.
	Requests bool `json:"requests,omitempty"`
}

type chatPoll struct {
	Question string         `json:"question"`
	Choices  []string       `json:"choices"`
	Votes    map[string]int `json:"votes,omitempty"`
	Closes   int64          `json:"closes,omitempty"`
	Closed   bool           `json:"closed,omitempty"`
}

type chatCard struct {
	Name     string `json:"name"`
	Phone    string `json:"phone,omitempty"`
	Username string `json:"username,omitempty"`
}

type chatPlace struct {
	Lat   float64 `json:"lat"`
	Lng   float64 `json:"lng"`
	Label string  `json:"label,omitempty"`
}

type chatStar struct {
	Thread string `json:"thread"`
	ID     int64  `json:"id"`
	At     int64  `json:"at"`
	Text   string `json:"text,omitempty"`
}

type chatLabel struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Threads []string `json:"threads,omitempty"`
}

type chatDevice struct {
	Hash     string `json:"hash"`
	Name     string `json:"name,omitempty"`
	Platform string `json:"platform,omitempty"`
	Created  int64  `json:"created"`
	Seen     int64  `json:"seen"`
}

type chatStatusNote struct {
	ID        string   `json:"id"`
	From      string   `json:"from"`
	Name      string   `json:"name"`
	Text      string   `json:"text"`
	At        int64    `json:"at"`
	Audience  string   `json:"audience,omitempty"`
	Allow     []string `json:"allow,omitempty"`
	Deny      []string `json:"deny,omitempty"`
	Views     []string `json:"views,omitempty"`
	Font      int      `json:"font,omitempty"`
	Image     string   `json:"image,omitempty"`
	ImageType string   `json:"imageType,omitempty"`
}

type chatSchedule struct {
	ID     string `json:"id"`
	Thread string `json:"thread"`
	From   string `json:"from"`
	Text   string `json:"text"`
	Reply  int64  `json:"reply,omitempty"`
	SendAt int64  `json:"sendAt"`
	Zone   string `json:"zone,omitempty"`
}

type chatCall struct {
	ID       string `json:"id"`
	Thread   string `json:"thread"`
	From     string `json:"from"`
	To       string `json:"to"`
	FromName string `json:"fromName,omitempty"`
	State    string `json:"state"`
	At       int64  `json:"at"`
	Answered int64  `json:"answered,omitempty"`
	Ended    int64  `json:"ended,omitempty"`
	Dur      int    `json:"dur,omitempty"`
	Offer    string `json:"offer,omitempty"`
	Answer   string `json:"answer,omitempty"`
}

type chatReport struct {
	ID     string `json:"id"`
	From   string `json:"from"`
	Target string `json:"target"`
	Reason string `json:"reason,omitempty"`
	At     int64  `json:"at"`
}

type chatPostBody struct {
	Text  string     `json:"text"`
	Reply int64      `json:"reply"`
	Poll  *chatPoll  `json:"poll"`
	Card  *chatCard  `json:"card"`
	Place *chatPlace `json:"place"`
}

func stringList(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}

func threadAdmin(thread *chatThread, userID string) bool {
	if thread == nil || userID == "" {
		return false
	}
	if thread.Owner == userID {
		return true
	}
	for _, id := range thread.Admins {
		if id == userID {
			return true
		}
	}
	return false
}

func privacyChoice(raw string, receipts bool) (string, error) {
	raw = strings.ToLower(strings.TrimSpace(raw))
	if raw == "" {
		return "", nil
	}
	if receipts {
		switch raw {
		case "everyone", "nobody":
			return raw, nil
		default:
			return "", chatRejected("Choose everyone or nobody for read receipts.")
		}
	}
	switch raw {
	case "everyone", "contacts", "nobody":
		return raw, nil
	default:
		return "", chatRejected("Choose everyone, contacts, or nobody.")
	}
}

func (c *chatRoom) directPairLocked(a, b string) bool {
	if a == "" || b == "" || a == b {
		return false
	}
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		if len(thread.Members) > 0 {
			continue
		}
		if threadPairs(*thread, a, b) {
			return true
		}
	}
	return false
}

func (c *chatRoom) sharesPresenceLocked(viewerID string, owner chatUser, field string) bool {
	if viewerID == "" || owner.ID == "" {
		return false
	}
	if viewerID == owner.ID {
		return true
	}
	mode := ""
	switch field {
	case "online":
		mode = owner.Privacy.Online
	case "lastSeen":
		mode = owner.Privacy.LastSeen
	case "photo":
		mode = owner.Privacy.Photo
	}
	switch mode {
	case "", "everyone":
		return true
	case "nobody":
		return false
	case "contacts":
		return c.directPairLocked(viewerID, owner.ID)
	default:
		return true
	}
}

func (c *chatRoom) receiptsSharedLocked(thread *chatThread) bool {
	if thread == nil || len(thread.Members) > 0 {
		return true
	}
	a, aOK := c.userLocked(thread.A)
	b, bOK := c.userLocked(thread.B)
	if aOK && a.Privacy.Receipts == "nobody" {
		return false
	}
	if bOK && b.Privacy.Receipts == "nobody" {
		return false
	}
	return true
}

func (c *chatRoom) reportedOftenLocked(userID string) bool {
	cutoff := time.Now().Add(-7 * 24 * time.Hour).UnixMilli()
	n := 0
	for _, report := range c.data.Reports {
		if report.Target == userID && report.At >= cutoff {
			n++
		}
	}
	return n >= 5
}

func (c *chatRoom) gatePostLocked(thread *chatThread, user chatUser) error {
	if c.fresh == nil {
		c.fresh = map[string][]time.Time{}
	}
	// A new direct chat stays a request until the other person replies,
	// reacts, or accepts it. Messages still send, with a tighter limit,
	// and a reported account can only start one of these a minute.
	if len(thread.Members) == 0 && c.holdsRequestLocked(thread) && thread.Request != user.ID {
		limit := 5
		if c.reportedOftenLocked(user.ID) {
			limit = 1
		}
		if !c.allowLocked(c.fresh, user.ID, limit) {
			return errs.RateLimited()
		}
	}
	if len(thread.Members) > 0 && thread.Announce && !threadAdmin(thread, user.ID) {
		return chatRejected("Only admins can post in this group.")
	}
	if thread.Request == user.ID {
		thread.Request = ""
	}
	return nil
}

func (c *chatRoom) sweepThreadLocked(thread *chatThread) bool {
	if thread == nil {
		return false
	}
	now := time.Now().UnixMilli()
	dirty := false
	if thread.ClearAt > 0 && now >= thread.ClearAt {
		for _, item := range thread.Messages {
			thread.Removed = rememberRemoved(thread.Removed, item.ID)
		}
		thread.Messages = nil
		thread.ClearAt = 0
		dirty = true
	}
	if len(thread.Messages) == 0 {
		return dirty
	}
	kept := make([]chatMessage, 0, len(thread.Messages))
	for _, item := range thread.Messages {
		if item.Poll != nil && !item.Poll.Closed && item.Poll.Closes > 0 && now >= item.Poll.Closes {
			item.Poll.Closed = true
			item.Touched = now
			dirty = true
		}
		if item.Expires > 0 && item.Expires <= now {
			thread.Removed = rememberRemoved(thread.Removed, item.ID)
			dirty = true
			continue
		}
		kept = append(kept, item)
	}
	if len(kept) != len(thread.Messages) {
		thread.Messages = kept
		dirty = true
	}
	return dirty
}

func (c *chatRoom) postRich(ctx context.Context, user chatUser, threadID string, body chatPostBody) (chatMessage, error) {
	if body.Poll != nil {
		return c.postPoll(ctx, user, threadID, body.Poll, body.Reply)
	}
	if body.Card != nil {
		return c.postCard(ctx, user, threadID, body.Card, body.Reply)
	}
	if body.Place != nil {
		return c.postPlace(ctx, user, threadID, body.Place, body.Reply)
	}
	return c.post(ctx, user, threadID, body.Text, body.Reply)
}

func (c *chatRoom) deliver(ctx context.Context, user chatUser, threadID, text string, reply int64, extra chatExtra) (chatMessage, error) {
	c.ensure(ctx)
	c.mu.Lock()
	if !c.allowLocked(c.posts, user.ID, chatPostRate) {
		c.mu.Unlock()
		return chatMessage{}, errs.RateLimited()
	}
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	if err := c.gatePostLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	replyName, replyText, err := replyOf(thread, reply)
	if err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	extra.Reply = reply
	extra.ReplyName = replyName
	extra.ReplyText = replyText
	item := c.appendMessageLocked(thread, user, text, extra)
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	item.Status = "sent"
	c.announce(ctx, a, b, threadID, item)
	return item, nil
}

func cleanShort(raw, empty string, max int) (string, error) {
	raw = strings.Join(strings.Fields(stripControls(raw)), " ")
	if raw == "" {
		return "", chatRejected(empty)
	}
	if utf8.RuneCountInString(raw) > max {
		raw = string([]rune(raw)[:max])
	}
	return raw, nil
}

func (c *chatRoom) postPoll(ctx context.Context, user chatUser, threadID string, poll *chatPoll, reply int64) (chatMessage, error) {
	question, err := cleanShort(poll.Question, "Ask a question.", 120)
	if err != nil {
		return chatMessage{}, err
	}
	if len(poll.Choices) < 2 || len(poll.Choices) > 6 {
		return chatMessage{}, chatRejected("A poll needs 2 to 6 choices.")
	}
	choices := make([]string, 0, len(poll.Choices))
	seen := map[string]bool{}
	for _, choice := range poll.Choices {
		clean, err := cleanShort(choice, "Name each choice.", 40)
		if err != nil {
			return chatMessage{}, err
		}
		key := strings.ToLower(clean)
		if seen[key] {
			return chatMessage{}, chatRejected("Each choice has to be different.")
		}
		seen[key] = true
		choices = append(choices, clean)
	}
	closes := poll.Closes
	if closes != 0 && closes < time.Now().Add(time.Minute).UnixMilli() {
		return chatMessage{}, chatRejected("Choose a close time that is still ahead.")
	}
	return c.deliver(ctx, user, threadID, question, reply, chatExtra{
		Poll: &chatPoll{Question: question, Choices: choices, Closes: closes},
	})
}

func (c *chatRoom) postCard(ctx context.Context, user chatUser, threadID string, card *chatCard, reply int64) (chatMessage, error) {
	name, err := cleanShort(card.Name, "Name the contact.", 40)
	if err != nil {
		return chatMessage{}, err
	}
	phone := strings.TrimSpace(card.Phone)
	if phone != "" {
		phone, err = cleanChatPhone(phone)
		if err != nil {
			return chatMessage{}, err
		}
	}
	handle := ""
	if strings.TrimSpace(card.Username) != "" {
		handle, err = cleanChatUsername(card.Username)
		if err != nil {
			return chatMessage{}, err
		}
	}
	if phone == "" && handle == "" {
		return chatMessage{}, chatRejected("Add a phone number or a username.")
	}
	text := "Contact: " + name
	return c.deliver(ctx, user, threadID, text, reply, chatExtra{
		Card: &chatCard{Name: name, Phone: phone, Username: handle},
	})
}

func (c *chatRoom) postPlace(ctx context.Context, user chatUser, threadID string, place *chatPlace, reply int64) (chatMessage, error) {
	if place.Lat < -90 || place.Lat > 90 || place.Lng < -180 || place.Lng > 180 {
		return chatMessage{}, chatRejected("That location is not valid.")
	}
	label, _ := cleanShort(place.Label, "", 40)
	text := "Location"
	if label != "" {
		text = "Location: " + label
	}
	link := "https://maps.google.com/?q=" + strconv.FormatFloat(place.Lat, 'f', 5, 64) + "," + strconv.FormatFloat(place.Lng, 'f', 5, 64)
	if !strings.Contains(text, link) {
		text = text + " " + link
	}
	return c.deliver(ctx, user, threadID, text, reply, chatExtra{
		Place: &chatPlace{Lat: place.Lat, Lng: place.Lng, Label: label},
	})
}

func ensureRecovery(user *chatUser) (string, string, error) {
	if user == nil || user.RecoveryHash != "" {
		return "", "", nil
	}
	plain, hash, err := newRecovery()
	if err != nil {
		return "", "", err
	}
	user.RecoveryHash = hash
	return plain, hash, nil
}

func newRecovery() (string, string, error) {
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	buf := make([]byte, 10)
	if _, err := rand.Read(buf); err != nil {
		return "", "", err
	}
	out := make([]byte, len(buf))
	for i, b := range buf {
		out[i] = alphabet[int(b)%len(alphabet)]
	}
	plain := string(out)
	sum := sha256.Sum256([]byte(plain))
	return plain, hex.EncodeToString(sum[:]), nil
}

func recoveryMatches(stored, plain string) bool {
	plain = strings.ToUpper(strings.TrimSpace(plain))
	if stored == "" || plain == "" {
		return false
	}
	sum := sha256.Sum256([]byte(plain))
	got := hex.EncodeToString(sum[:])
	return subtle.ConstantTimeCompare([]byte(stored), []byte(got)) == 1
}

func (c *chatRoom) pumpSchedules() {
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for range tick.C {
		c.sendDue(context.Background())
	}
}

func (c *chatRoom) sendDue(ctx context.Context) {
	c.ensure(ctx)
	now := time.Now().UnixMilli()
	c.mu.Lock()
	due := make([]chatSchedule, 0)
	kept := make([]chatSchedule, 0, len(c.data.Schedules))
	for _, item := range c.data.Schedules {
		if item.SendAt <= now {
			due = append(due, item)
			continue
		}
		kept = append(kept, item)
	}
	if len(due) > 0 {
		c.data.Schedules = kept
	}
	c.mu.Unlock()
	if len(due) > 0 {
		c.persist(ctx)
	}
	for _, item := range due {
		c.mu.Lock()
		author, ok := c.userLocked(item.From)
		c.mu.Unlock()
		if !ok {
			continue
		}
		_, _ = c.post(ctx, author, item.Thread, item.Text, item.Reply)
	}
	c.missStaleCalls(ctx)
}

func (c *chatRoom) userRef(id string) (chatUser, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.userLocked(id)
}

func (s *Server) chatPrivacyPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body chatPrivacyBody
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Choose who can see this.")
		return
	}
	saved, err := s.chat.setPrivacy(r.Context(), user.ID, body)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "privacy": saved})
}

// chatPrivacyBody keeps missing fields so a requests switch does not clear
// online, last seen, photo, or receipts.
type chatPrivacyBody struct {
	Online   *string `json:"online"`
	LastSeen *string `json:"lastSeen"`
	Photo    *string `json:"photo"`
	Receipts *string `json:"receipts"`
	Requests *bool   `json:"requests"`
}

func (c *chatRoom) setPrivacy(ctx context.Context, userID string, body chatPrivacyBody) (chatPrivacy, error) {
	c.ensure(ctx)
	c.mu.Lock()
	found := -1
	for i := range c.data.Users {
		if c.data.Users[i].ID == userID {
			found = i
			break
		}
	}
	if found < 0 {
		c.mu.Unlock()
		return chatPrivacy{}, chatRejected("Sign in again.")
	}
	next := c.data.Users[found].Privacy
	if body.Online != nil {
		online, err := privacyChoice(*body.Online, false)
		if err != nil {
			c.mu.Unlock()
			return chatPrivacy{}, err
		}
		next.Online = online
	}
	if body.LastSeen != nil {
		seen, err := privacyChoice(*body.LastSeen, false)
		if err != nil {
			c.mu.Unlock()
			return chatPrivacy{}, err
		}
		next.LastSeen = seen
	}
	if body.Photo != nil {
		photo, err := privacyChoice(*body.Photo, false)
		if err != nil {
			c.mu.Unlock()
			return chatPrivacy{}, err
		}
		next.Photo = photo
	}
	if body.Receipts != nil {
		receipts, err := privacyChoice(*body.Receipts, true)
		if err != nil {
			c.mu.Unlock()
			return chatPrivacy{}, err
		}
		next.Receipts = receipts
	}
	if body.Requests != nil {
		next.Requests = *body.Requests
	}
	c.data.Users[found].Privacy = next
	c.mu.Unlock()
	c.persist(ctx)
	return next, nil
}

// holdsRequestLocked is true only when the recipient asked for message requests.
func (c *chatRoom) holdsRequestLocked(thread *chatThread) bool {
	if thread == nil || thread.Request == "" || len(thread.Members) > 0 {
		return false
	}
	person, ok := c.userLocked(thread.Request)
	return ok && person.Privacy.Requests
}

func (s *Server) chatStatusList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "statuses": s.chat.visibleStatuses(r.Context(), user)})
}

func (s *Server) chatStatusPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Text     string   `json:"text"`
		Audience string   `json:"audience"`
		Allow    []string `json:"allow"`
		Deny     []string `json:"deny"`
		Font     int      `json:"font"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Write an update first.")
		return
	}
	note, err := s.chat.addStatus(r.Context(), user, body.Text, body.Audience, body.Allow, body.Deny, body.Font)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "status": note})
}

func (s *Server) chatStatusView(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.viewStatus(r.Context(), user, chi.URLParam(r, "id")); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatStatusDelete(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.deleteStatus(r.Context(), user, chi.URLParam(r, "id")); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatStatusImagePut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, chatPhotoMax+1))
	if err != nil {
		writeChatError(w, http.StatusBadRequest, "Choose a JPEG or PNG photo.")
		return
	}
	font, _ := strconv.Atoi(strings.TrimSpace(r.Header.Get("X-Chat-Font")))
	note, err := s.chat.addStatusImage(
		r.Context(),
		user,
		body,
		chatHeaderCaption(r),
		chatHeaderText(r, "X-Chat-Audience"),
		chatHeaderList(r, "X-Chat-Allow"),
		chatHeaderList(r, "X-Chat-Deny"),
		font,
	)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "status": note})
}

func (s *Server) chatStatusImageGet(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, contentType, err := s.chat.statusImage(r.Context(), user, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeChatBytes(w, contentType, body)
}

func chatHeaderText(r *http.Request, name string) string {
	raw := strings.TrimSpace(r.Header.Get(name))
	if raw == "" {
		return ""
	}
	decoded, err := url.QueryUnescape(raw)
	if err != nil {
		return raw
	}
	return strings.TrimSpace(decoded)
}

func chatHeaderList(r *http.Request, name string) []string {
	raw := chatHeaderText(r, name)
	if raw == "" {
		return nil
	}
	return strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ' ' || r == ';'
	})
}

func cleanNames(values []string, max int) ([]string, error) {
	out := make([]string, 0, len(values))
	seen := map[string]bool{}
	for _, value := range values {
		name, err := cleanChatUsername(value)
		if err != nil {
			return nil, err
		}
		if seen[name] {
			continue
		}
		seen[name] = true
		out = append(out, name)
		if len(out) > max {
			return nil, chatRejected("That list is too long.")
		}
	}
	return out, nil
}

func prepareStatusFields(text, audience string, allow, deny []string, font int, allowEmpty bool) (string, string, []string, []string, int, error) {
	var clean string
	if strings.TrimSpace(text) == "" {
		if !allowEmpty {
			return "", "", nil, nil, 0, chatRejected("Write an update first.")
		}
	} else {
		next, err := cleanChatText(text)
		if err != nil {
			return "", "", nil, nil, 0, err
		}
		clean = next
	}
	audience = strings.ToLower(strings.TrimSpace(audience))
	switch audience {
	case "", "all", "contacts", "only", "except":
	default:
		return "", "", nil, nil, 0, chatRejected("Choose who can see this update.")
	}
	if audience == "" {
		audience = "all"
	}
	allowed, err := cleanNames(allow, 32)
	if err != nil {
		return "", "", nil, nil, 0, err
	}
	denied, err := cleanNames(deny, 32)
	if err != nil {
		return "", "", nil, nil, 0, err
	}
	if audience == "only" && len(allowed) == 0 {
		return "", "", nil, nil, 0, chatRejected("Choose at least one person.")
	}
	if font < 0 || font > 19 {
		font = 0
	}
	return clean, audience, allowed, denied, font, nil
}

func (c *chatRoom) addStatus(ctx context.Context, user chatUser, text, audience string, allow, deny []string, font int) (chatStatusNote, error) {
	clean, audience, allowed, denied, font, err := prepareStatusFields(text, audience, allow, deny, font, false)
	if err != nil {
		return chatStatusNote{}, err
	}
	note := chatStatusNote{
		ID: newChatID("st"), From: user.ID, Name: user.Username, Text: clean,
		At: time.Now().UnixMilli(), Audience: audience, Allow: allowed, Deny: denied,
		Font: font,
	}
	c.storeStatus(ctx, note)
	return note, nil
}

func (c *chatRoom) addStatusImage(ctx context.Context, user chatUser, body []byte, caption, audience string, allow, deny []string, font int) (chatStatusNote, error) {
	if len(body) == 0 || len(body) > chatPhotoMax || imageKind(body) == "" {
		return chatStatusNote{}, chatRejected("Choose a JPEG or PNG photo.")
	}
	clean, audience, allowed, denied, font, err := prepareStatusFields(caption, audience, allow, deny, font, true)
	if err != nil {
		return chatStatusNote{}, err
	}
	id := newChatID("st")
	key, err := chatBlobKey("chat/status/", id)
	if err != nil {
		return chatStatusNote{}, chatRejected("That photo could not be posted.")
	}
	if err := c.putBlob(ctx, key, body); err != nil {
		return chatStatusNote{}, chatRejected("That photo could not be posted.")
	}
	note := chatStatusNote{
		ID: id, From: user.ID, Name: user.Username, Text: clean,
		At: time.Now().UnixMilli(), Audience: audience, Allow: allowed, Deny: denied,
		Font: font, Image: id, ImageType: imageKind(body),
	}
	c.storeStatus(ctx, note)
	return note, nil
}

func (c *chatRoom) storeStatus(ctx context.Context, note chatStatusNote) {
	c.ensure(ctx)
	c.mu.Lock()
	c.pruneStatusesLocked()
	c.data.Statuses = append(c.data.Statuses, note)
	if len(c.data.Statuses) > 400 {
		c.data.Statuses = append([]chatStatusNote(nil), c.data.Statuses[len(c.data.Statuses)-400:]...)
	}
	c.mu.Unlock()
	c.persist(ctx)
}

func (c *chatRoom) statusImage(ctx context.Context, viewer chatUser, id string) ([]byte, string, error) {
	id = strings.TrimSpace(id)
	c.ensure(ctx)
	c.mu.Lock()
	c.pruneStatusesLocked()
	var found *chatStatusNote
	for i := range c.data.Statuses {
		if c.data.Statuses[i].ID == id {
			found = &c.data.Statuses[i]
			break
		}
	}
	if found == nil || found.Image == "" || !c.statusVisibleLocked(viewer, *found) {
		c.mu.Unlock()
		return nil, "", chatRejected("That update is gone.")
	}
	imageID := found.Image
	kind := found.ImageType
	c.mu.Unlock()
	key, err := chatBlobKey("chat/status/", imageID)
	if err != nil {
		return nil, "", chatRejected("That photo could not be opened.")
	}
	body, err := c.getBlob(ctx, key)
	if err != nil || len(body) == 0 {
		return nil, "", chatRejected("That photo could not be opened.")
	}
	if kind == "" {
		kind = imageKind(body)
	}
	if kind == "" {
		kind = "application/octet-stream"
	}
	return body, kind, nil
}

func (c *chatRoom) dropStatusImage(imageID string) {
	if imageID == "" || c.blob != nil {
		return
	}
	key, err := chatBlobKey("chat/status/", imageID)
	if err != nil {
		return
	}
	path, err := c.localBlob(key)
	if err != nil {
		return
	}
	_ = os.Remove(path)
}

func (c *chatRoom) pruneStatusesLocked() {
	cutoff := time.Now().Add(-chatStatusLife).UnixMilli()
	kept := make([]chatStatusNote, 0, len(c.data.Statuses))
	for _, note := range c.data.Statuses {
		if note.At >= cutoff {
			kept = append(kept, note)
		}
	}
	c.data.Statuses = kept
}

func (c *chatRoom) visibleStatuses(ctx context.Context, viewer chatUser) []chatStatusNote {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pruneStatusesLocked()
	out := make([]chatStatusNote, 0)
	for _, note := range c.data.Statuses {
		if !c.statusVisibleLocked(viewer, note) {
			continue
		}
		shown := note
		if note.From != viewer.ID {
			shown.Views = nil
		}
		out = append(out, shown)
	}
	return out
}

func (c *chatRoom) deleteStatus(ctx context.Context, owner chatUser, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return chatRejected("That update is gone.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	c.pruneStatusesLocked()
	found := -1
	for i := range c.data.Statuses {
		if c.data.Statuses[i].ID == id {
			found = i
			break
		}
	}
	if found < 0 {
		c.mu.Unlock()
		return chatRejected("That update is gone.")
	}
	if c.data.Statuses[found].From != owner.ID {
		c.mu.Unlock()
		return chatRejected("You can only delete your own update.")
	}
	imageID := c.data.Statuses[found].Image
	c.data.Statuses = append(c.data.Statuses[:found], c.data.Statuses[found+1:]...)
	c.mu.Unlock()
	c.persist(ctx)
	c.dropStatusImage(imageID)
	return nil
}

func (c *chatRoom) viewStatus(ctx context.Context, viewer chatUser, id string) error {
	id = strings.TrimSpace(id)
	if id == "" {
		return chatRejected("That update is gone.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	c.pruneStatusesLocked()
	found := -1
	for i := range c.data.Statuses {
		if c.data.Statuses[i].ID == id {
			found = i
			break
		}
	}
	if found < 0 || !c.statusVisibleLocked(viewer, c.data.Statuses[found]) {
		c.mu.Unlock()
		return chatRejected("That update is gone.")
	}
	note := &c.data.Statuses[found]
	if note.From == viewer.ID {
		c.mu.Unlock()
		return nil
	}
	for _, name := range note.Views {
		if strings.EqualFold(name, viewer.Username) {
			c.mu.Unlock()
			return nil
		}
	}
	if len(note.Views) >= chatStatusViewMax {
		c.mu.Unlock()
		return nil
	}
	note.Views = append(note.Views, viewer.Username)
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) statusVisibleLocked(viewer chatUser, note chatStatusNote) bool {
	if note.From == viewer.ID {
		return true
	}
	switch note.Audience {
	case "", "all":
		return true
	case "contacts":
		return c.directPairLocked(viewer.ID, note.From)
	case "only":
		return chatNamed(note.Allow, viewer.Username)
	case "except":
		if chatNamed(note.Deny, viewer.Username) {
			return false
		}
		return c.directPairLocked(viewer.ID, note.From)
	default:
		return false
	}
}

func (s *Server) chatGroupAdmin(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		On       *bool  `json:"on"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512)).Decode(&body); err != nil || body.On == nil {
		writeChatError(w, http.StatusBadRequest, "Choose a person.")
		return
	}
	if err := s.chat.setGroupAdmin(r.Context(), user, chi.URLParam(r, "id"), body.Username, *body.On); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) memberIDLocked(username string) (string, error) {
	name, err := cleanChatUsername(username)
	if err != nil {
		return "", err
	}
	for _, person := range c.data.Users {
		if person.Username == name {
			return person.ID, nil
		}
	}
	return "", chatRejected("No Social Save user has that username.")
}

func (c *chatRoom) setGroupAdmin(ctx context.Context, user chatUser, threadID, username string, on bool) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || thread.Owner != user.ID {
		c.mu.Unlock()
		return chatRejected("Only the group owner can change admins.")
	}
	peerID, err := c.memberIDLocked(username)
	if err != nil {
		c.mu.Unlock()
		return err
	}
	if peerID == thread.Owner || !onThread(thread, peerID) {
		c.mu.Unlock()
		return chatRejected("Choose a member of this group.")
	}
	next := make([]string, 0, len(thread.Admins)+1)
	for _, id := range thread.Admins {
		if id != peerID {
			next = append(next, id)
		}
	}
	if on {
		next = append(next, peerID)
	}
	thread.Admins = next
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}
