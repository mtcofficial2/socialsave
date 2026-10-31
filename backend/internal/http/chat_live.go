package server

import (
	"bufio"
	"context"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/auth"
)

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

type liveFrame struct {
	opcode byte
	data   []byte
}

type liveConn struct {
	userID string
	out    chan liveFrame
}

type chatHub struct {
	mu     sync.Mutex
	byUser map[string]map[*liveConn]struct{}
}

func newChatHub() *chatHub {
	return &chatHub{byUser: map[string]map[*liveConn]struct{}{}}
}

func (h *chatHub) add(c *liveConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.byUser[c.userID]
	if set == nil {
		set = map[*liveConn]struct{}{}
		h.byUser[c.userID] = set
	}
	set[c] = struct{}{}
}

func (h *chatHub) remove(c *liveConn) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.byUser[c.userID]
	delete(set, c)
	if len(set) == 0 {
		delete(h.byUser, c.userID)
		return 0
	}
	return len(set)
}

func (h *chatHub) send(userID string, text []byte) bool {
	return h.deliver(userID, liveFrame{opcode: 0x1, data: text})
}

func (h *chatHub) sendBinary(userID string, data []byte) bool {
	return h.deliver(userID, liveFrame{opcode: 0x2, data: data})
}

func (h *chatHub) deliver(userID string, frame liveFrame) bool {
	if h == nil || userID == "" || len(frame.data) == 0 && frame.opcode == 0x1 {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	set := h.byUser[userID]
	if len(set) == 0 {
		return false
	}
	ok := false
	for conn := range set {
		select {
		case conn.out <- frame:
			ok = true
		default:
		}
	}
	return ok
}

func (c *chatRoom) announce(ctx context.Context, a, b, threadID string, item chatMessage) {
	if c.live == nil {
		return
	}
	body, err := json.Marshal(map[string]any{
		"type":    "message",
		"thread":  threadID,
		"message": item,
	})
	if err != nil {
		return
	}
	if c.live.send(a, body) && a != item.From {
		c.markPushed(ctx, a, threadID, item.ID, b)
	}
	if a != b && c.live.send(b, body) && b != item.From {
		c.markPushed(ctx, b, threadID, item.ID, a)
	}
}

func (c *chatRoom) announceRead(userID, threadID string, id int64) {
	if c.live == nil || userID == "" || id <= 0 {
		return
	}
	body, err := json.Marshal(map[string]any{"type": "read", "thread": threadID, "id": id})
	if err != nil {
		return
	}
	c.live.send(userID, body)
}

func (c *chatRoom) markPushed(ctx context.Context, userID, threadID string, id int64, tell string) {
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil {
		c.mu.Unlock()
		return
	}
	if thread.Seen == nil {
		thread.Seen = map[string]chatSeen{}
	}
	cur := thread.Seen[userID]
	if cur.Delivered >= id {
		c.mu.Unlock()
		return
	}
	cur.Delivered = id
	if cur.Delivered < cur.Read {
		cur.Delivered = cur.Read
	}
	thread.Seen[userID] = cur
	c.mu.Unlock()
	c.persist(ctx)
	body, err := json.Marshal(map[string]any{"type": "delivered", "thread": threadID, "id": id})
	if err == nil {
		c.live.send(tell, body)
	}
}

func (c *chatRoom) touch(ctx context.Context, userID string) {
	c.ensure(ctx)
	c.mu.Lock()
	dirty := c.touchLocked(userID)
	c.mu.Unlock()
	if dirty {
		c.persist(ctx)
	}
}

func (c *chatRoom) announcePresence(userID string, online bool) {
	if c.live == nil {
		return
	}
	c.mu.Lock()
	user, ok := c.userLocked(userID)
	if !ok {
		c.mu.Unlock()
		return
	}
	others := make([]string, 0)
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		switch userID {
		case thread.A:
			others = append(others, thread.B)
		case thread.B:
			others = append(others, thread.A)
		}
	}
	c.mu.Unlock()
	body, err := json.Marshal(map[string]any{
		"type":     "presence",
		"username": user.Username,
		"online":   online,
		"lastSeen": user.LastSeen,
	})
	if err != nil {
		return
	}
	for _, id := range others {
		c.live.send(id, body)
	}
}

