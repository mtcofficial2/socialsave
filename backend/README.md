# SocialSave API

Example backend for the SocialSave Flutter app.

It validates URLs, detects platforms, fetches **official metadata when available**, and streams files **only** for permitted public media (the included `DirectVideoProvider`).

Social platform providers are separate classes so you can disable one of them from `.env` without touching Flutter.

```
ENABLED_PLATFORMS=direct,youtube
```

See the root `README.md` and `docs/openapi.yaml` for the full contract.
