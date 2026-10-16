package server

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func relayUploadRequest(t *testing.T, name, contentType string, data []byte) *http.Request {
	t.Helper()
	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	header := make(map[string][]string)
	header["Content-Disposition"] = []string{`form-data; name="file"; filename="` + name + `"`}
	header["Content-Type"] = []string{contentType}
	part, err := form.CreatePart(header)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = part.Write(data)
	_ = form.Close()
	request := httptest.NewRequest(http.MethodPost, "/relay", &body)
	request.Header.Set("Content-Type", form.FormDataContentType())
	request.RemoteAddr = "203.0.113.9:1234"
	return request
}

func relayTestApp(t *testing.T) http.Handler {
	t.Helper()
	app := testApp(t)
	app.relay = newRelayStore(t.TempDir())
	return app.Router()
}

func TestRelayRoundTripAndDownloadLimit(t *testing.T) {
	router := relayTestApp(t)
	data := []byte("not really a video")
	response := httptest.NewRecorder()
	router.ServeHTTP(response, relayUploadRequest(t, "clip.mp4", "video/mp4", data))
	if response.Code != http.StatusOK {
		t.Fatalf("upload %d %s", response.Code, response.Body.String())
	}
	var info relayInfo
	if err := json.Unmarshal(response.Body.Bytes(), &info); err != nil {
		t.Fatal(err)
	}
	if len(info.Code) != 6 || info.Name != "clip.mp4" || info.Size != int64(len(data)) || info.DownloadsLeft != 3 {
		t.Fatalf("info = %#v", info)
	}

	meta := httptest.NewRecorder()
	router.ServeHTTP(meta, httptest.NewRequest(http.MethodGet, "/relay/"+strings.ToLower(info.Code), nil))
	if meta.Code != http.StatusOK || !strings.Contains(meta.Body.String(), "clip.mp4") {
		t.Fatalf("meta %d %s", meta.Code, meta.Body.String())
	}

	for i := 0; i < 3; i++ {
		file := httptest.NewRecorder()
		router.ServeHTTP(file, httptest.NewRequest(http.MethodGet, "/relay/"+info.Code+"/file?dl=1", nil))
		if file.Code != http.StatusOK || file.Body.String() != string(data) {
			t.Fatalf("download %d: %d %s", i, file.Code, file.Body.String())
		}
		if !strings.HasPrefix(file.Header().Get("Content-Disposition"), "attachment") {
			t.Fatalf("disposition %q", file.Header().Get("Content-Disposition"))
		}
	}
	fourth := httptest.NewRecorder()
	router.ServeHTTP(fourth, httptest.NewRequest(http.MethodGet, "/relay/"+info.Code+"/file", nil))
	if fourth.Code != http.StatusNotFound || relayErrorJSON(fourth.Body.Bytes()) != "not_found" {
		t.Fatalf("fourth %d %s", fourth.Code, fourth.Body.String())
	}
}

func TestRelayServesHTMLAsDownload(t *testing.T) {
	router := relayTestApp(t)
	response := httptest.NewRecorder()
	router.ServeHTTP(response, relayUploadRequest(t, "x.html", "text/html", []byte("<script>alert(1)</script>")))
	var info relayInfo
	_ = json.Unmarshal(response.Body.Bytes(), &info)
	file := httptest.NewRecorder()
	router.ServeHTTP(file, httptest.NewRequest(http.MethodGet, "/relay/"+info.Code+"/file", nil))
	if file.Header().Get("Content-Type") != "application/octet-stream" ||
		!strings.HasPrefix(file.Header().Get("Content-Disposition"), "attachment") ||
		!strings.Contains(file.Header().Get("Content-Security-Policy"), "sandbox") {
		t.Fatalf("headers %#v", file.Header())
	}
}

func TestRelayRejectsOversizeAndUnknownCodes(t *testing.T) {
	app := testApp(t)
	app.relay = newRelayStore(t.TempDir())
	app.relay.maxFile = 8
	router := app.Router()
	response := httptest.NewRecorder()
	router.ServeHTTP(response, relayUploadRequest(t, "big.mp4", "video/mp4", bytes.Repeat([]byte("a"), 64)))
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize %d %s", response.Code, response.Body.String())
	}
	missing := httptest.NewRecorder()
	router.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/relay/ZZZZZZ", nil))
	if missing.Code != http.StatusNotFound {
		t.Fatalf("missing %d", missing.Code)
	}
}

func TestRelayUploadRateLimit(t *testing.T) {
	router := relayTestApp(t)
	for i := 0; i < relayUploadsPerIP; i++ {
		response := httptest.NewRecorder()
		router.ServeHTTP(response, relayUploadRequest(t, "a.mp4", "video/mp4", []byte("x")))
		if response.Code != http.StatusOK {
			t.Fatalf("upload %d: %d", i, response.Code)
		}
	}
	response := httptest.NewRecorder()
	router.ServeHTTP(response, relayUploadRequest(t, "a.mp4", "video/mp4", []byte("x")))
	if response.Code != http.StatusTooManyRequests {
		t.Fatalf("limit %d", response.Code)
	}
}
