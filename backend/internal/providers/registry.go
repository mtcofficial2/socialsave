package providers

import (
	"context"
	"io"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
	"github.com/aviation256444-boop/socialsave/backend/internal/security"
)

const publicNote = "Public videos can be saved when the source is reachable without a login."

// Registry maps a URL host to a provider and keeps the shared yt-dlp runner.
type Registry struct {
	items  []Provider
	runner *Runner
	cfg    config.Config
}

// NewRegistry builds the platform list in the order Flutter expects.
func NewRegistry(cfg config.Config, validator *security.Validator) *Registry {
	fetch := NewFetcher(validator, cfg.RequestTimeout, cfg.MaxRedirects)
	runner := NewRunner()
	social := func(id, display string, hosts []string) *Social {
		return &Social{
			id:      id,
			display: display,
			hosts:   hosts,
			notes:   publicNote,
			cfg:     cfg,
			fetch:   fetch,
			runner:  runner,
		}
	}
	return &Registry{
		cfg:    cfg,
		runner: runner,
		items: []Provider{
			NewTikTok(cfg),
			social("instagram", "Instagram", []string{"instagram.com", "instagr.am"}),
			social("facebook", "Facebook", []string{"facebook.com", "fb.com", "fb.watch"}),
			social("x", "X", []string{"x.com", "twitter.com"}),
			social("youtube", "YouTube", []string{"youtube.com", "youtu.be", "youtube-nocookie.com"}),
			social("reddit", "Reddit", []string{"reddit.com", "v.redd.it"}),
			social("pinterest", "Pinterest", []string{"pinterest.com", "pin.it"}),
			&Direct{cfg: cfg, fetch: fetch, runner: runner},
		},
	}
}

// All returns providers in catalog order.
func (r *Registry) All() []Provider {
	return append([]Provider(nil), r.items...)
}

// Enabled reports the configured switch for a provider.
func (r *Registry) Enabled(provider Provider) bool {
	return r.cfg.Enabled(provider.ID())
}

// Resolve finds the provider for a URL. A disabled match is platform_disabled.
// Unknown hosts fall through to direct when that provider is enabled.
func (r *Registry) Resolve(rawURL string) (Provider, error) {
	for _, provider := range r.items {
		if provider.CanHandle(rawURL) {
			if !r.Enabled(provider) {
				return nil, errs.PlatformDisabled()
			}
			return provider, nil
		}
	}
	for _, provider := range r.items {
		if provider.ID() == "direct" && r.Enabled(provider) {
			return provider, nil
		}
	}
	return nil, errs.UnsupportedPlatform()
}

// Prepare downloads a file with yt-dlp into workDir.
func (r *Registry) Prepare(ctx context.Context, rawURL, formatID, workDir string, progress func(float64)) (DownloadResult, error) {
	return r.runner.Download(ctx, rawURL, formatID, r.cfg, workDir, progress)
}

// WritePlayable streams one fragmented MP4 for the in-app player.
func (r *Registry) WritePlayable(ctx context.Context, pageURL string, dst io.Writer) error {
	return r.runner.WritePlayable(ctx, pageURL, dst)
}
