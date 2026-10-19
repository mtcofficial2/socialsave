package providers

import "testing"

func TestYouTubeErrorsAreNotAllPrivate(t *testing.T) {
	u := "https://youtu.be/wvNPaKrDh4M?si=BqbWwTYO9s386ayL"
	cases := []struct {
		in, code, want string
	}{
		{"ERROR: [youtube] wvNPaKrDh4M: Sign in to confirm you're not a bot. Use --cookies-from-browser", "platform_unavailable", "bot check"},
		{"ERROR: [youtube] abc: Private video. Sign in if you've been granted access", "private_video", "private"},
		{"ERROR: [youtube] abc: Join this channel to get access to members-only content", "private_video", "members only"},
		{"ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", "private_video", "age-restricted"},
		{"ERROR: [youtube] abc: Video unavailable", "removed_video", ""},
	}
	for _, c := range cases {
		got := MapExtractorError(c.in, u)
		if got.Code != c.code || (c.want != "" && !contains(got.Message, c.want)) {
			t.Errorf("%q -> %+v", c.in, got)
		}
	}
}
