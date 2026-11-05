package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

func (s *Server) chatGroupRemove(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Choose a person.")
		return
	}
	if err := s.chat.removeGroupMember(r.Context(), user, chi.URLParam(r, "id"), body.Username); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) removeGroupMember(ctx context.Context, user chatUser, threadID, username string) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !threadAdmin(thread, user.ID) {
		c.mu.Unlock()
		return chatRejected("Only an admin can remove someone.")
	}
	peerID, err := c.memberIDLocked(username)
	if err != nil {
		c.mu.Unlock()
		return err
	}
	if peerID == thread.Owner {
		c.mu.Unlock()
		return chatRejected("Transfer the group before removing its owner.")
	}
	if peerID == user.ID {
		c.mu.Unlock()
		return chatRejected("Leave the group instead.")
	}
	next := make([]string, 0, len(thread.Members))
	for _, id := range thread.Members {
		if id != peerID {
			next = append(next, id)
		}
	}
	if len(next) == len(thread.Members) {
		c.mu.Unlock()
		return chatRejected("That person is not in this group.")
	}
	thread.Members = next
	admins := make([]string, 0, len(thread.Admins))
	for _, id := range thread.Admins {
		if id != peerID {
			admins = append(admins, id)
		}
	}
	thread.Admins = admins
	if thread.Seen != nil {
		delete(thread.Seen, peerID)
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatGroupTransfer(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Choose the next owner.")
		return
	}
	if err := s.chat.transferGroup(r.Context(), user, chi.URLParam(r, "id"), body.Username); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) transferGroup(ctx context.Context, user chatUser, threadID, username string) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || thread.Owner != user.ID {
		c.mu.Unlock()
		return chatRejected("Only the group owner can transfer it.")
	}
	peerID, err := c.memberIDLocked(username)
	if err != nil {
		c.mu.Unlock()
		return err
	}
	if peerID == user.ID || !onThread(thread, peerID) {
		c.mu.Unlock()
		return chatRejected("Choose another member.")
	}
	thread.Owner = peerID
	admins := make([]string, 0, len(thread.Admins)+1)
	seen := map[string]bool{peerID: true}
	for _, id := range thread.Admins {
		if id == "" || id == peerID || seen[id] {
			continue
		}
		seen[id] = true
		admins = append(admins, id)
	}
	if !seen[user.ID] {
		admins = append(admins, user.ID)
	}
	thread.Admins = admins
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatGroupInvite(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Hours int `json:"hours"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "The invite could not be changed.")
		return
	}
	code, exp, err := s.chat.rotateInvite(r.Context(), user, chi.URLParam(r, "id"), body.Hours)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "code": code, "inviteExp": exp})
}

func (c *chatRoom) rotateInvite(ctx context.Context, user chatUser, threadID string, hours int) (string, int64, error) {
	if hours < 0 || hours > 24*30 {
		return "", 0, chatRejected("Choose an expiry up to 30 days, or none.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !threadAdmin(thread, user.ID) {
		c.mu.Unlock()
		return "", 0, chatRejected("Only an admin can change the invite.")
	}
	code, err := c.freshGroupCodeLocked()
	if err != nil {
		c.mu.Unlock()
		return "", 0, err
	}
	thread.Code = code
	var exp int64
	if hours > 0 {
		exp = time.Now().Add(time.Duration(hours) * time.Hour).UnixMilli()
	}
	thread.InviteExp = exp
	c.mu.Unlock()
	c.persist(ctx)
	return code, exp, nil
}

func (s *Server) chatGroupInfo(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		About    *string `json:"about"`
		Rules    *string `json:"rules"`
		Announce *bool   `json:"announce"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "The group details could not be saved.")
		return
	}
	if err := s.chat.setGroupInfo(r.Context(), user, chi.URLParam(r, "id"), body.About, body.Rules, body.Announce); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) setGroupInfo(ctx context.Context, user chatUser, threadID string, about, rules *string, announce *bool) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !threadAdmin(thread, user.ID) {
		c.mu.Unlock()
		return chatRejected("Only an admin can change the group.")
	}
	if about != nil {
		clean, err := cleanOptional(*about, 400)
		if err != nil {
			c.mu.Unlock()
			return err
		}
		thread.About = clean
	}
	if rules != nil {
		clean, err := cleanOptional(*rules, 400)
		if err != nil {
			c.mu.Unlock()
			return err
		}
		thread.Rules = clean
	}
	if announce != nil {
		thread.Announce = *announce
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func cleanOptional(raw string, max int) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	return cleanShort(raw, "Write something shorter.", max)
}

