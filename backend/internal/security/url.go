// Package security checks outbound URLs for SSRF before the API fetches or redirects.
package security

import (
	"context"
	"errors"
	"net"
	"net/url"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

// ErrBlockedAddress is returned by a dialer when the resolved address is not public.
var ErrBlockedAddress = errors.New("blocked address")

// Validator resolves hosts and rejects private or local targets.
type Validator struct {
	Lookup func(ctx context.Context, host string) ([]net.IP, error)
}

// NewValidator uses the system resolver.
func NewValidator() *Validator {
	return &Validator{Lookup: defaultLookup}
}

func defaultLookup(ctx context.Context, host string) ([]net.IP, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return net.DefaultResolver.LookupIP(ctx, "ip", host)
}

var blockedNets = mustCIDRs(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
	"255.255.255.255/32",
	"::1/128",
	"fc00::/7",
	"fe80::/10",
	"fec0::/10",
	"ff00::/8",
	"2001:db8::/32",
)

func mustCIDRs(values ...string) []*net.IPNet {
	nets := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic(err)
		}
		nets = append(nets, network)
	}
	return nets
}

// IsBlockedIP reports whether ip is loopback, private, link-local, reserved, or CGNAT.
func IsBlockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return true
	}
	for _, network := range blockedNets {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

// Validate returns the trimmed URL when it is an http(s) URL on a public host.
func (v *Validator) Validate(ctx context.Context, raw string) (string, error) {
	if v == nil {
		v = NewValidator()
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if strings.TrimSpace(raw) == "" {
		return "", errs.InvalidURL("")
	}
	trimmed := strings.TrimSpace(raw)
	if len(trimmed) > 4096 || strings.ContainsAny(trimmed, " \t\r\n") {
		return "", errs.InvalidURL("That URL is not valid.")
	}
	for _, r := range trimmed {
		if r < 0x20 || r == 0x7f {
			return "", errs.InvalidURL("That URL is not valid.")
		}
	}
	parsed, err := url.Parse(trimmed)
	if err != nil || parsed.Host == "" {
		return "", errs.InvalidURL("That URL is not valid.")
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return "", errs.InvalidURL("Only http and https URLs are allowed.")
	}
	if parsed.User != nil {
		return "", errs.InvalidURL("URLs with embedded credentials are not allowed.")
	}
	host := strings.ToLower(strings.TrimSuffix(parsed.Hostname(), "."))
	if host == "" || host == "localhost" || strings.HasSuffix(host, ".localhost") || host == "metadata.google.internal" {
		return "", errs.InvalidURL("That host cannot be used.")
	}
	if ip := net.ParseIP(host); ip != nil {
		if IsBlockedIP(ip) {
			return "", errs.InvalidURL("Private or local network addresses are not allowed.")
		}
		return trimmed, nil
	}
	lookup := v.Lookup
	if lookup == nil {
		lookup = defaultLookup
	}
	ips, err := lookup(ctx, host)
	if err != nil || len(ips) == 0 {
		return "", errs.InvalidURL("The host could not be resolved.")
	}
	for _, ip := range ips {
		if IsBlockedIP(ip) {
			return "", errs.InvalidURL("Private or local network addresses are not allowed.")
		}
	}
	return trimmed, nil
}

// DialContext pins the connection to a public address from this lookup.
func (v *Validator) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	ips, err := v.resolve(ctx, host)
	if err != nil {
		return nil, err
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	var last error
	for _, ip := range ips {
		if IsBlockedIP(ip) {
			last = ErrBlockedAddress
			continue
		}
		conn, dialErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if dialErr == nil {
			return conn, nil
		}
		last = dialErr
	}
	if last == nil {
		last = ErrBlockedAddress
	}
	return nil, last
}

func (v *Validator) resolve(ctx context.Context, host string) ([]net.IP, error) {
	if ip := net.ParseIP(host); ip != nil {
		if IsBlockedIP(ip) {
			return nil, ErrBlockedAddress
		}
		return []net.IP{ip}, nil
	}
	lookup := v.Lookup
	if lookup == nil {
		lookup = defaultLookup
	}
	ips, err := lookup(ctx, host)
	if err != nil {
		return nil, err
	}
	return ips, nil
}
