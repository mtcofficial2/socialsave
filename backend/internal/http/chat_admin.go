package server

import (
	"context"
	"net/http"
	"sort"
)

const (
	chatAdminUsername = "daniel256"
	chatAdminPhone    = "256703487378"
)

func chatIsAdmin(user chatUser) bool {
	return user.Username == chatAdminUsername && user.Phone == chatAdminPhone
}

// chatReservedAccount keeps @daniel256 on the admin phone number.
func chatReservedAccount(username, phone string) (bool, string) {
	if username == chatAdminUsername && phone != chatAdminPhone {
		return true, "That username is taken."
	}
	if phone == chatAdminPhone && username != chatAdminUsername {
		return true, "That phone number already has a Social Save username."
	}
	return false, ""
}

func chatAccountOverlaps(user chatUser, phone, email, username string) bool {
	if user.Username == username {
		return true
	}
	if phone != "" && user.Phone == phone {
		return true
	}
	if email != "" && user.Email == email {
		return true
	}
	return false
}

func chatSameSignIn(user chatUser, phone, email, username string) bool {
	if user.Username != username {
		return false
	}
	if phone != "" && user.Phone != phone {
		return false
	}
	if email != "" && user.Email != email {
		return false
	}
	if phone != "" && user.Phone == phone {
		return true
	}
	return email != "" && user.Email == email
}

func chatOverlapMessage(user chatUser, phone, email, username string) string {
	if phone != "" && user.Phone == phone && user.Username != username {
		return "That phone number already has a Social Save username."
	}
	if email != "" && user.Email == email && user.Username != username {
		return "That email already has a Social Save username."
	}
	return "That username is taken."
}

type chatAdminRow struct {
	Username    string `json:"username"`
	Phone       string `json:"phone,omitempty"`
	Email       string `json:"email,omitempty"`
	Created     int64  `json:"created"`
	LastSeen    int64  `json:"lastSeen,omitempty"`
	HasPassword bool   `json:"hasPassword"`
}

func (c *chatRoom) adminUsers(ctx context.Context) []chatAdminRow {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := make([]chatAdminRow, 0, len(c.data.Users))
	for _, user := range c.data.Users {
		rows = append(rows, chatAdminRow{
			Username:    user.Username,
			Phone:       user.Phone,
			Email:       user.Email,
			Created:     user.Created,
			LastSeen:    user.LastSeen,
			HasPassword: user.PasswordHash != "",
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Created != rows[j].Created {
			return rows[i].Created > rows[j].Created
		}
		return rows[i].Username < rows[j].Username
	})
	return rows
}

// storageState says where accounts are kept: "s3", "s3-error" (stored
// accounts could not be read), or "temporary" (lost when the server restarts).
func (c *chatRoom) storageState() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.blob == nil {
		return "temporary"
	}
	if c.blobFailed {
		return "s3-error"
	}
	return "s3"
}

func (s *Server) chatAdminUsers(w http.ResponseWriter, r *http.Request) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return
	}
	if !chatIsAdmin(user) {
		writeChatError(w, http.StatusForbidden, "You cannot open that list.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"success": true,
		"users":   s.chat.adminUsers(r.Context()),
		"storage": s.chat.storageState(),
	})
}
