package server

import (
	"strings"
	"testing"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

func TestPairStoreRoundTrip(t *testing.T) {
	var store pairStore
	code, expires := store.put([]models.PairItem{{
		Title:     "Flower",
		Platform:  "direct",
		SourceURL: "https://example.com/flower.mp4",
		Quality:   "original",
	}})
	if len(code) != 6 || !expires.After(time.Now()) {
		t.Fatalf("code %q expires %s", code, expires)
	}
	items, ok := store.get(strings.ToLower(code))
	if !ok || len(items) != 1 || items[0].Title != "Flower" {
		t.Fatalf("items = %#v ok=%v", items, ok)
	}
	if _, ok := store.get("MISSING"); ok {
		t.Fatal("unknown code should miss")
	}
}

func TestSanitizePairItemsDropsPathsAndCaps(t *testing.T) {
	items := sanitizePairItems([]models.PairItem{{
		Title:     "  Clip  ",
		Platform:  "youtube",
		SourceURL: "https://example.com/v",
		Quality:   "1080p",
	}, {Title: "   "}})
	if len(items) != 1 || items[0].Title != "Clip" {
		t.Fatalf("items = %#v", items)
	}
}

func TestOutputTextReadsMessageContent(t *testing.T) {
	raw := []byte(`{"output":[{"content":[{"type":"output_text","text":"A short note."}]}]}`)
	if got := outputText(raw); got != "A short note." {
		t.Fatal(got)
	}
	if got := outputText([]byte(`{"output_text":"Hello"}`)); got != "Hello" {
		t.Fatal(got)
	}
}
