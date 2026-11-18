package server

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

type chatSearchHit struct {
	Thread string `json:"thread"`
	ID     int64  `json:"id"`
	Name   string `json:"name"`
	Text   string `json:"text"`
	At     int64  `json:"at"`
	Title  string `json:"title,omitempty"`
}

func dropUserStrings(list []string, id string) ([]string, bool) {
	id = strings.TrimSpace(id)
	if id == "" {
		return list, false
	}
	out := make([]string, 0, len(list))
	dropped := false
	for _, item := range list {
		if strings.EqualFold(strings.TrimSpace(item), id) {
			dropped = true
			continue
		}
		if strings.TrimSpace(item) == "" {
			continue
		}
		out = append(out, item)
	}
	if !dropped {
		return list, false
	}
	if len(out) == 0 {
		return nil, true
	}
	return out, true
}

func (c *chatRoom) clearUnreadLocked(userID, threadID string) bool {
	for i := range c.data.Users {
		if c.data.Users[i].ID != userID {
			continue
		}
		next, ok := dropUserStrings(c.data.Users[i].UnreadMarks, threadID)
		if !ok {
			return false
		}
		c.data.Users[i].UnreadMarks = next
		return true
	}
	return false
}

func (c *chatRoom) userIndexLocked(userID string) int {
	for i := range c.data.Users {
		if c.data.Users[i].ID == userID {
			return i
		}
	}
	return -1
}

func (c *chatRoom) togglePinChat(ctx context.Context, user chatUser, threadID string) (bool, error) {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return false, chatRejected("That chat was not found.")
	}
	index := c.userIndexLocked(user.ID)
	if index < 0 {
		c.mu.Unlock()
		return false, chatRejected("Register a phone number or email to use chat.")
	}
	if chatNamed(c.data.Users[index].Pins, thread.ID) {
		next, _ := dropUserStrings(c.data.Users[index].Pins, thread.ID)
		c.data.Users[index].Pins = next
		c.mu.Unlock()
		c.persist(ctx)
		return false, nil
	}
	pins := append(append([]string(nil), c.data.Users[index].Pins...), thread.ID)
	if len(pins) > chatListPinMax {
		pins = append([]string(nil), pins[len(pins)-chatListPinMax:]...)
	}
	c.data.Users[index].Pins = pins
	c.mu.Unlock()
	c.persist(ctx)
	return true, nil
}

func (c *chatRoom) markThreadUnread(ctx context.Context, user chatUser, threadID string) error {
	c.ensure(ctx)
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatRejected("That chat was not found.")
	}
	index := c.userIndexLocked(user.ID)
	if index < 0 {
		c.mu.Unlock()
		return chatRejected("Register a phone number or email to use chat.")
	}
	if !chatNamed(c.data.Users[index].UnreadMarks, thread.ID) {
		marks := append(append([]string(nil), c.data.Users[index].UnreadMarks...), thread.ID)
		if len(marks) > 100 {
			marks = append([]string(nil), marks[len(marks)-100:]...)
		}
		c.data.Users[index].UnreadMarks = marks
	}
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) searchMessages(ctx context.Context, userID, query string) ([]chatSearchHit, error) {
	query = strings.TrimSpace(query)
	if utf8.RuneCountInString(query) < 2 {
		return nil, chatRejected("Type a little more to search.")
	}
	if utf8.RuneCountInString(query) > 80 {
		runes := []rune(query)
		query = string(runes[:80])
	}
	needle := strings.ToLower(query)
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	hits := make([]chatSearchHit, 0)
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		if !onThread(thread, userID) {
			continue
		}
		for j := len(thread.Messages) - 1; j >= 0; j-- {
			item := thread.Messages[j]
			blob := strings.ToLower(item.Text + "\n" + item.ReplyText + "\n" + item.SongName + "\n" + item.FileName)
			if !strings.Contains(blob, needle) {
				continue
			}
			text := strings.TrimSpace(item.Text)
			if text == "" {
				text = strings.TrimSpace(item.FileName)
			}
			if text == "" {
				text = strings.TrimSpace(item.SongName)
			}
			hits = append(hits, chatSearchHit{
				Thread: thread.ID,
				ID:     item.ID,
				Name:   item.Name,
				Text:   clipRunes(text, 80),
				At:     item.At,
				Title:  thread.Title,
			})
			break
		}
		if len(hits) >= chatSearchMax {
			break
		}
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].At > hits[j].At })
	return hits, nil
}

func clipRunes(text string, max int) string {
	text = strings.TrimSpace(text)
	runes := []rune(text)
	if len(runes) <= max {
		return text
	}
	return string(runes[:max])
}

func cleanFileName(raw string) string {
	raw = strings.TrimSpace(raw)
	raw = strings.ReplaceAll(raw, "\\", "/")
	if i := strings.LastIndex(raw, "/"); i >= 0 {
		raw = raw[i+1:]
	}
	raw = strings.Map(func(r rune) rune {
		if r < 32 || r == '"' || r == '<' || r == '>' || r == ':' {
			return -1
		}
		return r
	}, raw)
	raw = strings.Trim(raw, ". ")
	if utf8.RuneCountInString(raw) > 80 {
		runes := []rune(raw)
		raw = string(runes[len(runes)-80:])
		raw = strings.Trim(raw, ". ")
	}
	return raw
}

