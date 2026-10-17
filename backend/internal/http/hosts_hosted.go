//go:build !windows

package server

import (
	"strings"
	"time"
)

// prepareTimeout caps one server-side prepare (hosted: shared machine).
const prepareTimeout = 10 * time.Minute

// Host names of the hosted deployments. The Windows engine is built without
// them (see hosts_windows.go): it only ever runs on 127.0.0.1.
var httpsProxyHosts = []string{"workers.dev", "cloudflare", "koyeb.app", "onrender.com"}

func isHostedAPIHost(host string) bool { return strings.Contains(host, "onrender.com") }

func isHTTPSProxyHost(host string) bool {
	for _, item := range httpsProxyHosts {
		if strings.Contains(host, item) {
			return true
		}
	}
	return false
}
