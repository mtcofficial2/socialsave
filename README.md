# SocialSave

The latest Android app is on [GitHub Releases](https://github.com/mtcofficial2/socialsave/releases/latest). Download `SocialSave.apk` from that page and install it.

SocialSave is a Flutter download manager for **public video URLs you are allowed to save**. The mobile app never talks to TikTok, Instagram, YouTube, or other social platforms directly. It only calls **your backend**, which must use official APIs or other permitted access.

This project does **not** scrape private content, bypass DRM, logins, paywalls, or other access controls.

## What works out of the box

| Capability | Status |
|---|---|
| Direct public video URLs (`.mp4`, `.webm`, `.mov`, …) | Implemented end-to-end against the example backend |
| Platform detection (TikTok, Instagram, Facebook, X, YouTube, Reddit, Pinterest) | Implemented |
| Official oEmbed metadata for YouTube, TikTok, Reddit, Pinterest, X | Implemented on the server when the platform still exposes oEmbed |
| File download from those social platforms | **Not implemented.** Those platforms do not grant third-party apps a general download API. The backend refuses instead of bypassing that restriction. |
| Instagram / Facebook metadata | Requires official app tokens on the **server**. Until you add them, analyze returns a restricted result. |

To exercise the real download path, paste a public MP4 such as:

`https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4`

or tap **Try a sample public video** on the home screen.

## Architecture

```
Flutter app (Riverpod + GoRouter + Dio + Hive)
        HTTPS
Backend API  (/api/v1/analyze, /api/v1/download)
        │
        ├── ProviderRegistry
        │     ├── TikTokProvider
        │     ├── InstagramProvider
        │     ├── FacebookProvider
        │     ├── XProvider
        │     ├── YouTubeProvider
        │     ├── RedditProvider
        │     ├── PinterestProvider
        │     └── DirectVideoProvider
        └── Signed temporary file stream (SSRF-checked)
```

Disable a platform without changing Flutter by editing `ENABLED_PLATFORMS` on the server.

```
lib/
  core/           config, errors, network, storage, theme, utils, DI
  features/
    home/
    downloader/   analyze, preview, download manager
    downloads/    history
    settings/
  shared/         models, widgets, routing
backend/
  app/providers/  one class per social platform
docs/openapi.yaml
```

## Flutter setup

1. Install [Flutter](https://docs.flutter.dev/get-started/install) 3.24+ (this repo was created with Flutter 3.44 / Dart 3.12).
2. From the project root:

```bash
flutter pub get
flutter test
```

3. Run the backend first (see below), then:

```bash
# Android emulator (host loopback is 10.0.2.2 — this is the default)
flutter run

# iOS simulator
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000

# Physical device on your LAN
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000

# Production
flutter run --dart-define-from-file=dart_defines.json
```

Copy `dart_defines.example.json` to `dart_defines.json` (gitignored if you add secrets). **Do not put provider API secrets in the Flutter app.** An optional public client token may be passed as `API_KEY`; real YouTube/Instagram/X credentials stay on the server.

### Android

- `INTERNET`, `POST_NOTIFICATIONS`, and optional media permissions are declared.
- Debug builds allow cleartext to `10.0.2.2` / localhost so the example backend can run over HTTP.
- Production must use HTTPS.

### iOS

- Photo library usage strings are in `ios/Runner/Info.plist`.
- Local networking is allowed for development.
- On a real device, point `API_BASE_URL` at an HTTPS host or your machine’s LAN IP.

## Backend setup

The example API is FastAPI.

```bash
cd backend
python -m venv .venv
# Windows: .venv\Scripts\activate
# macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env   # or cp .env.example .env
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

Set `PUBLIC_BASE_URL` to the URL the **phone** can reach. For an Android emulator that is often `http://10.0.2.2:8000`. For a physical device, use your computer’s LAN address.

### Important environment variables

| Variable | Purpose |
|---|---|
| `SECRET_KEY` | HMAC key for temporary download tokens |
| `ENABLED_PLATFORMS` | Comma-separated provider ids. Remove one to disable it |
| `REQUIRE_API_KEY` / `API_KEYS` | Optional public client tokens |
| `MAX_DOWNLOAD_BYTES` | Default 500 MB |
| `YOUTUBE_API_KEY`, `INSTAGRAM_ACCESS_TOKEN`, `FACEBOOK_ACCESS_TOKEN`, `X_BEARER_TOKEN` | Official credentials **only**. Unused keys mean that provider stays metadata-only or disabled |

The contract is documented in `docs/openapi.yaml`.

```
POST /api/v1/analyze     { "url": "https://..." }
POST /api/v1/download    { "url": "https://...", "format_id": "original" }
GET  /api/v1/download/{id}
GET  /api/v1/files/{token}
GET  /api/v1/platforms
GET  /health
```

### Security controls in the example API

- HTTPS expected in production
- URL allow-list: http/https only
- SSRF protection (localhost, private, link-local, metadata hosts, credentialed URLs, limited redirects)
- Content-type and maximum size checks
- HMAC temporary file URLs
- Per-IP rate limits
- Provider secrets never leave the server

This is an example implementation, not a hosted scraping service.

## Tests

```bash
flutter test
cd backend
pytest
```

Covered on the Flutter side: URL validation, platform detection, API failures, repository behavior, download cancel/retry, wifi-only, theme switching, and widget/integration smoke tests.

## Compliance notice

Users are responsible for the content they download. SocialSave will not:

- log into someone else’s private account
- decrypt DRM
- scrape hidden or paywalled media
- ship platform API keys inside the Android/iOS binary

If a platform does not permit downloading, keep that provider disabled or metadata-only.

## License

You are responsible for complying with copyright law and each platform’s terms when you ship or use this software.
