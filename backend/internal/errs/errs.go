// Package errs is the JSON error contract shared with the Flutter client.
package errs

import "net/http"

// Error is a coded API failure. StatusCode is the HTTP status.
type Error struct {
	Code       string
	Message    string
	StatusCode int
}

func (e *Error) Error() string {
	if e == nil {
		return ""
	}
	return e.Code + ": " + e.Message
}

func newError(code, message string, status int) *Error {
	return &Error{Code: code, Message: message, StatusCode: status}
}

func InvalidURL(message string) *Error {
	if message == "" {
		message = "That URL cannot be used."
	}
	return newError("invalid_url", message, http.StatusBadRequest)
}

func UnsupportedPlatform() *Error {
	return newError(
		"unsupported_platform",
		"This platform is not supported, or it has been disabled.",
		http.StatusBadRequest,
	)
}

func PlatformDisabled() *Error {
	return newError(
		"platform_disabled",
		"This platform is turned off in the current configuration.",
		http.StatusForbidden,
	)
}

func PrivateVideo(message string) *Error {
	if message == "" {
		message = "Unable to access this video. Make sure the link is public and that downloading is permitted for this content."
	}
	return newError("private_video", message, http.StatusForbidden)
}

func RemovedVideo() *Error {
	return newError("removed_video", "This video is no longer available.", http.StatusNotFound)
}

func DownloadNotPermitted() *Error {
	return newError(
		"download_not_permitted",
		"This platform does not allow third-party apps to download the file. SocialSave will not bypass that restriction.",
		http.StatusForbidden,
	)
}

func UnsupportedFormat() *Error {
	return newError(
		"unsupported_format",
		"This file type is not a supported video format.",
		http.StatusUnsupportedMediaType,
	)
}

func FileTooLarge(maxBytes int64) *Error {
	if maxBytes <= 0 {
		maxBytes = 256 * 1024 * 1024
	}
	megabytes := maxBytes / (1024 * 1024)
	if megabytes < 1 {
		megabytes = 1
	}
	return newError(
		"file_too_large",
		"This file is larger than the "+itoa(megabytes)+" MB download limit.",
		http.StatusRequestEntityTooLarge,
	)
}

func Unauthorized() *Error {
	return newError("unauthorized", "Missing or invalid API key.", http.StatusUnauthorized)
}

func PlatformUnavailable(message string) *Error {
	if message == "" {
		message = "The source platform is temporarily unavailable. Try again later."
	}
	return newError("platform_unavailable", message, http.StatusServiceUnavailable)
}

func RateLimited() *Error {
	return newError(
		"rate_limited",
		"Too many requests. Please wait a moment and try again.",
		http.StatusTooManyRequests,
	)
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}