func (s *Server) chatPollVote(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID     int64 `json:"id"`
		Choice int   `json:"choice"`
		Close  bool  `json:"close"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That vote could not be saved.")
		return
	}
	item, err := s.chat.votePoll(r.Context(), user, chi.URLParam(r, "id"), body.ID, body.Choice, body.Close)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (c *chatRoom) votePoll(ctx context.Context, user chatUser, threadID string, id int64, choice int, close bool) (chatMessage, error) {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	index := -1
	for i := range thread.Messages {
		if thread.Messages[i].ID == id && thread.Messages[i].Poll != nil {
			index = i
			break
		}
	}
	if index < 0 {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That poll was not found.")
	}
	poll := thread.Messages[index].Poll
	now := time.Now().UnixMilli()
	if poll.Closes > 0 && now >= poll.Closes {
		poll.Closed = true
	}
	if close {
		if thread.Messages[index].From != user.ID {
			c.mu.Unlock()
			return chatMessage{}, chatRejected("Only the person who asked can close it.")
		}
		poll.Closed = true
	} else if poll.Closed {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That poll is closed.")
	} else if choice < 0 || choice >= len(poll.Choices) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("Choose one of the options.")
	} else {
		if poll.Votes == nil {
			poll.Votes = map[string]int{}
		}
		poll.Votes[user.Username] = choice
	}
	thread.Messages[index].Touched = now
	item := thread.Messages[index]
	item.Status = chatStatus(thread, user.ID, item)
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	c.announceChanged(a, b, threadID, "poll", item)
	return item, nil
}

func (s *Server) chatSchedulePut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Thread string `json:"thread"`
		Text   string `json:"text"`
		Reply  int64  `json:"reply"`
		SendAt int64  `json:"sendAt"`
		Zone   string `json:"zone"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That message could not be scheduled.")
		return
	}
	item, err := s.chat.addSchedule(r.Context(), user, body.Thread, body.Text, body.Zone, body.Reply, body.SendAt)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "schedule": item})
}

func cleanZone(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > 64 {
		return ""
	}
	for _, r := range raw {
		if r < 32 || r == 127 {
			return ""
		}
	}
	return raw
}

func (c *chatRoom) addSchedule(ctx context.Context, user chatUser, threadID, text, zone string, reply, sendAt int64) (chatSchedule, error) {
	clean, err := cleanChatText(text)
	if err != nil {
		return chatSchedule{}, err
	}
	now := time.Now()
	when := time.UnixMilli(sendAt)
	if sendAt < now.Add(time.Minute).UnixMilli() || when.After(now.Add(365*24*time.Hour)) {
		return chatSchedule{}, chatRejected("Choose a send time in the future.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatSchedule{}, chatRejected("That chat was not found.")
	}
	if _, _, err := replyOf(thread, reply); err != nil {
		c.mu.Unlock()
		return chatSchedule{}, err
	}
	item := chatSchedule{
		ID: newChatID("q"), Thread: thread.ID, From: user.ID, Text: clean,
		Reply: reply, SendAt: sendAt, Zone: cleanZone(zone),
	}
	c.data.Schedules = append(c.data.Schedules, item)
	c.mu.Unlock()
	c.persist(ctx)
	return item, nil
}

func (s *Server) chatScheduleList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "schedules": s.chat.listSchedules(r.Context(), user.ID)})
}

func (c *chatRoom) listSchedules(ctx context.Context, userID string) []chatSchedule {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]chatSchedule, 0)
	for _, item := range c.data.Schedules {
		if item.From == userID {
			out = append(out, item)
		}
	}
	return out
}

