package server

import (
	"context"
	"crypto/subtle"
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
	Username    string            `json:"username"`
	Phone       string            `json:"phone,omitempty"`
	Email       string            `json:"email,omitempty"`
	Created     int64             `json:"created"`
	LastSeen    int64             `json:"lastSeen,omitempty"`
	HasPassword bool              `json:"hasPassword"`
	HasRecovery bool              `json:"hasRecovery,omitempty"`
	Disabled    bool              `json:"disabled,omitempty"`
	Sessions    []chatSessionView `json:"sessions,omitempty"`
}

type chatAdminGroup struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Owner    string `json:"owner,omitempty"`
	Members  int    `json:"members"`
	Created  int64  `json:"created,omitempty"`
	Announce bool   `json:"announce,omitempty"`
}

type chatAdminReport struct {
	ID     string `json:"id"`
	From   string `json:"from"`
	Target string `json:"target"`
	Reason string `json:"reason,omitempty"`
	At     int64  `json:"at"`
}

func (c *chatRoom) adminUsers(ctx context.Context, current string) []chatAdminRow {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := make([]chatAdminRow, 0, len(c.data.Users))
	for i := range c.data.Users {
		user := &c.data.Users[i]
		rows = append(rows, chatAdminRow{
			Username:    user.Username,
			Phone:       user.Phone,
			Email:       user.Email,
			Created:     user.Created,
			LastSeen:    user.LastSeen,
			HasPassword: user.PasswordHash != "",
			HasRecovery: user.RecoveryHash != "",
			Disabled:    user.Disabled,
			Sessions:    sessionViewsLocked(user, current),
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
	current := chatTokenHash(r.Header.Get(chatTokenHeader))
	writeJSON(w, http.StatusOK, map[string]any{
		"success":     true,
		"users":       s.chat.adminUsers(r.Context(), current),
		"devices":     s.chat.adminDevices(r.Context()),
		"groups":      s.chat.adminGroups(r.Context()),
		"reports":     s.chat.adminReports(r.Context()),
		"storage":     s.chat.storageState(),
		"deviceLimit": chatInstallKeep,
	})
}

func (s *Server) chatAdminActor(w http.ResponseWriter, r *http.Request) (chatUser, bool) {
	user, ok := s.chatActor(w, r)
	if !ok {
		return chatUser{}, false
	}
	if !chatIsAdmin(user) {
		writeChatError(w, http.StatusForbidden, "You cannot open that list.")
		return chatUser{}, false
	}
	return user, true
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
// A signed-in open stores that username. A signed-out open keeps the last
// username and clears the signed-in flag.
func (c *chatRoom) noteInstall(ctx context.Context, id, platform, version, name, model, username string, signedIn bool, ip string, download bool) bool {
	c.ensure(ctx)
	now := time.Now().UnixMilli()
	c.mu.Lock()
	for i := range c.data.Installs {
		row := &c.data.Installs[i]
		if row.ID != id {
			continue
		}
		account := row.Username
		on := row.SignedIn
		if signedIn && username != "" {
			account = username
			on = true
		} else if !signedIn {
			on = false
		}
		changed := row.Platform != platform || row.Version != version || (name != "" && row.Name != name) || (model != "" && row.Model != model) || account != row.Username || on != row.SignedIn || download
		stale := now-row.Seen >= chatInstallQuiet
		row.Platform = platform
		row.Version = version
		row.Seen = now
		row.Username = account
		row.SignedIn = on
		if name != "" {
			row.Name = name
		}
		if model != "" {
			row.Model = model
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
	account := ""
	on := false
	if signedIn && username != "" {
		account = username
		on = true
	}
	c.data.Installs = append(c.data.Installs, chatInstall{
		ID:           id,
		Platform:     platform,
		Version:      version,
		Name:         name,
		Model:        model,
		Username:     account,
		SignedIn:     on,
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
	signedIn := false
	if token := strings.TrimSpace(r.Header.Get(chatTokenHeader)); token != "" {
		if user, ok := s.chat.userByToken(r.Context(), token); ok && user.Username != "" {
			username = user.Username
			signedIn = true
		}
	}
	if !s.chat.noteInstall(r.Context(), id, platform, version, cleanInstallName(body.Name), cleanInstallName(body.Model), username, signedIn, clientIP(r), body.Download) {
		writeChatError(w, http.StatusTooManyRequests, "Too many new devices from this network. Try again in a minute.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func accountDisabled(user chatUser) error {
	if user.Disabled {
		return chatRejected("This account is disabled.")
	}
	return nil
}

func (c *chatRoom) userByNameLocked(username string) *chatUser {
	for i := range c.data.Users {
		if c.data.Users[i].Username == username {
			return &c.data.Users[i]
		}
	}
	return nil
}

func (c *chatRoom) adminGroups(ctx context.Context) []chatAdminGroup {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := make([]chatAdminGroup, 0)
	for i := range c.data.Threads {
		thread := &c.data.Threads[i]
		if len(thread.Members) == 0 {
			continue
		}
		owner := ""
		if person, ok := c.userLocked(thread.Owner); ok {
			owner = person.Username
		}
		created := thread.Created
		if created == 0 {
			for _, msg := range thread.Messages {
				if msg.At > 0 && (created == 0 || msg.At < created) {
					created = msg.At
				}
			}
		}
		rows = append(rows, chatAdminGroup{
			ID:       thread.ID,
			Name:     thread.Title,
			Owner:    owner,
			Members:  len(thread.Members),
			Created:  created,
			Announce: thread.Announce,
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Created != rows[j].Created {
			return rows[i].Created > rows[j].Created
		}
		return rows[i].Name < rows[j].Name
	})
	return rows
}

func (c *chatRoom) adminReports(ctx context.Context) []chatAdminReport {
	c.ensure(ctx)
	c.mu.Lock()
	defer c.mu.Unlock()
	rows := make([]chatAdminReport, 0, len(c.data.Reports))
	for _, report := range c.data.Reports {
		from := usernameLocked(c, report.From)
		target := usernameLocked(c, report.Target)
		if from == "" {
			from = "Removed account"
		}
		if target == "" {
			target = "Removed account"
		}
		rows = append(rows, chatAdminReport{
			ID:     report.ID,
			From:   from,
			Target: target,
			Reason: report.Reason,
			At:     report.At,
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].At != rows[j].At {
			return rows[i].At > rows[j].At
		}
		return rows[i].ID < rows[j].ID
	})
	return rows
}

func usernameLocked(c *chatRoom, id string) string {
	person, ok := c.userLocked(id)
	if !ok {
		return ""
	}
	return person.Username
}

func (c *chatRoom) setDisabled(ctx context.Context, actor chatUser, username string, disabled bool) error {
	if !chatIsAdmin(actor) {
		return chatRejected("You cannot open that list.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return err
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userByNameLocked(name)
	if user == nil {
		c.mu.Unlock()
		return chatRejected("No Social Save user has that username.")
	}
	if disabled && chatIsAdmin(*user) {
		c.mu.Unlock()
		return chatRejected("That account stays open.")
	}
	user.Disabled = disabled
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatAdminDisable(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatAdminActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		Disabled bool   `json:"disabled"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That account could not be changed.")
		return
	}
	if err := s.chat.setDisabled(r.Context(), actor, body.Username, body.Disabled); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (c *chatRoom) adminEndSession(ctx context.Context, actor chatUser, current, username, prefix string) error {
	if !chatIsAdmin(actor) {
		return chatRejected("You cannot open that list.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return err
	}
	prefix = strings.ToLower(strings.TrimSpace(prefix))
	if len(prefix) < 8 || len(prefix) > 64 || !hexPrefix(prefix) {
		return chatRejected("That device was not found.")
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userByNameLocked(name)
	if user == nil {
		c.mu.Unlock()
		return chatRejected("No Social Save user has that username.")
	}
	match := ""
	count := 0
	seen := map[string]bool{}
	consider := func(hash string) {
		if hash == "" || seen[hash] || !strings.HasPrefix(hash, prefix) {
			return
		}
		seen[hash] = true
		count++
		match = hash
	}
	for _, hash := range user.Sessions {
		consider(hash)
	}
	consider(user.TokenHash)
	if count == 0 {
		c.mu.Unlock()
		return chatRejected("That device was not found.")
	}
	if count > 1 {
		c.mu.Unlock()
		return chatRejected("Say which device.")
	}
	if user.ID == actor.ID && subtle.ConstantTimeCompare([]byte(match), []byte(current)) == 1 {
		c.mu.Unlock()
		return chatRejected("This is the device you are using.")
	}
	dropSessionHash(user, match)
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (c *chatRoom) adminEndSessions(ctx context.Context, actor chatUser, current, username string) error {
	if !chatIsAdmin(actor) {
		return chatRejected("You cannot open that list.")
	}
	name, err := cleanChatUsername(username)
	if err != nil {
		return err
	}
	if name == actor.Username {
		return c.endOtherSessions(ctx, actor.ID, current)
	}
	c.ensure(ctx)
	c.mu.Lock()
	user := c.userByNameLocked(name)
	if user == nil {
		c.mu.Unlock()
		return chatRejected("No Social Save user has that username.")
	}
	user.TokenHash = ""
	user.Sessions = nil
	user.Devices = nil
	c.mu.Unlock()
	c.persist(ctx)
	return nil
}

func (s *Server) chatAdminSessionEnd(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatAdminActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
		ID       string `json:"id"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 512)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That device was not found.")
		return
	}
	if err := s.chat.adminEndSession(r.Context(), actor, chatTokenHash(r.Header.Get(chatTokenHeader)), body.Username, body.ID); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

func (s *Server) chatAdminSessionsAll(w http.ResponseWriter, r *http.Request) {
	actor, ok := s.chatAdminActor(w, r)
	if !ok {
		return
	}
	var body struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 256)).Decode(&body); err != nil {
		writeChatError(w, http.StatusBadRequest, "That account could not be changed.")
		return
	}
	if err := s.chat.adminEndSessions(r.Context(), actor, chatTokenHash(r.Header.Get(chatTokenHeader)), body.Username); err != nil {
		writeChatFailure(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}
