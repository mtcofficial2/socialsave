package providers

import (
	"context"

	"github.com/aviation256444-boop/socialsave/backend/internal/models"
)

// Metadata is a normalized analyze result.
type Metadata struct {
	Platform                 string
	Title                    string
	SourceURL                string
	Thumbnail                *string
	Duration                 *int
	Author                   *string
	Formats                  []models.MediaFormat
	CanDownload              bool
	DownloadRestrictedReason *string
}

// Handle is what POST /download turns into a ticket or a job.
type Handle struct {
	SourceURL      string
	FormatID       string
	MimeType       string
	Filesize       *int64
	FileName       string
	UpstreamURL    string
	PrepareLocally bool
	Headers        map[string]string
	// Proxy means the phone should play or fetch the file through this API.
	// YouTube media URLs are tied to the computer that requested them.
	Proxy bool
	// Stream asks the API to build one playable MP4 and send it to the player.
	Stream bool
}

// Provider resolves one platform.
type Provider interface {
	ID() string
	SupportsMetadata() bool
	SupportsDownload() bool
	Notes() string
	CanHandle(rawURL string) bool
	Analyze(ctx context.Context, rawURL string) (Metadata, error)
	CreateDownload(ctx context.Context, rawURL, formatID string) (Handle, error)
}
