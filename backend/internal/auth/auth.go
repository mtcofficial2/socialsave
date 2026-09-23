// Package auth checks the optional shared API key.
package auth

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

// Authorize allows the request when API keys are not required, or when
// X-API-Key or Authorization: Bearer matches a configured key.
// A Bearer header wins over X-API-Key, matching the previous API.
func Authorize(r *http.Request, cfg config.Config) error {
	if !cfg.RequireAPIKey {
		return nil
	}
	token := r.Header.Get("X-API-Key")
	if header := r.Header.Get("Authorization"); len(header) >= 7 && strings.EqualFold(header[:7], "bearer ") {
		token = strings.TrimSpace(header[7:])
	}
	if token == "" || !matches(token, cfg.APIKeys) {
		return errs.Unauthorized()
	}
	return nil
}

func matches(got string, keys []string) bool {
	ok := 0
	gb := []byte(got)
	for _, key := range keys {
		kb := []byte(key)
		if len(gb) != len(kb) {
			continue
		}
		ok |= subtle.ConstantTimeCompare(gb, kb)
	}
	return ok == 1
}
