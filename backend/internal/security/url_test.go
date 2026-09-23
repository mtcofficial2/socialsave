package security

import (
	"context"
	"errors"
	"net"
	"testing"
)

func TestRejectsLoopbackIP(t *testing.T) {
	validator := NewValidator()
	_, err := validator.Validate(context.Background(), "http://127.0.0.1/video.mp4")
	if err == nil {
		t.Fatal("expected http://127.0.0.1 to be rejected")
	}
}

func TestRejectsPrivateAndReservedHosts(t *testing.T) {
	validator := NewValidator()
	blocked := []string{
		"http://localhost/video.mp4",
		"http://foo.localhost/video.mp4",
		"http://metadata.google.internal/computeMetadata/v1/",
		"http://10.1.2.3/video.mp4",
		"http://192.168.1.10/video.mp4",
		"http://172.16.0.5/video.mp4",
		"http://169.254.169.254/latest/meta-data/",
		"http://100.64.0.1/video.mp4",
		"http://[::1]/video.mp4",
		"file:///etc/passwd",
		"https://user:pass@example.com/video.mp4",
	}
	for _, raw := range blocked {
		if _, err := validator.Validate(context.Background(), raw); err == nil {
			t.Errorf("expected %s to be rejected", raw)
		}
	}
}

func TestRejectsHostnameThatResolvesPrivate(t *testing.T) {
	validator := NewValidator()
	validator.Lookup = func(context.Context, string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("127.0.0.1")}, nil
	}
	_, err := validator.Validate(context.Background(), "https://rebind.example/video.mp4")
	if err == nil {
		t.Fatal("expected a host that resolves to loopback to be rejected")
	}
}

func TestRejectsUnresolvedHost(t *testing.T) {
	validator := NewValidator()
	validator.Lookup = func(context.Context, string) ([]net.IP, error) {
		return nil, errors.New("no such host")
	}
	if _, err := validator.Validate(context.Background(), "https://missing.example/video.mp4"); err == nil {
		t.Fatal("expected unresolved host to be rejected")
	}
}

func TestAcceptsPublicIPLiteral(t *testing.T) {
	validator := NewValidator()
	got, err := validator.Validate(context.Background(), "https://93.184.216.34/video.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if got != "https://93.184.216.34/video.mp4" {
		t.Fatalf("got %s", got)
	}
}
