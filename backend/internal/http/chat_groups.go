package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
)

const chatGroupMax = 32

func cleanGroupName(raw string) (string, error) {
	raw = strings.Join(strings.Fields(stripControls(raw)), " ")
	if raw == "" {
		return "", chatRejected("Name the group.")
	}
	if utf8.RuneCountInString(raw) > 40 {
		return "", chatRejected("That name is too long.")
	}
	return raw, nil
}

func (c *chatRoom) freshGroupCodeLocked() (string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		code := pairCode()
		if code == "SAVE00" {
			return "", chatRejected("The group could not be made. Try again.")
		}
		taken := false
		for i := range c.data.Threads {
			if strings.EqualFold(c.data.Threads[i].Code, code) {
				taken = true
				break
			}
		}
		if !taken {
			return code, nil
		}
	}
	return "", chatRejected("The group could not be made. Try again.")
}

func (c *chatRoom) createGroup(ctx context.Context, user chatUser, name string) (chatThread, error) {
	title, err := cleanGroupName(name)
	if err != nil {
		return chatThread{}, err
	}
	c.ensure(ctx)
	c.mu.Lock()
	code, err := c.freshGroupCodeLocked()
	if err != nil {
		c.mu.Unlock()
		return chatThread{}, err
	}
	thread := chatThread{
		ID:      newChatID("g"),
		Title:   title,
		Owner:   user.ID,
		Code:    code,
		Members: []string{user.ID},
		Next:    1,
	}
	c.data.Threads = append(c.data.Threads, thread)
	c.mu.Unlock()
	c.persist(ctx)
	return thread, nil
}

