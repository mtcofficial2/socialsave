package providers

import (
	"bytes"
	"encoding/json"
	"strconv"
)

// flexInt accepts the ints, floats, and numeric strings yt-dlp emits.
type flexInt struct {
	N *int64
}

func (f *flexInt) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || bytes.Equal(data, []byte("null")) || bytes.Equal(data, []byte(`""`)) {
		return nil
	}
	var number int64
	if err := json.Unmarshal(data, &number); err == nil {
		f.N = &number
		return nil
	}
	var float float64
	if err := json.Unmarshal(data, &float); err == nil {
		number = int64(float)
		f.N = &number
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err != nil || text == "" {
		return nil
	}
	if parsed, err := strconv.ParseInt(text, 10, 64); err == nil {
		f.N = &parsed
		return nil
	}
	if parsed, err := strconv.ParseFloat(text, 64); err == nil {
		number = int64(parsed)
		f.N = &number
	}
	return nil
}
