package providers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
	"github.com/aviation256444-boop/socialsave/backend/internal/errs"
)

// Runner shells out to yt-dlp for platforms that already use it.
// It does not pass YouTube client overrides, impersonation, or alternate frontends.
type Runner struct {
	bin string
	sem chan struct{}
}

// NewRunner looks up yt-dlp on PATH. A missing binary fails at call time.
func NewRunner() *Runner {
	return &Runner{
		bin: findYTDLP(),
		sem: make(chan struct{}, 2),
	}
}

func findYTDLP() string {
	if path, err := exec.LookPath("yt-dlp"); err == nil {
		return path
	}
	var candidates []string
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		candidates = append(candidates, filepath.Join(local, "SocialSave", "yt-dlp.exe"))
	}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "yt-dlp.exe"), filepath.Join(filepath.Dir(exe), "yt-dlp"))
	}
	for _, candidate := range candidates {
		info, err := os.Stat(candidate)
		if err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

// Extract reads metadata and format URLs without downloading the file.
func (r *Runner) Extract(ctx context.Context, rawURL string, cfg config.Config) (mediaInfo, error) {
	if err := r.available(); err != nil {
		return mediaInfo{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	var stderr string
	var runErr error
	for _, extra := range attemptArgs(rawURL) {
		args := append(extractArgs(rawURL, cfg), extra...)
		args = append(args, "--", rawURL)
		stdout, errText, err := r.run(ctx, args, "")
		if err == nil {
			info, decErr := decodeInfo(stdout)
			if decErr != nil {
				return mediaInfo{}, decErr
			}
			return unwrapInfo(info)
		}
		stderr, runErr = errText, err
		if stopRetry(MapExtractorError(errText+"\n"+err.Error(), rawURL)) {
			break
		}
	}
	if runErr == nil {
		runErr = errs.PlatformUnavailable("")
	}
	return mediaInfo{}, MapExtractorError(stderr+"\n"+runErr.Error(), rawURL)
}

// DownloadResult is a prepared temp file.
type DownloadResult struct {
	Path     string
	MIME     string
	Name     string
	Filesize int64
}

// Download runs yt-dlp into workDir. progress receives 0..0.99 while bytes arrive.
func (r *Runner) Download(ctx context.Context, rawURL, formatID string, cfg config.Config, workDir string, progress func(float64)) (DownloadResult, error) {
	if err := r.available(); err != nil {
		return DownloadResult{}, err
	}
	ffmpeg := ffmpegDir()
	selector := FormatSelector(formatID, ffmpeg != "", cfg.DefaultMaxHeight)
	out := filepath.ToSlash(filepath.Join(workDir, "%(title).80B.%(ext)s"))
	var stderr string
	var runErr error
	for _, extra := range attemptArgs(rawURL) {
		clearPartials(workDir)
		args := downloadArgs(rawURL, cfg, selector, out, ffmpeg)
		args = append(args, extra...)
		args = append(args, "--", rawURL)
		_, errText, err := r.runProgress(ctx, args, workDir, progress)
		if err == nil {
			if _, statErr := largestMedia(workDir); statErr == nil {
				runErr = nil
				break
			}
			err = errs.UnsupportedFormat()
		}
		stderr, runErr = errText, err
		if stopRetry(MapExtractorError(errText+"\n"+err.Error(), rawURL)) {
			break
		}
	}
	if runErr != nil {
		return DownloadResult{}, MapExtractorError(stderr+"\n"+runErr.Error(), rawURL)
	}
	file, err := largestMedia(workDir)
	if err != nil {
		return DownloadResult{}, err
	}
	info, err := os.Stat(file)
	if err != nil {
		return DownloadResult{}, errs.UnsupportedFormat()
	}
	if info.Size() > cfg.MaxDownloadBytes {
		_ = os.Remove(file)
		return DownloadResult{}, errs.FileTooLarge(cfg.MaxDownloadBytes)
	}
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(file)), ".")
	return DownloadResult{
		Path:     file,
		MIME:     mimeForExt(ext),
		Name:     filepath.Base(file),
		Filesize: info.Size(),
	}, nil
}

// WritePlayable merges a video into one fragmented MP4 and writes it to dst.
// The player can start while bytes are still arriving.
func (r *Runner) WritePlayable(ctx context.Context, pageURL string, dst io.Writer) error {
	if err := r.available(); err != nil {
		return err
	}
	ff := ffmpegBin()
	if ff == "" {
		return errs.PlatformUnavailable("Playback is missing ffmpeg on this computer.")
	}
	urls, err := r.mediaURLs(ctx, pageURL)
	if err != nil {
		return err
	}
	args := []string{"-hide_banner", "-loglevel", "error", "-nostdin"}
	referer, _ := Referer(pageURL)
	for _, mediaURL := range urls {
		if referer != "" {
			args = append(args, "-referer", referer)
		}
		args = append(args, "-user_agent", browserUA, "-i", mediaURL)
	}
	args = append(args,
		"-c", "copy",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"-f", "mp4",
		"pipe:1",
	)
	cmd := exec.CommandContext(ctx, ff, args...)
	cmd.Stdout = dst
	var stderr bytes.Buffer
	cmd.Stderr = &limitedWriter{buf: &stderr, max: 4000}
	if err := cmd.Run(); err != nil {
		return MapExtractorError(stderr.String()+"\n"+err.Error(), pageURL)
	}
	return nil
}

func (r *Runner) mediaURLs(ctx context.Context, pageURL string) ([]string, error) {
	args := []string{
		"-g",
		"-f", "bv*[height<=720][vcodec^=avc1]+ba/b[height<=720]/b",
		"--no-playlist",
		"--no-warnings",
		"--no-progress",
		"--ignore-config",
		"--no-cache-dir",
		"--socket-timeout", "25",
		"--retries", "2",
		"--user-agent", browserUA,
	}
	args = append(args, toolArgs(pageURL)...)
	var stderr string
	var runErr error
	for _, extra := range attemptArgs(pageURL) {
		cmdArgs := append(append([]string{}, args...), extra...)
		cmdArgs = append(cmdArgs, "--", pageURL)
		stdout, errText, err := r.run(ctx, cmdArgs, "")
		if err == nil {
			var urls []string
			for _, line := range strings.Split(stdout, "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") {
					urls = append(urls, line)
				}
			}
			if len(urls) > 0 {
				return urls, nil
			}
			err = errs.PlatformUnavailable("This video has no playable stream.")
		}
		stderr, runErr = errText, err
		if stopRetry(MapExtractorError(errText+"\n"+err.Error(), pageURL)) {
			break
		}
	}
	if runErr == nil {
		runErr = errs.PlatformUnavailable("")
	}
	return nil, MapExtractorError(stderr+"\n"+runErr.Error(), pageURL)
}