func (c *chatRoom) joinGroup(ctx context.Context, user chatUser, code string) (chatThread, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) != 6 {
		return chatThread{}, chatRejected("Enter the 6-character group code.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	var thread *chatThread
	for i := range c.data.Threads {
		if strings.EqualFold(c.data.Threads[i].Code, code) && len(c.data.Threads[i].Members) > 0 {
			thread = &c.data.Threads[i]
			break
		}
	}
	if thread == nil {
		c.mu.Unlock()
		return chatThread{}, chatRejected("No group uses that code.")
	}
	for _, id := range thread.Members {
		if id == user.ID {
			copy := *thread
			c.mu.Unlock()
			return copy, nil
		}
	}
	if len(thread.Members) >= chatGroupMax {
		c.mu.Unlock()
		return chatThread{}, chatRejected("That group is full.")
	}
	thread.Members = append(thread.Members, user.ID)
	copy := *thread
	c.mu.Unlock()
	c.persist(ctx)
	return copy, nil
}

func (c *chatRoom) addGroupMember(ctx context.Context, user chatUser, threadID, username string) (chatThread, []string, error) {
	peer := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	if !chatUsernamePattern.MatchString(peer) {
		return chatThread{}, nil, chatRejected("Enter a username.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatThread{}, nil, chatRejected("That group was not found.")
	}
	var peerID string
	for _, person := range c.data.Users {
		if person.Username == peer {
			peerID = person.ID
			break
		}
	}
	if peerID == "" {
		c.mu.Unlock()
		return chatThread{}, nil, chatRejected("No Social Save user has that username.")
	}
	for _, id := range thread.Members {
		if id == peerID {
			copy := *thread
			names := thread.MemberNames(c)
			c.mu.Unlock()
			return copy, names, nil
		}
	}
	if len(thread.Members) >= chatGroupMax {
		c.mu.Unlock()
		return chatThread{}, nil, chatRejected("That group is full.")
	}
	thread.Members = append(thread.Members, peerID)
	copy := *thread
	names := thread.MemberNames(c)
	c.mu.Unlock()
	c.persist(ctx)
	return copy, names, nil
}

func (c *chatRoom) leaveGroup(ctx context.Context, user chatUser, threadID string) error {
	c.ensure(ctx)
	c.mu.Lock()
	index := -1
	for i := range c.data.Threads {
		if c.data.Threads[i].ID == threadID {
			index = i
			break
		}
	}
	if index < 0 || len(c.data.Threads[index].Members) == 0 || !onThread(&c.data.Threads[index], user.ID) {
		c.mu.Unlock()
		return chatRejected("That group was not found.")
	}
	thread := &c.data.Threads[index]
	next := make([]string, 0, len(thread.Members))
	for _, id := range thread.Members {
		if id != user.ID {
			next = append(next, id)
		}
	}
	if len(next) == 0 {
		c.data.Threads = append(c.data.Threads[:index], c.data.Threads[index+1:]...)
		c.mu.Unlock()
		c.persist(ctx)
		return nil
	}
	thread.Members = next
	if thread.Owner == user.ID {
		thread.Owner = next[0]
	}
	if thread.Seen != nil {
		delete(thread.Seen, user.ID)
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) renameGroup(ctx context.Context, user chatUser, threadID, name string) (string, error) {
	title, err := cleanGroupName(name)
	if err != nil {
		return "", err
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return "", chatRejected("That group was not found.")
	}
	if thread.Owner != user.ID {
		c.mu.Unlock()
		return "", chatRejected("Only the person who made the group can rename it.")
	}
	thread.Title = title
	c.mu.Unlock()
	c.persist(ctx)
	return title, nil
}

func (c *chatRoom) groupView(ctx context.Context, user chatUser, threadID string) (chatThread, []string, error) {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	thread := c.threadLocked(threadID)
	if thread == nil || len(thread.Members) == 0 || !onThread(thread, user.ID) {
		return chatThread{}, nil, chatRejected("That group was not found.")
	}
	return *thread, thread.MemberNames(c), nil
}

func (c *chatRoom) setBlocked(ctx context.Context, userID, username string, on bool) (bool, error) {
	c.ensure(ctx)
	peer := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	if !chatUsernamePattern.MatchString(peer) {
		return false, chatRejected("Enter a username.")
	}
	c.mu.Lock()
	found := false
	for _, user := range c.data.Users {
		if user.Username == peer {
			found = true
			break
		}
	}
	if !found {
		c.mu.Unlock()
		return false, chatRejected("No Social Save user has that username.")
	}
	for i := range c.data.Users {
		if c.data.Users[i].ID != userID {
			continue
		}
		if c.data.Users[i].Username == peer {
			c.mu.Unlock()
			return false, chatRejected("That is your own username.")
		}
		next := make([]string, 0, len(c.data.Users[i].Blocked)+1)
		for _, name := range c.data.Users[i].Blocked {
			if name != peer {
				next = append(next, name)
			}
		}
		if on {
			next = append(next, peer)
		}
		if len(next) == 0 {
			c.data.Users[i].Blocked = nil
		} else {
			c.data.Users[i].Blocked = next
		}
		c.mu.Unlock()
		c.persist(ctx)
		return on, nil
	}
	c.mu.Unlock()
	return false, chatRejected("Sign in again.")
}

func writeGroup(w http.ResponseWriter, thread chatThread, members []string) {
	if members == nil {
		members = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"id":      thread.ID,
		"name":    thread.Title,
		"code":    thread.Code,
		"group":   true,
		"members": members,
	})
}

func (s *Server) chatGroupCreate(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Name the group.")
		return
	}
	thread, err := s.chat.createGroup(r.Context(), user, body.Name)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeGroup(w, thread, []string{user.Username})
}

func (s *Server) chatGroupJoin(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter the 6-character group code.")
		return
	}
	thread, err := s.chat.joinGroup(r.Context(), user, body.Code)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	_, names, err := s.chat.groupView(r.Context(), user, thread.ID)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeGroup(w, thread, names)
}

func (s *Server) chatGroupGet(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	thread, names, err := s.chat.groupView(r.Context(), user, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeGroup(w, thread, names)
}

func (s *Server) chatGroupAdd(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter a username.")
		return
	}
	thread, names, err := s.chat.addGroupMember(r.Context(), user, chi.URLParam(r, "id"), body.Username)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeGroup(w, thread, names)
}

func (s *Server) chatGroupName(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Name the group.")
		return
	}
	title, err := s.chat.renameGroup(r.Context(), user, chi.URLParam(r, "id"), body.Name)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "name": title})
}

func (s *Server) chatGroupLeave(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.leaveGroup(r.Context(), user, chi.URLParam(r, "id")); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatBlock(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		On       *bool  `json:"on"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil || body.On == nil {
		writeChatError(w, http.StatusBadRequest, "Enter a username.")
		return
	}
	on, err := s.chat.setBlocked(r.Context(), user.ID, body.Username, *body.On)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "blocked": on})
}

func (s *Server) chatLogout(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.chatActor(w, r); !ok {
		return
	}
	s.chat.dropSession(r.Context(), r.Header.Get(chatTokenHeader))
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
