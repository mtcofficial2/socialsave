package storage

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/aviation256444-boop/socialsave/backend/internal/config"
)

// Uploader stores a prepared file and returns a URL the phone can fetch directly.
type Uploader interface {
	Enabled() bool
	Put(ctx context.Context, path, name, mime string) (string, error)
}

// NewFromConfig prefers S3-compatible storage, then the older HTTP PUT target.
func NewFromConfig(cfg config.Config) Uploader {
	if cfg.S3Bucket != "" && cfg.S3AccessKeyID != "" && cfg.S3SecretAccessKey != "" {
		return NewS3(cfg)
	}
	return New(cfg.ObjectStorageURL)
}

// S3 uploads with AWS Signature Version 4. It works with Amazon S3, Cloudflare R2, and Backblaze B2.
type S3 struct {
	Endpoint   string
	Region     string
	Bucket     string
	AccessKey  string
	SecretKey  string
	PublicBase string
	TTL        time.Duration
	Client     *http.Client
	now        func() time.Time
}

// NewS3 builds a client. Credentials are kept on the struct and are not logged.
func NewS3(cfg config.Config) *S3 {
	ttl := cfg.S3URLTTL
	if ttl <= 0 {
		ttl = time.Hour
	}
	region := cfg.S3Region
	if region == "" {
		region = "us-east-1"
	}
	return &S3{
		Endpoint:   cfg.S3Endpoint,
		Region:     region,
		Bucket:     cfg.S3Bucket,
		AccessKey:  cfg.S3AccessKeyID,
		SecretKey:  cfg.S3SecretAccessKey,
		PublicBase: cfg.S3PublicBaseURL,
		TTL:        ttl,
		Client:     &http.Client{Timeout: 10 * time.Minute},
		now:        time.Now,
	}
}

func (s *S3) Enabled() bool {
	return s != nil && s.Bucket != "" && s.AccessKey != "" && s.SecretKey != ""
}

// Put uploads the file, checks that it exists, and returns a temporary GET URL.
func (s *S3) Put(ctx context.Context, path, name, mime string) (string, error) {
	if !s.Enabled() {
		return "", fmt.Errorf("object storage disabled")
	}
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	if mime == "" {
		mime = "application/octet-stream"
	}
	key := objectKey(name)
	sum, err := fileSHA256(file)
	if err != nil {
		return "", err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	target, err := s.objectURL(key)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, target.String(), file)
	if err != nil {
		return "", err
	}
	req.ContentLength = info.Size()
	req.Header.Set("Content-Type", mime)
	req.Header.Set("x-amz-content-sha256", sum)
	s.sign(req, sum, s.now().UTC())
	client := s.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("object storage status %d", resp.StatusCode)
	}
	if err := s.head(ctx, key); err != nil {
		return "", err
	}
	if s.PublicBase != "" {
		return s.PublicBase + "/" + escapeKey(key), nil
	}
	return s.presignGet(key), nil
}

func (s *S3) head(ctx context.Context, key string) error {
	target, err := s.objectURL(key)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, target.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("x-amz-content-sha256", emptySHA256)
	s.sign(req, emptySHA256, s.now().UTC())
	client := s.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("object storage verify status %d", resp.StatusCode)
	}
	return nil
}

func (s *S3) presignGet(key string) string {
	now := s.now().UTC()
	expires := int(s.TTL.Seconds())
	if expires <= 0 {
		expires = 3600
	}
	target, err := s.objectURL(key)
	if err != nil {
		return ""
	}
	scope := s.scope(now)
	query := url.Values{}
	query.Set("X-Amz-Algorithm", "AWS4-HMAC-SHA256")
	query.Set("X-Amz-Credential", s.AccessKey+"/"+scope)
	query.Set("X-Amz-Date", amzDate(now))
	query.Set("X-Amz-Expires", fmt.Sprintf("%d", expires))
	query.Set("X-Amz-SignedHeaders", "host")
	canonical := strings.Join([]string{
		http.MethodGet,
		canonicalPath(target),
		canonicalQuery(query),
		"host:" + target.Host + "\n",
		"host",
		"UNSIGNED-PAYLOAD",
	}, "\n")
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate(now) + "\n" + scope + "\n" + hashHex(canonical)
	query.Set("X-Amz-Signature", hex.EncodeToString(s.signature(now, stringToSign)))
	target.RawQuery = query.Encode()
	return target.String()
}