func ffmpegBin() string {
	if path, err := exec.LookPath("ffmpeg"); err == nil {
		return path
	}
	if dir := ffmpegDir(); dir != "" {
		for _, name := range []string{"ffmpeg.exe", "ffmpeg"} {
			candidate := filepath.Join(dir, name)
			info, err := os.Stat(candidate)
			if err == nil && !info.IsDir() {
				return candidate
			}
		}
	}
	return ""
}

func (r *Runner) available() error {
	if r == nil || r.bin == "" {
		return errs.PlatformUnavailable("The source platform is temporarily unavailable. Try again later.")
	}
	return nil
}

func (r *Runner) run(ctx context.Context, args []string, dir string) (string, string, error) {
	if err := r.acquire(ctx); err != nil {
		return "", "", errs.PlatformUnavailable("")
	}
	defer r.release()
	cmd := exec.CommandContext(ctx, r.bin, args...)
	if dir != "" {
		cmd.Dir = dir
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &limitedWriter{buf: &stdout, max: 32 << 20}
	cmd.Stderr = &limitedWriter{buf: &stderr, max: 8000}
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func (r *Runner) runProgress(ctx context.Context, args []string, dir string, progress func(float64)) (string, string, error) {
	if err := r.acquire(ctx); err != nil {
		return "", "", errs.PlatformUnavailable("")
	}
	defer r.release()
	cmd := exec.CommandContext(ctx, r.bin, args...)
	cmd.Dir = dir
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return "", "", err
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return "", "", err
	}
	if err := cmd.Start(); err != nil {
		return "", "", err
	}
	var errBuf bytes.Buffer
	done := make(chan struct{})
	go func() {
		defer close(done)
		scanner := bufio.NewScanner(stderrPipe)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if errBuf.Len() < 8000 {
				errBuf.WriteString(line)
				errBuf.WriteByte('\n')
			}
			if progress != nil {
				if value, ok := percentOf(line); ok {
					progress(value)
				}
			}
		}
	}()
	stdoutDone := make(chan struct{})
	go func() {
		defer close(stdoutDone)
		_, _ = io.Copy(io.Discard, stdoutPipe)
	}()
	waitErr := cmd.Wait()
	<-done
	<-stdoutDone
	return "", errBuf.String(), waitErr
}