func (s *Server) chatScheduleCancel(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That scheduled message was not found.")
		return
	}
	if err := s.chat.cancelSchedule(r.Context(), user.ID, body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) cancelSchedule(ctx context.Context, userID, id string) error {
	id = strings.TrimSpace(id)
	c.ensure(ctx)
	c.mu.Lock()
	next := make([]chatSchedule, 0, len(c.data.Schedules))
	found := false
	for _, item := range c.data.Schedules {
		if item.ID == id && item.From == userID {
			found = true
			continue
		}
		next = append(next, item)
	}
	if !found {
		c.mu.Unlock()
		return chatRejected("That scheduled message was not found.")
	}
	c.data.Schedules = next
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatScheduleEdit(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID     string `json:"id"`
		Text   string `json:"text"`
		SendAt int64  `json:"sendAt"`
		Zone   string `json:"zone"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That scheduled message could not be changed.")
		return
	}
	item, err := s.chat.editSchedule(r.Context(), user.ID, body.ID, body.Text, body.Zone, body.SendAt)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "schedule": item})
}

func (c *chatRoom) editSchedule(ctx context.Context, userID, id, text, zone string, sendAt int64) (chatSchedule, error) {
	clean, err := cleanChatText(text)
	if err != nil {
		return chatSchedule{}, err
	}
	now := time.Now()
	if sendAt < now.Add(time.Minute).UnixMilli() || time.UnixMilli(sendAt).After(now.Add(365*24*time.Hour)) {
		return chatSchedule{}, chatRejected("Choose a send time in the future.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	for i := range c.data.Schedules {
		item := &c.data.Schedules[i]
		if item.ID != id || item.From != userID {
			continue
		}
		item.Text = clean
		item.SendAt = sendAt
		item.Zone = cleanZone(zone)
		copy := *item
		c.mu.Unlock()
		c.persist(ctx)
		return copy, nil
	}
	c.mu.Unlock()
	return chatSchedule{}, chatRejected("That scheduled message was not found.")
}

func (s *Server) chatStarPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Thread string `json:"thread"`
		ID     int64  `json:"id"`
		On     *bool  `json:"on"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil || body.On == nil {
		writeChatError(w, http.StatusBadRequest, "That message could not be starred.")
		return
	}
	if err := s.chat.setStar(r.Context(), user.ID, body.Thread, body.ID, *body.On); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) setStar(ctx context.Context, userID, threadID string, id int64, on bool) error {
	if id < 1 || threadID == "" {
		return chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, userID) {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	foundMessage := false
	for _, item := range thread.Messages {
		if item.ID == id {
			foundMessage = true
			break
		}
	}
	if !foundMessage {
		c.mu.Unlock()
		return chatRejected("That message was not found.")
	}
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
	person := &c.data.Users[index]
	next := make([]chatStar, 0, len(person.Stars)+1)
	for _, star := range person.Stars {
		if star.Thread == thread.ID && star.ID == id {
			continue
		}
		next = append(next, star)
	}
	if on {
		if len(next) >= chatStarMax {
			c.mu.Unlock()
			return chatRejected("Starred messages are full. Remove one first.")
		}
		next = append(next, chatStar{Thread: thread.ID, ID: id, At: time.Now().UnixMilli()})
	}
	person.Stars = next
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatStarList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "stars": s.chat.listStars(r.Context(), user.ID)})
}

func (c *chatRoom) listStars(ctx context.Context, userID string) []chatStar {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	var stars []chatStar
	for _, person := range c.data.Users {
		if person.ID == userID {
			stars = append([]chatStar(nil), person.Stars...)
			break
		}
	}
	out := make([]chatStar, 0, len(stars))
	for _, star := range stars {
		copy := star
		thread := c.threadLocked(star.Thread)
		if thread == nil {
			continue
		}
		for _, item := range thread.Messages {
			if item.ID == star.ID {
				copy.Text = item.Text
				out = append(out, copy)
				break
			}
		}
	}
	return out
}

