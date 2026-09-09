# Host SocialSave API on Cloudflare

The phone app stays on your device. Cloudflare hosts the **Python API** so downloads work when this PC is off.

## Important limits

- **Cloudflare Workers (free serverless)** cannot run this API. yt-dlp, ffmpeg, and Node need a real Linux container.
- **Cloudflare Containers** can. They require a **Workers Paid** plan (about **$5/month**), plus usage for CPU/RAM/disk while a download is running.
- This is **not free**. A free Worker or Cloudflare Tunnel still needs this PC on.

## One-time setup

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and start it.
2. In this folder:

```bash
cd cloudflare
npm install
npx wrangler login
npx wrangler deploy
```

3. Wrangler prints a URL like:

`https://socialsave-api.<your-subdomain>.workers.dev`

4. Rebuild the Android app with that URL:

```bash
flutter build apk --debug --target-platform android-arm64 --dart-define=API_BASE_URL=https://socialsave-api.YOUR_SUBDOMAIN.workers.dev
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

After the first deploy, wait a few minutes for the container to provision.

## Optional secret

```bash
npx wrangler secret put SECRET_KEY
```

Use a long random string. The container reads it as `SECRET_KEY`.
