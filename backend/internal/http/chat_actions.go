package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
)

var chatQuickEmojis = []string{"👍", "❤️", "😂", "😮", "😢", "🙏"}

type chatReaction struct {
	User  string `json:"user"`
	Emoji string `json:"emoji"`
	At    int64  `json:"at"`
}

type chatMessageInfo struct {
	ID          int64 `json:"id"`
	At          int64 `json:"at"`
	EditedAt    int64 `json:"editedAt,omitempty"`
	DeliveredAt int64 `json:"deliveredAt,omitempty"`
	ReadAt      int64 `json:"readAt,omitempty"`
}

func nonNilIDs(ids []int64) []int64 {
	if ids == nil {
		return []int64{}
	}
	return ids
}

func chatEmojiOK(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "❤" {
		raw = "❤️"
	}
	for _, emoji := range chatQuickEmojis {
		if raw == emoji {
			return emoji, true
		}
	}
	return "", false
}

func dropPinned(ids []int64, id int64) []int64 {
	out := ids[:0]
	for _, cur := range ids {
		if cur != id {
			out = append(out, cur)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return append([]int64(nil), out...)
}

func (c *chatRoom) react(ctx context.Context, user chatUser, threadID string, id int64, emoji string) (chatMessage, error) {
	emoji, ok := chatEmojiOK(emoji)
	if !ok {
		return chatMessage{}, chatRejected("Pick one of the chat reactions.")
	}
	if id < 1 {
		return chatMessage{}, chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
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
		return chatMessage{}, chatRejected("That message was not found.")
	}
	now := time.Now().UnixMilli()
	prev := thread.Messages[index].Reactions
	kept := make([]chatReaction, 0, len(prev))
	same := false
	for _, item := range prev {
		if item.User == user.Username {
			if item.Emoji == emoji {
				same = true
			}
			continue
		}
		kept = append(kept, item)
	}
	if !same {
		kept = append(kept, chatReaction{User: user.Username, Emoji: emoji, At: now})
	}
	if len(kept) == 0 {
		thread.Messages[index].Reactions = nil
	} else {
		thread.Messages[index].Reactions = append([]chatReaction(nil), kept...)
	}
	thread.Messages[index].Touched = now
	item := thread.Messages[index]
	item.Status = chatStatus(thread, user.ID, item)
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	c.announceChanged(a, b, threadID, "reaction", item)
	return item, nil
}

func (c *chatRoom) edit(ctx context.Context, user chatUser, threadID string, id int64, text string) (chatMessage, error) {
	clean, err := cleanChatText(text)
	if err != nil {
		return chatMessage{}, err
	}
	if id < 1 {
		return chatMessage{}, chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	index := -1
	for i := range thread.Messages {
		if thread.Messages[i].ID != id {
			continue
		}
		if thread.Messages[i].From != user.ID {
			c.mu.Unlock()
			return chatMessage{}, chatRejected("You can only edit your own message.")
		}
		if thread.Messages[i].Voice != "" || thread.Messages[i].Song != "" {
			c.mu.Unlock()
			return chatMessage{}, chatRejected("That message cannot be edited.")
		}
		index = i
		break
	}
	if index < 0 {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That message was not found.")
	}
	item := thread.Messages[index]
	if time.Since(time.UnixMilli(item.At)) > chatEditFor {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That message can no longer be edited.")
	}
	now := time.Now().UnixMilli()
	item.Text = clean
	if item.Photo == "" {
		item.Links = chatLinks(clean)
	}
	item.EditedAt = now
	item.Touched = now
	thread.Messages[index] = item
	item.Status = chatStatus(thread, user.ID, item)
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	c.announceChanged(a, b, threadID, "edited", item)
	return item, nil
}

func (c *chatRoom) pin(ctx context.Context, user chatUser, threadID string, id int64) ([]int64, error) {
	if id < 1 {
		return nil, chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return nil, chatRejected("That chat was not found.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return nil, err
	}
	found := false
	for _, item := range thread.Messages {
		if item.ID == id {
			found = true
			break
		}
	}
	if !found {
		c.mu.Unlock()
		return nil, chatRejected("That message was not found.")
	}
	already := false
	for _, cur := range thread.Pinned {
		if cur == id {
			already = true
			break
		}
	}
	if already {
		thread.Pinned = dropPinned(thread.Pinned, id)
	} else {
		thread.Pinned = append(dropPinned(thread.Pinned, id), id)
		if len(thread.Pinned) > chatPinMax {
			thread.Pinned = append([]int64(nil), thread.Pinned[len(thread.Pinned)-chatPinMax:]...)
		}
	}
	pinned := append([]int64(nil), thread.Pinned...)
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	c.announcePinned(a, b, threadID, pinned)
	return pinned, nil
}

func (c *chatRoom) info(ctx context.Context, user chatUser, threadID string, id int64) (chatMessageInfo, error) {
	if id < 1 {
		return chatMessageInfo{}, chatRejected("That message was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		return chatMessageInfo{}, chatRejected("That chat was not found.")
	}
	var item chatMessage
	found := false
	for _, cur := range thread.Messages {
		if cur.ID == id {
			item = cur
			found = true
			break
		}
	}
	if !found {
		return chatMessageInfo{}, chatRejected("That message was not found.")
	}
	if item.From != user.ID {
		return chatMessageInfo{}, chatRejected("Message info is only for your own messages.")
	}
	peer := peerSeen(thread, user.ID)
	out := chatMessageInfo{ID: item.ID, At: item.At, EditedAt: item.EditedAt}
	if peer.Delivered >= id {
		out.DeliveredAt = peer.DeliveredAt
	}
	if peer.Read >= id {
		out.ReadAt = peer.ReadAt
	}
	return out, nil
}

func (c *chatRoom) liveIDs(a, b, threadID string) []string {
	ids := []string{a, b}
	if thread := c.threadLocked(threadID); thread != nil && len(thread.Members) > 0 {
		ids = append([]string(nil), thread.Members...)
	}
	return ids
}

func (c *chatRoom) announceChanged(a, b, threadID, kind string, item chatMessage) {
	if c.live == nil {
		return
	}
	body, err := json.Marshal(map[string]any{
		"type":    kind,
		"thread":  threadID,
		"id":      item.ID,
		"message": item,
	})
	if err != nil {
		return
	}
	c.mu.Lock()
	ids := c.liveIDs(a, b, threadID)
	c.mu.Unlock()
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		c.live.send(id, body)
	}
}

func (c *chatRoom) announcePinned(a, b, threadID string, pinned []int64) {
	if c.live == nil {
		return
	}
	if pinned == nil {
		pinned = []int64{}
	}
	body, err := json.Marshal(map[string]any{
		"type":   "pinned",
		"thread": threadID,
		"pinned": pinned,
	})
	if err != nil {
		return
	}
	c.mu.Lock()
	ids := c.liveIDs(a, b, threadID)
	c.mu.Unlock()
	seen := map[string]bool{}
	for _, id := range ids {
		if id == "" || seen[id] {
			continue
		}
		seen[id] = true
		c.live.send(id, body)
	}
}

func (s *Server) chatThreadReact(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID    int64  `json:"id"`
		Emoji string `json:"emoji"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Pick a reaction.")
		return
	}
	item, err := s.chat.react(r.Context(), user, chi.URLParam(r, "id"), body.ID, body.Emoji)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatThreadEdit(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID   int64  `json:"id"`
		Text string `json:"text"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Write a message first.")
		return
	}
	item, err := s.chat.edit(r.Context(), user, chi.URLParam(r, "id"), body.ID, body.Text)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatThreadPin(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		ID int64 `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That message was not found.")
		return
	}
	pinned, err := s.chat.pin(r.Context(), user, chi.URLParam(r, "id"), body.ID)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "pinned": nonNilIDs(pinned)})
}

func (s *Server) chatThreadInfo(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	id, _ := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	info, err := s.chat.info(r.Context(), user, chi.URLParam(r, "id"), id)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "info": info})
}