func (c *chatRoom) onLiveText(user chatUser, payload []byte) {
	if len(payload) == 0 || len(payload) > 2048 {
		return
	}
	var body struct {
		Type   string `json:"type"`
		Thread string `json:"thread"`
		ID     string `json:"id"`
		On     bool   `json:"on"`
	}
	if json.Unmarshal(payload, &body) != nil {
		return
	}
	switch body.Type {
	case "typing":
		c.liveTyping(user, body.Thread, body.On)
	case "photo-have":
		c.notePhotoHave(user, body.Thread, body.ID)
	}
}

func (c *chatRoom) liveTyping(user chatUser, threadID string, on bool) {
	if c.live == nil || threadID == "" {
		return
	}
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != user.ID && thread.B != user.ID) {
		c.mu.Unlock()
		return
	}
	other := thread.B
	if other == user.ID {
		other = thread.A
	}
	c.mu.Unlock()
	body, err := json.Marshal(map[string]any{
		"type":   "typing",
		"thread": threadID,
		"from":   user.Username,
		"on":     on,
	})
	if err != nil {
		return
	}
	c.live.send(other, body)
}

func (c *chatRoom) notePhotoHave(user chatUser, threadID, photoID string) {
	if c.live == nil || threadID == "" || photoID == "" {
		return
	}
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != user.ID && thread.B != user.ID) {
		c.mu.Unlock()
		return
	}
	sender := ""
	for i := len(thread.Messages) - 1; i >= 0; i-- {
		if thread.Messages[i].Photo == photoID {
			sender = thread.Messages[i].From
			break
		}
	}
	c.mu.Unlock()
	if sender == "" || sender == user.ID {
		return
	}
	body, err := json.Marshal(map[string]any{"type": "photo-ok", "thread": threadID, "id": photoID})
	if err != nil {
		return
	}
	c.live.send(sender, body)
}

// relayPhoto forwards a picture to the other phone and does not keep the bytes.
func (c *chatRoom) relayPhoto(fromID, threadID, photoID string, body []byte) bool {
	if c.live == nil || photoID == "" || len(body) == 0 || len(body) > chatPhotoMax {
		return false
	}
	if imageKind(body) == "" {
		return false
	}
	c.mu.Lock()
	thread := c.threadLocked(threadID)
	if thread == nil || (thread.A != fromID && thread.B != fromID) {
		c.mu.Unlock()
		return false
	}
	owned := false
	for i := len(thread.Messages) - 1; i >= 0; i-- {
		item := thread.Messages[i]
		if item.Photo == photoID && item.From == fromID {
			owned = true
			break
		}
	}
	other := thread.B
	if other == fromID {
		other = thread.A
	}
	c.mu.Unlock()
	if !owned || other == fromID {
		return false
	}
	return c.live.sendBinary(other, encodePhotoFrame(threadID, photoID, body))
}

func (c *chatRoom) relayIncomingPhoto(from chatUser, payload []byte) {
	threadID, photoID, body, err := decodePhotoFrame(payload)
	if err != nil {
		return
	}
	if c.relayPhoto(from.ID, threadID, photoID, body) {
		return
	}
	note, err := json.Marshal(map[string]any{"type": "photo-wait", "thread": threadID, "id": photoID})
	if err == nil {
		c.live.send(from.ID, note)
	}
}

func encodePhotoFrame(threadID, photoID string, body []byte) []byte {
	tb := []byte(threadID)
	pb := []byte(photoID)
	out := make([]byte, 1+2+len(tb)+2+len(pb)+len(body))
	out[0] = 1
	binary.BigEndian.PutUint16(out[1:3], uint16(len(tb)))
	copy(out[3:], tb)
	off := 3 + len(tb)
	binary.BigEndian.PutUint16(out[off:off+2], uint16(len(pb)))
	copy(out[off+2:], pb)
	copy(out[off+2+len(pb):], body)
	return out
}

func decodePhotoFrame(payload []byte) (string, string, []byte, error) {
	if len(payload) < 5 || payload[0] != 1 {
		return "", "", nil, errors.New("frame")
	}
	threadLen := int(binary.BigEndian.Uint16(payload[1:3]))
	if threadLen < 1 || threadLen > 40 || len(payload) < 3+threadLen+2 {
		return "", "", nil, errors.New("frame")
	}
	threadID := string(payload[3 : 3+threadLen])
	off := 3 + threadLen
	photoLen := int(binary.BigEndian.Uint16(payload[off : off+2]))
	off += 2
	if photoLen < 1 || photoLen > 40 || len(payload) < off+photoLen {
		return "", "", nil, errors.New("frame")
	}
	photoID := string(payload[off : off+photoLen])
	body := payload[off+photoLen:]
	if len(body) == 0 || len(body) > chatPhotoMax {
		return "", "", nil, errors.New("frame")
	}
	return threadID, photoID, body, nil
}

