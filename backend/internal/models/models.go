// Package models holds the JSON shapes the Flutter client already decodes.
package models

// AnalyzeRequest is POST /api/v1/analyze.
type AnalyzeRequest struct {
	URL string `json:"url"`
}

// DownloadRequest is POST /api/v1/download.
type DownloadRequest struct {
	URL      string `json:"url"`
	FormatID string `json:"format_id"`
}

// MediaFormat is one selectable quality.
type MediaFormat struct {
	ID       string `json:"id"`
	Quality  string `json:"quality"`
	Format   string `json:"format"`
	Filesize *int64 `json:"filesize"`
	Width    *int   `json:"width"`
	Height   *int   `json:"height"`
	HasAudio bool   `json:"has_audio"`
	HasVideo bool   `json:"has_video"`
}

// AnalyzeResponse is the metadata payload.
type AnalyzeResponse struct {
	Success                  bool          `json:"success"`
	Platform                 string        `json:"platform"`
	Title                    string        `json:"title"`
	Thumbnail                *string       `json:"thumbnail"`
	Duration                 *int          `json:"duration"`
	Author                   *string       `json:"author"`
	URL                      string        `json:"url"`
	Formats                  []MediaFormat `json:"formats"`
	CanDownload              bool          `json:"can_download"`
	DownloadRestrictedReason *string       `json:"download_restricted_reason"`
}

// DownloadResponse is either a ready ticket or a processing job.
type DownloadResponse struct {
	Success        bool              `json:"success"`
	DownloadURL    string            `json:"download_url"`
	DirectURL      *string           `json:"direct_url"`
	ID             *string           `json:"id"`
	State          string            `json:"state"`
	ExpiresAt      *string           `json:"expires_at"`
	MimeType       *string           `json:"mime_type"`
	Filesize       *int64            `json:"filesize"`
	FileName       *string           `json:"file_name"`
	RequestHeaders map[string]string `json:"request_headers"`
}

// PlatformStatus is one entry in the catalog.
type PlatformStatus struct {
	ID               string  `json:"id"`
	Enabled          bool    `json:"enabled"`
	SupportsMetadata bool    `json:"supports_metadata"`
	SupportsDownload bool    `json:"supports_download"`
	Notes            *string `json:"notes"`
}

// PlatformsResponse is GET /api/v1/platforms.
type PlatformsResponse struct {
	Success   bool             `json:"success"`
	Platforms []PlatformStatus `json:"platforms"`
}

// ErrorBody is the nested error object.
type ErrorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ErrorResponse is every JSON failure.
type ErrorResponse struct {
	Success bool      `json:"success"`
	Error   ErrorBody `json:"error"`
}

// JobStatusResponse is GET /api/v1/download/{job_id}.
type JobStatusResponse struct {
	Success     bool       `json:"success"`
	ID          string     `json:"id"`
	State       string     `json:"state"`
	DownloadURL string     `json:"download_url"`
	Error       *ErrorBody `json:"error"`
	Progress    float64    `json:"progress"`
	Filesize    *int64     `json:"filesize"`
	FileName    string     `json:"file_name"`
}

// TikTokResponse is POST /api/v1/tiktok and POST /api/tiktok.
type TikTokResponse struct {
	Success     bool   `json:"success"`
	Platform    string `json:"platform"`
	VideoURL    string `json:"videoUrl"`
	Author      string `json:"author"`
	Caption     string `json:"caption"`
	Duration    int    `json:"duration"`
	Width       int    `json:"width"`
	Height      int    `json:"height"`
	CoverURL    string `json:"coverUrl"`
	Watermarked bool   `json:"watermarked"`
}

// HealthResponse is GET /health.
type HealthResponse struct {
	Status  string `json:"status"`
	Version string `json:"version"`
}