func (r *Runner) acquire(ctx context.Context) error {
	select {
	case r.sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (r *Runner) release() {
	select {
	case <-r.sem:
	default:
	}
}

type limitedWriter struct {
	buf *bytes.Buffer
	max int
}

func (w *limitedWriter) Write(p []byte) (int, error) {
	if w.buf.Len() < w.max {
		remain := w.max - w.buf.Len()
		if len(p) > remain {
			_, _ = w.buf.Write(p[:remain])
		} else {
			_, _ = w.buf.Write(p)
		}
	}
	return len(p), nil
}

func headerArgs(rawURL string) []string {
	var args []string
	referer, origin := Referer(rawURL)
	if referer != "" {
		args = append(args, "--referer", referer)
	}
	if origin != "" {
		args = append(args, "--add-header", "Origin:"+origin)
	}
	return args
}

func ffmpegDir() string {
	if path, err := exec.LookPath("ffmpeg"); err == nil {
		return filepath.Dir(path)
	}
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		dir := filepath.Join(local, "SocialSave")
		if _, err := os.Stat(filepath.Join(dir, "ffmpeg.exe")); err == nil {
			return dir
		}
	}
	return ""
}

func findDeno() string {
	if path, err := exec.LookPath("deno"); err == nil {
		return path
	}
	if local := os.Getenv("LOCALAPPDATA"); local != "" {
		candidate := filepath.Join(local, "SocialSave", "deno.exe")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

func toolArgs(rawURL string) []string {
	var args []string
	if deno := findDeno(); deno != "" {
		args = append(args, "--js-runtimes", "deno:"+deno, "--remote-components", "ejs:github")
	}
	if ffmpeg := ffmpegDir(); ffmpeg != "" {
		args = append(args, "--ffmpeg-location", ffmpeg)
	}
	args = append(args, headerArgs(rawURL)...)
	return args
}

func extractArgs(rawURL string, cfg config.Config) []string {
	args := []string{
		"--dump-single-json",
		"--no-playlist",
		"--skip-download",
		"--no-progress",
		"--ignore-config",
		"--no-cache-dir",
		"--restrict-filenames",
		"--no-check-formats",
		"--socket-timeout", "15",
		"--retries", "1",
		"--fragment-retries", "1",
		"--extractor-retries", "1",
		"--max-filesize", strconv.FormatInt(cfg.MaxDownloadBytes, 10),
		"--user-agent", browserUA,
	}
	return append(args, toolArgs(rawURL)...)
}

func downloadArgs(rawURL string, cfg config.Config, selector, out, ffmpeg string) []string {
	args := []string{
		"--no-playlist",
		"--ignore-config",
		"--no-cache-dir",
		"--restrict-filenames",
		"--newline",
		"--progress",
		"--retries", "3",
		"--fragment-retries", "3",
		"--socket-timeout", "25",
		"--concurrent-fragments", "16",
		"--max-filesize", strconv.FormatInt(cfg.MaxDownloadBytes, 10),
		"--user-agent", browserUA,
		"-f", selector,
		"-o", out,
	}
	if ffmpeg != "" {
		args = append(args, "--ffmpeg-location", ffmpeg, "--merge-output-format", "mp4", "--remux-video", "mp4")
	}
	return append(args, toolArgs(rawURL)...)
}

// attemptArgs retries the same public extractor with the client variants the
// previous API already used for sites that reject the default request.
func attemptArgs(rawURL string) [][]string {
	host := hostOf(rawURL)
	plain := []string(nil)
	chrome := []string{"--impersonate", "chrome"}
	switch {
	case strings.Contains(host, "instagram.com") || strings.HasSuffix(host, "instagr.am"):
		// A public Reel often looks "login required" until the browser-like request.
		return [][]string{
			append([]string{"--impersonate", "chrome"}, "--extractor-args", "instagram:app_id=936619743392459"),
			chrome,
			plain,
		}
	case strings.Contains(host, "facebook.com") || strings.HasSuffix(host, "fb.com") || strings.HasSuffix(host, "fb.watch"):
		return [][]string{
			chrome,
			{"--extractor-args", "facebook:api=graphql,webpage,plugin"},
			plain,
		}
	case host == "x.com" || host == "twitter.com" || strings.HasSuffix(host, ".x.com") || strings.HasSuffix(host, ".twitter.com"):
		return [][]string{
			{"--impersonate", "chrome", "--extractor-args", "twitter:api=syndication,graphql,legacy"},
			chrome,
			plain,
		}
	case strings.Contains(host, "pinterest.com") || strings.HasSuffix(host, "pin.it"):
		return [][]string{chrome, plain}
	case strings.Contains(host, "tiktok.com"):
		return [][]string{
			chrome,
			{"--impersonate", "safari"},
			plain,
		}
	default:
		return [][]string{plain}
	}
}

func stopRetry(err *errs.Error) bool {
	if err == nil {
		return false
	}
	switch err.Code {
	case "removed_video", "unsupported_platform", "file_too_large", "download_not_permitted":
		return true
	default:
		return false
	}
}

func clearPartials(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		_ = os.RemoveAll(filepath.Join(dir, entry.Name()))
	}
}

func decodeInfo(stdout string) (mediaInfo, error) {
	text := strings.TrimSpace(stdout)
	start := strings.IndexByte(text, '{')
	if start < 0 {
		return mediaInfo{}, errs.PlatformUnavailable("This post does not contain a public downloadable video.")
	}
	var info mediaInfo
	if err := json.Unmarshal([]byte(text[start:]), &info); err != nil {
		return mediaInfo{}, errs.PlatformUnavailable("")
	}
	return info, nil
}

var videoExts = map[string]struct{}{
	".mp4": {}, ".webm": {}, ".mov": {}, ".m4v": {}, ".mkv": {}, ".m4a": {},
}

func largestMedia(dir string) (string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", errs.UnsupportedFormat()
	}
	var best string
	var bestSize int64
	var mp4 string
	var mp4Size int64
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if _, ok := videoExts[ext]; !ok {
			continue
		}
		info, statErr := entry.Info()
		if statErr != nil || info.Size() <= 0 {
			continue
		}
		if ext == ".mp4" && info.Size() > mp4Size {
			mp4 = filepath.Join(dir, entry.Name())
			mp4Size = info.Size()
		}
		if info.Size() > bestSize {
			best = filepath.Join(dir, entry.Name())
			bestSize = info.Size()
		}
	}
	if mp4 != "" {
		return mp4, nil
	}
	if best == "" {
		return "", errs.UnsupportedFormat()
	}
	return best, nil
}

var percentPattern = regexp.MustCompile(`([0-9]+(?:\.[0-9]+)?)%`)

func percentOf(line string) (float64, bool) {
	if !strings.Contains(line, "[download]") {
		return 0, false
	}
	match := percentPattern.FindStringSubmatch(line)
	if match == nil {
		return 0, false
	}
	value, err := strconv.ParseFloat(match[1], 64)
	if err != nil {
		return 0, false
	}
	return value / 100, true
}
