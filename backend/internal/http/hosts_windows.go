//go:build windows

package server

import "time"

// prepareTimeout: the desktop engine downloads long 1080p/4K videos on the
// user's own connection; the app stops a job that stalls (see download_manager).
const prepareTimeout = 6 * time.Hour

// The Windows build is the desktop app's local engine on 127.0.0.1. It knows
// no hosted API hosts and never proxies through one.
func isHostedAPIHost(string) bool { return false }

func isHTTPSProxyHost(string) bool { return false }