func (s *Server) chatLabelPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID      string   `json:"id"`
		Name    string   `json:"name"`
		Threads []string `json:"threads"`
		Delete  bool     `json:"delete"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That folder could not be saved.")
		return
	}
	labels, err := s.chat.saveLabel(r.Context(), user.ID, body.ID, body.Name, body.Threads, body.Delete)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "labels": labels})
}

func (c *chatRoom) saveLabel(ctx context.Context, userID, id, name string, threads []string, drop bool) ([]chatLabel, error) {
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
		return nil, chatRejected("Sign in again.")
	}
	person := &c.data.Users[index]
	if drop {
		id = strings.TrimSpace(id)
		next := make([]chatLabel, 0, len(person.Labels))
		for _, label := range person.Labels {
			if label.ID != id {
				next = append(next, label)
			}
		}
		person.Labels = next
		out := append([]chatLabel(nil), person.Labels...)
		c.mu.Unlock()
		c.persist(ctx)
		return out, nil
	}
	clean, err := cleanShort(name, "Name the folder.", 24)
	if err != nil {
		c.mu.Unlock()
		return nil, err
	}
	keptThreads := make([]string, 0, len(threads))
	seen := map[string]bool{}
	for _, threadID := range threads {
		threadID = strings.TrimSpace(threadID)
		thread := c.threadLocked(threadID)
		if thread == nil || !onThread(thread, userID) || seen[thread.ID] {
			continue
		}
		seen[thread.ID] = true
		keptThreads = append(keptThreads, thread.ID)
		if len(keptThreads) >= 100 {
			break
		}
	}
	id = strings.TrimSpace(id)
	found := false
	for i := range person.Labels {
		if person.Labels[i].ID == id && id != "" {
			person.Labels[i].Name = clean
			person.Labels[i].Threads = keptThreads
			found = true
			break
		}
	}
	if !found {
		if len(person.Labels) >= chatLabelMax {
			c.mu.Unlock()
			return nil, chatRejected("You can keep up to 12 folders.")
		}
		person.Labels = append(person.Labels, chatLabel{ID: newChatID("lb"), Name: clean, Threads: keptThreads})
	}
	out := append([]chatLabel(nil), person.Labels...)
	c.mu.Unlock()
	c.persist(ctx)
	return out, nil
}

func (s *Server) chatLabelList(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "labels": s.chat.labelsOf(r.Context(), user.ID)})
}

func (c *chatRoom) labelsOf(ctx context.Context, userID string) []chatLabel {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, person := range c.data.Users {
		if person.ID == userID {
			if person.Labels == nil {
				return []chatLabel{}
			}
			return append([]chatLabel(nil), person.Labels...)
		}
	}
	return []chatLabel{}
}

func (s *Server) chatTimerPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Vanish     int `json:"vanish"`
		ClearHours int `json:"clearHours"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That timer could not be saved.")
		return
	}
	if err := s.chat.setTimer(r.Context(), user, chi.URLParam(r, "id"), body.Vanish, body.ClearHours); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) setTimer(ctx context.Context, user chatUser, threadID string, vanish, clearHours int) error {
	switch vanish {
	case 0, 24 * 3600, 7 * 24 * 3600, 90 * 24 * 3600:
	default:
		return chatRejected("Choose 24 hours, 7 days, 90 days, or off.")
	}
	if clearHours < 0 || clearHours > 24*90 {
		return chatRejected("Choose how long to keep this chat.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	if len(thread.Members) > 0 && !threadAdmin(thread, user.ID) {
		c.mu.Unlock()
		return chatRejected("Only an admin can set the group timer.")
	}
	thread.Vanish = vanish
	if clearHours == 0 {
		thread.ClearAt = 0
	} else {
		thread.ClearAt = time.Now().Add(time.Duration(clearHours) * time.Hour).UnixMilli()
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatAccept(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.acceptRequest(r.Context(), user, chi.URLParam(r, "id")); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) acceptRequest(ctx context.Context, user chatUser, threadID string) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) || len(thread.Members) > 0 {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	if thread.Request != user.ID {
		c.mu.Unlock()
		return nil
	}
	thread.Request = ""
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatReportPut(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		Reason   string `json:"reason"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "The report could not be sent.")
		return
	}
	if err := s.chat.addReport(r.Context(), user, body.Username, body.Reason); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) addReport(ctx context.Context, user chatUser, username, reason string) error {
	name, err := cleanChatUsername(username)
	if err != nil {
		return err
	}
	if name == user.Username {
		return chatRejected("That is your own username.")
	}
	reason, _ = cleanShort(reason, "", 200)
	c.ensure(ctx)
	c.mu.Lock()
	if !c.allowLocked(c.joins, "report:"+user.ID, 5) {
		c.mu.Unlock()
		return errs.RateLimited()
	}
	target := ""
	for _, person := range c.data.Users {
		if person.Username == name {
			target = person.ID
			break
		}
	}
	if target == "" {
		c.mu.Unlock()
		return chatRejected("No Social Save user has that username.")
	}
	c.data.Reports = append(c.data.Reports, chatReport{
		ID: newChatID("rp"), From: user.ID, Target: target, Reason: reason, At: time.Now().UnixMilli(),
	})
	if len(c.data.Reports) > chatReportMax {
		c.data.Reports = append([]chatReport(nil), c.data.Reports[len(c.data.Reports)-chatReportMax:]...)
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}
