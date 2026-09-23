package tokens

import (
	"strings"
	"testing"
	"time"
)

func TestRoundTripRemoteToken(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	service := New("test-secret", time.Hour).WithClock(func() time.Time { return now })
	size := int64(1234)
	token, err := service.IssueRemote(
		"https://cdn.example.com/a.mp4",
		"video/mp4",
		"a.mp4",
		268435456,
		map[string]string{"User-Agent": "test", "Referer": "https://example.com/"},
		&size,
		false,
	)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(token, ".") != 1 {
		t.Fatalf("token = %q", token)
	}
	claims, err := service.Parse(token)
	if err != nil {
		t.Fatal(err)
	}
	if claims.URL != "https://cdn.example.com/a.mp4" || claims.MIME != "video/mp4" || claims.Name != "a.mp4" {
		t.Fatalf("claims = %+v", claims)
	}
	if claims.Size == nil || *claims.Size != 1234 {
		t.Fatalf("size = %v", claims.Size)
	}
	if claims.Headers["Referer"] != "https://example.com/" {
		t.Fatalf("headers = %#v", claims.Headers)
	}
	if claims.Exp != now.Unix()+3600 {
		t.Fatalf("exp = %d", claims.Exp)
	}
}

func TestRejectsTamperedToken(t *testing.T) {
	service := New("test-secret", time.Hour)
	token, err := service.IssueRemote("https://cdn.example.com/a.mp4", "video/mp4", "a.mp4", 10, nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	tampered := token[:len(token)-1] + flip(token[len(token)-1])
	if _, err := service.Parse(tampered); err == nil {
		t.Fatal("expected tampered token to fail")
	}
}

func TestRejectsWrongSecret(t *testing.T) {
	issued := New("one", time.Hour)
	token, err := issued.IssueJob("abc", "video/mp4", "video.mp4")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := New("two", time.Hour).Parse(token); err == nil {
		t.Fatal("expected wrong secret to fail")
	}
}

func TestRejectsExpiredToken(t *testing.T) {
	start := time.Unix(1_700_000_000, 0).UTC()
	current := start
	service := New("test-secret", time.Minute).WithClock(func() time.Time { return current })
	token, err := service.IssueRemote("https://cdn.example.com/a.mp4", "video/mp4", "a.mp4", 10, nil, nil, false)
	if err != nil {
		t.Fatal(err)
	}
	current = start.Add(2 * time.Minute)
	if _, err := service.Parse(token); err == nil {
		t.Fatal("expected expired token to fail")
	}
}

func flip(b byte) string {
	if b == 'a' {
		return "b"
	}
	return "a"
}
