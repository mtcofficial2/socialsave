package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/http"
	"github.com/aviation256444-boop/socialsave/backend/internal/providers"
)

func main() {
	cfg := config.Load()
	if cfg.Environment == "production" && cfg.SecretKey == "change-me-in-production" {
		slog.Warn("SECRET_KEY is still the default; set a long random value before exposing this API")
	}
	app := server.New(cfg, nil, nil)
	httpServer := &http.Server{
		Addr:              cfg.BindAddr + ":" + cfg.Port,
		Handler:           app.Router(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if os.Getenv("EXIT_WITH_STDIN") == "1" {
		// The desktop app holds our stdin open. When the app exits (or is
		// killed) the pipe closes and the engine stops with it.
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			stop()
		}()
	}
	providers.Configure(cfg)
	go app.Jobs.Run(ctx)
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdown)
	}()
	slog.Info("api ready", "port", cfg.Port, "max_download_bytes", cfg.MaxDownloadBytes, "default_max_height", cfg.DefaultMaxHeight)
	err := httpServer.ListenAndServe()
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server stopped", "err", err)
		os.Exit(1)
	}
}
