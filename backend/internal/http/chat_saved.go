package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"
)

func cleanSeenName(raw string) (string, error) {
	raw = strings.Join(strings.Fields(stripControls(raw)), " ")
	if utf8.RuneCountInString(raw) > 40 {
		return "", chatRejected("That name is too long.")
	}
	return raw, nil
}

// saveSeenLocked stores the name this person wants to see for a username.
// A blank name, or the username itself, clears the custom name.
func saveSeenLocked(data *chatData, userID, peer, raw string) (string, error) {
	label, err := cleanSeenName(raw)
	if err != nil {
		return "", err
	}
	if strings.EqualFold(label, peer) {
		label = ""
	}
	for i := range data.Users {
		if data.Users[i].ID != userID {
			continue
		}
		if data.Users[i].Saved == nil {
			data.Users[i].Saved = map[string]string{}
		}
		if label == "" {
			delete(data.Users[i].Saved, peer)
		} else {
			data.Users[i].Saved[peer] = label
		}
		if len(data.Users[i].Saved) == 0 {
			data.Users[i].Saved = nil
		}
		return label, nil
	}
	return "", chatRejected("Sign in again.")
}

func seenNameLocked(data chatData, userID, peer string) string {
	for _, user := range data.Users {
		if user.ID != userID || user.Saved == nil {
			continue
		}
		return user.Saved[peer]
	}
	return ""
}

func (s *Server) chatSaved(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		Name     string `json:"name"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "Enter a username.")
		return
	}
	label, err := s.chat.setSeenName(r.Context(), user.ID, body.Username, body.Name)
	if err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success":  true,
		"username": strings.ToLower(strings.TrimSpace(strings.TrimPrefix(body.Username, "@"))),
		"name":     label,
	})
}

func (c *chatRoom) setSeenName(ctx context.Context, userID, username, raw string) (string, error) {
	c.ensure(ctx)
	peer := strings.ToLower(strings.TrimSpace(strings.TrimPrefix(username, "@")))
	if !chatUsernamePattern.MatchString(peer) {
		return "", chatRejected("Enter a username.")
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
		return "", chatRejected("No Social Save user has that username.")
	}
	label, err := saveSeenLocked(&c.data, userID, peer, raw)
	c.mu.Unlock()
	if err != nil {
		return "", err
	}
	c.persist(ctx)
	return label, nil
}
