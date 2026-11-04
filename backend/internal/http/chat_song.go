package server

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

func songKind(body []byte) (string, string) {
	if len(body) >= 3 && body[0] == 'I' && body[1] == 'D' && body[2] == '3' {
		return "mp3", "audio/mpeg"
	}
	if len(body) >= 2 && body[0] == 0xFF && body[1]&0xE0 == 0xE0 {
		return "mp3", "audio/mpeg"
	}
	if len(body) >= 4 && string(body[:4]) == "fLaC" {
		return "flac", "audio/flac"
	}
	if len(body) >= 4 && string(body[:4]) == "OggS" {
		return "ogg", "audio/ogg"
	}
	if len(body) >= 12 && string(body[:4]) == "RIFF" && string(body[8:12]) == "WAVE" {
		return "wav", "audio/wav"
	}
	if len(body) >= 12 && string(body[4:8]) == "ftyp" {
		head := body
		if len(head) > 64 {
			head = body[:64]
		}
		if bytes.Contains(head, []byte("avc1")) || bytes.Contains(head, []byte("hvc1")) || bytes.Contains(head, []byte("vide")) {
			return "", ""
		}
		return "m4a", "audio/mp4"
	}
	return "", ""
}

func cleanSongName(raw string) (string, error) {
	raw = strings.Join(strings.Fields(stripControls(raw)), " ")
	if raw == "" {
		return "", chatRejected("Name the song.")
	}
	if utf8.RuneCountInString(raw) > 80 {
		raw = string([]rune(raw)[:80])
	}
	return raw, nil
}

func (c *chatRoom) postSong(ctx context.Context, user chatUser, threadID string, body []byte, name string, ms int, reply int64) (chatMessage, error) {
	if len(body) == 0 || len(body) > chatSongMax {
		return chatMessage{}, chatRejected("That song is too large to send in chat.")
	}
	kind, _ := songKind(body)
	if kind == "" {
		return chatMessage{}, chatRejected("Choose a saved song.")
	}
	title, err := cleanSongName(name)
	if err != nil {
		return chatMessage{}, err
	}
	if ms < 0 || ms > 20*60*1000 {
		return chatMessage{}, chatRejected("That song is too long to send in chat.")
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
	replyName, replyText, err := replyOf(thread, reply)
	if err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	c.mu.Unlock()
	id := newChatID("s")
	if err := c.putBlob(ctx, "chat/songs/"+id, body); err != nil {
		return chatMessage{}, chatRejected("That song could not be sent.")
	}
	c.mu.Lock()
	thread = c.threadLocked(threadID)
	if thread == nil || !onThread(thread, user.ID) {
		c.mu.Unlock()
		return chatMessage{}, chatRejected("That chat was not found.")
	}
	if err := c.refuseDirectLocked(thread, user); err != nil {
		c.mu.Unlock()
		return chatMessage{}, err
	}
	item := c.appendMessageLocked(thread, user, title, chatExtra{
		Reply: reply, ReplyName: replyName, ReplyText: replyText,
		Song: id, SongName: title, SongMs: ms, SongType: kind,
	})
	a, b := thread.A, thread.B
	c.mu.Unlock()
	c.persist(ctx)
	item.Status = "sent"
	c.announce(ctx, a, b, threadID, item)
	return item, nil
}

func (c *chatRoom) songFor(ctx context.Context, userID, songID string) ([]byte, string, error) {
	key, err := chatBlobKey("chat/songs/", songID)
	if err != nil {
		return nil, "", os.ErrNotExist
	}
	c.ensure(ctx)
	c.mu.Lock()
	kind := ""
	for _, thread := range c.data.Threads {
		if !onThread(&thread, userID) {
			continue
		}
		for _, message := range thread.Messages {
			if message.Song == songID {
				kind = message.SongType
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
	switch kind {
	case "mp3":
		return body, "audio/mpeg", nil
	case "flac":
		return body, "audio/flac", nil
	case "ogg":
		return body, "audio/ogg", nil
	case "wav":
		return body, "audio/wav", nil
	default:
		return body, "audio/mp4", nil
	}
}

func (s *Server) chatThreadSong(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	ms, _ := strconv.Atoi(r.Header.Get("X-Song-Ms"))
	name := strings.TrimSpace(r.Header.Get("X-Song-Name"))
	if decoded, err := url.QueryUnescape(name); err == nil {
		name = decoded
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, chatSongMax+1))
	if err != nil {
		writeChatError(w, http.StatusBadRequest, "That song could not be sent.")
		return
	}
	item, err := s.chat.postSong(r.Context(), user, chi.URLParam(r, "id"), body, name, ms, chatHeaderReply(r))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "message": item})
}

func (s *Server) chatSongGet(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	body, contentType, err := s.chat.songFor(r.Context(), user.ID, chi.URLParam(r, "id"))
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeChatBytes(w, contentType, body)
}
