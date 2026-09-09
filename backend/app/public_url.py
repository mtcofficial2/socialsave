from fastapi import Request

from app.config import Settings


def public_base_url(request: Request, settings: Settings) -> str:
    """Prefer the Host the phone actually called (Cloudflare URL), not localhost."""
    host = (
        request.headers.get("x-forwarded-host")
        or request.headers.get("host")
        or ""
    ).split(",")[0].strip()
    proto = (
        request.headers.get("x-forwarded-proto")
        or request.headers.get("x-forwarded-protocol")
        or ""
    ).split(",")[0].strip()
    if not proto:
        proto = (
            "https"
            if any(
                part in host
                for part in ("workers.dev", "cloudflare", "koyeb.app", "onrender.com")
            )
            else request.url.scheme
        )

    local = (
        not host
        or host.startswith("127.0.0.1")
        or host.startswith("localhost")
        or host.startswith("10.0.2.2")
        or host.startswith("0.0.0.0")
    )
    if local:
        return settings.public_base_url.rstrip("/")
    return f"{proto}://{host}".rstrip("/")
