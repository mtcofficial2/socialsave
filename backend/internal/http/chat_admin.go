package server

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
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
		"devices": s.chat.adminDevices(r.Context()),
		"storage": s.chat.storageState(),
	})
}

const (
	chatInstallKeep  = 2000
	chatInstallQuiet = int64(2 * 60 * 1000)
)

func installIDOk(id string) bool {
	if len(id) != 32 {
		return false
	}
	for _, r := range id {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func installPlatformOk(value string) bool {
	switch value {
	case "android", "windows", "ios", "macos", "linux", "web":
		return true
	default:
		return false
	}
}

func installVersionOk(value string) bool {
	if len(value) < 3 || len(value) > 16 || !strings.Contains(value, ".") {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && r != '.' {
			return false
		}
	}
	return true
}

func cleanInstallName(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	var b strings.Builder
	n := 0
	for _, r := range value {
		if r < 32 || r == 127 {
			continue
		}
		b.WriteRune(r)
		n++
		if n >= 40 {
			break
		}
	}
	return strings.TrimSpace(b.String())
}

// noteInstall remembers that a copy of the app was opened. An existing id
// updates in place. A new id is limited per network so the list cannot be
// filled with made-up devices. False means the new device was refused.
// Name and model are labels. An empty one does not erase a label already stored.
func (c *chatRoom) noteInstall(ctx context.Context, id, platform, version, name, model, username, ip string, download bool) bool {
	c.ensure(ctx)
	now := time.Now().UnixMilli()
	c.mu.Lock()
	for i := range c.data.Installs {
		row := &c.data.Installs[i]
		if row.ID != id {
			continue
		}
		changed := row.Platform != platform || row.Version != version || (name != "" && row.Name != name) || (model != "" && row.Model != model) || (username != "" && row.Username != username) || download
		stale := now-row.Seen >= chatInstallQuiet
		row.Platform = platform
		row.Version = version
		row.Seen = now
		if name != "" {
			row.Name = name
		}
		if model != "" {
			row.Model = model
		}
		if username != "" {
			row.Username = username
		}
		if download {
			row.Downloads++
			row.LastDownload = now
		}
		c.mu.Unlock()
		if changed || stale {
			c.persist(ctx)
		}
		return true
	}
	if ip == "" {
		ip = "unknown"
	}
	if !c.allowLocked(c.opens, ip, 8) {
		c.mu.Unlock()
		return false
	}
	downloads := 0
	var lastDownload int64
	if download {
		downloads = 1
		lastDownload = now
	}
	c.data.Installs = append(c.data.Installs, chatInstall{
		ID:           id,
		Platform:     platform,
		Version:      version,
		Name:         name,
		Model:        model,
		Username:     username,
		First:        now,
		Seen:         now,
		Downloads:    downloads,
		LastDownload: lastDownload,
	})
	if len(c.data.Installs) > chatInstallKeep {
		sort.Slice(c.data.Installs, func(i, j int) bool {
			return c.data.Installs[i].Seen < c.data.Installs[j].Seen
		})
		c.data.Installs = append([]chatInstall(nil), c.data.Installs[len(c.data.Installs)-chatInstallKeep:]...)
	}
	c.mu.Unlock()
	c.persist(ctx)
	return true
}

func (c *chatRoom) adminDevices(ctx context.Context) []chatInstall {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := make([]chatInstall, len(c.data.Installs))
	copy(rows, c.data.Installs)
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Seen != rows[j].Seen {
			return rows[i].Seen > rows[j].Seen
		}
		return rows[i].ID < rows[j].ID
	})
	return rows
}

func (s *Server) appOpened(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ID       string `json:"id"`
		Platform string `json:"platform"`
		Version  string `json:"version"`
		Name     string `json:"name"`
		Model    string `json:"model"`
		Download bool   `json:"download"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1024)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That device could not be recorded.")
		return
	}
	id := strings.ToLower(strings.TrimSpace(body.ID))
	platform := strings.ToLower(strings.TrimSpace(body.Platform))
	version := strings.TrimSpace(body.Version)
	if !installIDOk(id) || !installPlatformOk(platform) || !installVersionOk(version) {
		writeChatError(w, http.StatusBadRequest, "That device could not be recorded.")
		return
	}
	username := ""
	if token := strings.TrimSpace(r.Header.Get(chatTokenHeader)); token != "" {
		if user, ok := s.chat.userByToken(r.Context(), token); ok {
			username = user.Username
		}
	}
	if !s.chat.noteInstall(r.Context(), id, platform, version, cleanInstallName(body.Name), cleanInstallName(body.Model), username, clientIP(r), body.Download) {
		writeChatError(w, http.StatusTooManyRequests, "Too many new devices from this network. Try again in a minute.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