func (s *Server) chatLive(w http.ResponseWriter, r *http.Request) {
	if err := auth.Authorize(r, s.Config); err != nil {
		writeError(w, err)
		return
	}
	user, ok := s.chat.userByToken(r.Context(), r.Header.Get(chatTokenHeader))
	if !ok {
		writeChatError(w, http.StatusUnauthorized, "Register a phone number or email to use chat.")
		return
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") || key == "" {
		writeChatError(w, http.StatusBadRequest, "Chat could not connect.")
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		writeChatError(w, http.StatusInternalServerError, "Chat could not connect.")
		return
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	sum := sha1.Sum([]byte(key + wsGUID))
	accept := base64.StdEncoding.EncodeToString(sum[:])
	if _, err = rw.WriteString("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n"); err != nil {
		return
	}
	if err = rw.Flush(); err != nil {
		return
	}
	lc := &liveConn{userID: user.ID, out: make(chan liveFrame, 8)}
	s.chat.live.add(lc)
	defer func() {
		if s.chat.live.remove(lc) == 0 {
			s.chat.announcePresence(user.ID, false)
		}
	}()
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	go s.writeLive(ctx, conn, rw.Writer, lc)
	s.chat.live.send(user.ID, []byte(`{"type":"ready"}`))
	s.chat.touch(r.Context(), user.ID)
	s.chat.announcePresence(user.ID, true)
	for {
		_ = conn.SetReadDeadline(time.Now().Add(50 * time.Second))
		op, payload, err := readFrame(rw.Reader, chatPhotoMax+512)
		if err != nil {
			return
		}
		switch op {
		case 0x8:
			return
		case 0x9:
			select {
			case lc.out <- liveFrame{opcode: 0xA, data: payload}:
			default:
			}
		case 0x2:
			s.chat.relayIncomingPhoto(user, payload)
		case 0x1:
			s.chat.onLiveText(user, payload)
		}
	}
}

func (s *Server) writeLive(ctx context.Context, conn net.Conn, w *bufio.Writer, lc *liveConn) {
	ping := time.NewTicker(20 * time.Second)
	defer ping.Stop()
	var mu sync.Mutex
	write := func(op byte, data []byte) error {
		mu.Lock()
		defer mu.Unlock()
		_ = conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
		return writeFrame(w, op, data)
	}
	for {
		select {
		case <-ctx.Done():
			return
		case frame := <-lc.out:
			if err := write(frame.opcode, frame.data); err != nil {
				_ = conn.Close()
				return
			}
		case <-ping.C:
			if err := write(0x9, nil); err != nil {
				_ = conn.Close()
				return
			}
			s.chat.touch(context.Background(), lc.userID)
		}
	}
}

func writeFrame(w *bufio.Writer, opcode byte, payload []byte) error {
	if payload == nil {
		payload = []byte{}
	}
	if len(payload) > chatPhotoMax+512 {
		return errors.New("frame")
	}
	header := []byte{0x80 | opcode}
	n := len(payload)
	switch {
	case n < 126:
		header = append(header, byte(n))
	case n <= 65535:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[len(header)-2:], uint16(n))
	default:
		header = append(header, 127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[len(header)-8:], uint64(n))
	}
	if _, err := w.Write(header); err != nil {
		return err
	}
	if _, err := w.Write(payload); err != nil {
		return err
	}
	return w.Flush()
}

func readFrame(r *bufio.Reader, max int) (byte, []byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, nil, err
	}
	if hdr[0]&0x70 != 0 || hdr[0]&0x80 == 0 {
		return 0, nil, errors.New("frame")
	}
	opcode := hdr[0] & 0x0f
	masked := hdr[1]&0x80 != 0
	length := int(hdr[1] & 0x7f)
	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return 0, nil, err
		}
		length = int(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(r, ext[:]); err != nil {
			return 0, nil, err
		}
		n := binary.BigEndian.Uint64(ext[:])
		if n > uint64(max) {
			return 0, nil, errors.New("frame")
		}
		length = int(n)
	}
	if length > max {
		return 0, nil, errors.New("frame")
	}
	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, length)
	if length > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return 0, nil, err
		}
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return opcode, payload, nil
}