func (s *S3) sign(req *http.Request, payloadHash string, now time.Time) {
	req.Header.Set("x-amz-date", amzDate(now))
	req.Header.Set("host", req.URL.Host)
	signed := []string{"host", "x-amz-content-sha256", "x-amz-date"}
	var canonicalHeaders strings.Builder
	for _, name := range signed {
		canonicalHeaders.WriteString(name)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(strings.TrimSpace(req.Header.Get(name)))
		canonicalHeaders.WriteByte('\n')
	}
	canonical := strings.Join([]string{
		req.Method,
		canonicalPath(req.URL),
		canonicalQuery(req.URL.Query()),
		canonicalHeaders.String(),
		strings.Join(signed, ";"),
		payloadHash,
	}, "\n")
	scope := s.scope(now)
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate(now) + "\n" + scope + "\n" + hashHex(canonical)
	sig := hex.EncodeToString(s.signature(now, stringToSign))
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+s.AccessKey+"/"+scope+", SignedHeaders="+strings.Join(signed, ";")+", Signature="+sig)
}

func (s *S3) signature(now time.Time, stringToSign string) []byte {
	dateKey := hmacSHA256([]byte("AWS4"+s.SecretKey), now.Format("20060102"))
	regionKey := hmacSHA256(dateKey, s.Region)
	serviceKey := hmacSHA256(regionKey, "s3")
	signingKey := hmacSHA256(serviceKey, "aws4_request")
	return hmacSHA256(signingKey, stringToSign)
}

func (s *S3) scope(now time.Time) string {
	return now.Format("20060102") + "/" + s.Region + "/s3/aws4_request"
}

func (s *S3) objectURL(key string) (*url.URL, error) {
	key = escapeKey(key)
	if s.Endpoint != "" {
		base, err := url.Parse(s.Endpoint)
		if err != nil {
			return nil, err
		}
		base.Path = strings.TrimRight(base.Path, "/") + "/" + s.Bucket + "/" + key
		base.RawQuery = ""
		return base, nil
	}
	return url.Parse("https://" + s.Bucket + ".s3." + s.Region + ".amazonaws.com/" + key)
}

func objectKey(name string) string {
	name = strings.TrimSpace(name)
	name = strings.ReplaceAll(name, "\\", "-")
	name = strings.ReplaceAll(name, "/", "-")
	if name == "" || name == "." {
		name = "video.mp4"
	}
	return time.Now().UTC().Format("20060102") + "/" + name
}

func escapeKey(key string) string {
	parts := strings.Split(key, "/")
	for i, part := range parts {
		parts[i] = url.PathEscape(part)
	}
	return strings.Join(parts, "/")
}

func canonicalPath(u *url.URL) string {
	path := u.EscapedPath()
	if path == "" {
		return "/"
	}
	return path
}

func canonicalQuery(values url.Values) string {
	if len(values) == 0 {
		return ""
	}
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var parts []string
	for _, key := range keys {
		items := append([]string(nil), values[key]...)
		sort.Strings(items)
		for _, item := range items {
			parts = append(parts, url.QueryEscape(key)+"="+url.QueryEscape(item))
		}
	}
	return strings.Join(parts, "&")
}

func fileSHA256(file *os.File) (string, error) {
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func hashHex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func hmacSHA256(key []byte, value string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(value))
	return mac.Sum(nil)
}

func amzDate(now time.Time) string {
	return now.UTC().Format("20060102T150405Z")
}

const emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