func chatFileKind(name string, clip bool) (string, bool) {
	ext := strings.ToLower(strings.TrimPrefix(filepath.Ext(name), "."))
	if clip {
		switch ext {
		case "mp4", "mov", "webm", "m4v", "3gp":
			return chatClipType(ext), true
		default:
			return "", false
		}
	}
	switch ext {
	case "pdf":
		return "application/pdf", true
	case "txt":
		return "text/plain; charset=utf-8", true
	case "csv":
		return "text/csv; charset=utf-8", true
	case "rtf":
		return "application/rtf", true
	case "doc":
		return "application/msword", true
	case "docx":
		return "application/vnd.openxmlformats-officedocument.wordprocessingml.document", true
	case "xls":
		return "application/vnd.ms-excel", true
	case "xlsx":
		return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", true
	case "ppt":
		return "application/vnd.ms-powerpoint", true
	case "pptx":
		return "application/vnd.openxmlformats-officedocument.presentationml.presentation", true
	case "zip":
		return "application/zip", true
	default:
		return "", false
	}
}

func chatClipType(ext string) string {
	switch ext {
	case "mov":
		return "video/quicktime"
	case "webm":
		return "video/webm"
	case "3gp":
		return "video/3gpp"
	default:
		return "video/mp4"
	}
}

func (c *chatRoom) postFile(ctx context.Context, user chatUser, threadID string, body []byte, name, caption string, reply int64, clip bool) (chatMessage, error) {
	name = cleanFileName(name)
	if name == "" {
		return chatMessage{}, chatRejected("Choose a file first.")
	}
	kind, ok := chatFileKind(name, clip)
	if !ok {
		if clip {
			return chatMessage{}, chatRejected("Choose a short clip.")
		}
		return chatMessage{}, chatRejected("Choose a document.")
	}
	limit := chatFileMax
	if clip {
		limit = chatClipMax
	}
	if len(body) == 0 || len(body) > limit {
		if clip {
			return chatMessage{}, chatRejected("That short clip is too large.")
		}
		return chatMessage{}, chatRejected("That document is too large.")
	}
	text := "Document"
	if clip {
		text = "Short clip"
	}
	if strings.TrimSpace(caption) != "" {
		clean, err := cleanChatText(caption)
		if err != nil {
			return chatMessage{}, err
		}
		text = clean
	}
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
	id := newChatID("f")
	item := c.appendMessageLocked(thread, user, text, chatExtra{
		Reply: reply, ReplyName: replyName, ReplyText: replyText,
		File: id, FileName: name, FileType: kind, FileSize: int64(len(body)), Clip: clip,
	})
	a, b := thread.A, thread.B
	c.mu.Unlock()
	if key, err := chatBlobKey("chat/files/", id); err == nil {
		if err := c.putBlob(ctx, key, body); err != nil {
			slog.Info("chat file save failed")
		}
	}
	c.persist(ctx)
	item.Status = "sent"
	c.announce(ctx, a, b, threadID, item)
	return item, nil
}

func (c *chatRoom) fileFor(ctx context.Context, userID, fileID string) ([]byte, string, string, error) {
	key, err := chatBlobKey("chat/files/", fileID)
	if err != nil {
		return nil, "", "", os.ErrNotExist
	}
	c.ensure(ctx)
	c.mu.Lock()
	var kind, name string
	for _, thread := range c.data.Threads {
		if !onThread(&thread, userID) {
			continue
		}
		for _, message := range thread.Messages {
			if message.File == fileID {
				kind = message.FileType
				name = message.FileName
				break
			}
		}
		if kind != "" || name != "" {
			break
		}
	}
	c.mu.Unlock()
	if kind == "" && name == "" {
		return nil, "", "", os.ErrNotExist
	}
	if link := c.publicBlob(key); link != "" {
		return nil, "", "", &chatOffload{link: link}
	}
	body, err := c.getBlob(ctx, key)
	if err != nil || len(body) == 0 {
		return nil, "", "", os.ErrNotExist
	}
	if kind == "" {
		kind = "application/octet-stream"
	}
	return body, kind, name, nil
}

func (s *Server) chatThreadListPin(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	pinned, err := s.chat.togglePinChat(r.Context(), user, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "pinned": pinned})
}

func (s *Server) chatThreadMarkUnread(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if err := s.chat.markThreadUnread(r.Context(), user, chi.URLParam(r, "id")); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "marked": true})
}

func (s *Server) chatSearch(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	hits, err := s.chat.searchMessages(r.Context(), user.ID, r.URL.Query().Get("q"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	if hits == nil {
		hits = []chatSearchHit{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "hits": hits})
}

func (s *Server) chatThreadFile(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	clip := strings.TrimSpace(r.Header.Get("X-Chat-Clip")) == "1"
	limit := chatFileMax
	if clip {
		limit = chatClipMax
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, int64(limit)+1))
	if err != nil {
		writeChatError(w, http.StatusBadRequest, "That file could not be sent.")
		return
	}
	item, err := s.chat.postFile(
		r.Context(),
		user,
		chi.URLParam(r, "id"),
		body,
		chatHeaderFileName(r),
		chatHeaderCaption(r),
		chatHeaderReply(r),
		clip,
	)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatFileGet(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, contentType, name, err := s.chat.fileFor(r.Context(), user.ID, chi.URLParam(r, "id"))
	if wroteChatOffload(w, r, err) {
		return
	}
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	if name != "" {
		w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	}
	writeChatBytes(w, contentType, body)
}

func chatHeaderFileName(r *http.Request) string {
	raw := strings.TrimSpace(r.Header.Get("X-Chat-File-Name"))
	if raw == "" {
		return ""
	}
	decoded, err := url.QueryUnescape(raw)
	if err != nil {
		return raw
	}
	return decoded
}
