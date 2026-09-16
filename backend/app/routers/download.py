from __future__ import annotations

import asyncio
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, Request
from fastapi.responses import FileResponse, StreamingResponse

from app.auth import require_api_key
from app.config import Settings, get_settings
from app.errors import (
    ApiError,
    download_not_permitted,
    file_too_large,
    platform_unavailable,
    unauthorized,
)
from app.jobs import job_store
from app.models import DownloadRequest, DownloadResponse, JobStatusResponse
from app.providers.extractor import MediaExtractor
from app.providers.http import SafeHttp
from app.providers.registry import ProviderRegistry
from app.public_url import public_base_url
from app.security import validate_public_url
from app.tokens import DownloadTokenService

router = APIRouter()


@router.post(
    "/api/v1/download",
    response_model=DownloadResponse,
    dependencies=[Depends(require_api_key)],
)
async def create_download(
    payload: DownloadRequest,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> DownloadResponse:
    url = validate_public_url(payload.url)
    base = public_base_url(request, settings)
    provider = ProviderRegistry(settings).resolve(url)
    if not provider.supports_download:
        raise download_not_permitted()
    handle = await provider.create_download(url, payload.format_id)
    if handle.prepare_locally:
        job = job_store.create()
        asyncio.create_task(
            _prepare_job(job.id, url, handle.format_id, settings, base),
        )
        return DownloadResponse(
            download_url="",
            id=job.id,
            state="processing",
            mime_type=handle.mime_type,
            file_name=handle.file_name,
        )
    if not handle.upstream_url:
        raise download_not_permitted()
    token = DownloadTokenService(settings).issue(
        {
            "url": handle.upstream_url,
            "mime": handle.mime_type,
            "max": settings.max_download_bytes,
            "name": handle.file_name,
            "headers": handle.http_headers or {},
        }
    )
    expires = datetime.now(timezone.utc) + timedelta(seconds=settings.token_ttl_seconds)
    return DownloadResponse(
        download_url=f"{base}/api/v1/files/{token}",
        direct_url=handle.upstream_url,
        id=token[:12],
        state="ready",
        expires_at=expires.isoformat(),
        mime_type=handle.mime_type,
        filesize=handle.filesize,
        file_name=handle.file_name,
        request_headers=handle.http_headers,
    )


@router.get("/api/v1/download/{job_id}", response_model=JobStatusResponse)
async def job_status(job_id: str) -> JobStatusResponse:
    job = job_store.get(job_id)
    if job is None:
        raise unauthorized()
    return JobStatusResponse(
        id=job.id,
        state=job.state,
        download_url=job.download_url,
        error=job.error,
        progress=job.progress,
        filesize=job.filesize,
        file_name=job.file_name,
    )


def ascii_filename(name: str | None) -> str:
    raw = (name or "video.mp4").replace('"', "")
    cleaned = re.sub(r"[^\w.\-]+", "_", raw, flags=re.ASCII).strip("._") or "video"
    if "." not in cleaned:
        cleaned += ".mp4"
    return cleaned[:80]


@router.get("/api/v1/files/{token}")
async def stream_file(token: str, settings: Settings = Depends(get_settings)):
    payload = DownloadTokenService(settings).parse(token)
    job_id = payload.get("job")
    filename = ascii_filename(str(payload.get("name") or "video.mp4"))
    if isinstance(job_id, str):
        job = job_store.get(job_id)
        if job is None or not job.file_path:
            raise unauthorized()
        path = Path(job.file_path)
        if not path.is_file():
            raise unauthorized()
        return FileResponse(
            path,
            media_type=job.mime_type or payload.get("mime") or "video/mp4",
            filename=ascii_filename(job.file_name or filename),
        )

    url = payload.get("url")
    if not isinstance(url, str):
        raise unauthorized()
    validate_public_url(url)
    extra_headers = payload.get("headers") if isinstance(payload.get("headers"), dict) else None
    http = SafeHttp(settings)
    try:
        client, response = await http.stream(url, extra_headers=extra_headers)
    except ApiError:
        raise
    except Exception as exc:
        raise platform_unavailable(
            "TikTok (or the source) refused the video file. Try again in a moment."
        ) from exc
    mime = (response.headers.get("content-type") or payload.get("mime") or "video/mp4").split(";")[0]
    if response.status_code >= 400 or mime.startswith("text/html") or mime.startswith("application/json"):
        await response.aclose()
        await client.aclose()
        raise platform_unavailable(
            "The source refused the video file. Try a public TikTok, or try again."
        )

    async def iterator():
        sent = 0
        try:
            async for chunk in response.aiter_bytes():
                sent += len(chunk)
                if sent > settings.max_download_bytes:
                    raise file_too_large()
                yield chunk
        finally:
            await response.aclose()
            await client.aclose()

    headers = {
        "Content-Disposition": f'attachment; filename="{filename}"',
        "Cache-Control": "no-store",
    }
    length = response.headers.get("content-length")
    if length:
        headers["Content-Length"] = length
        if int(length) > settings.max_download_bytes:
            await response.aclose()
            await client.aclose()
            raise file_too_large()
    return StreamingResponse(iterator(), media_type=mime, headers=headers)


async def _prepare_job(
    job_id: str,
    url: str,
    format_id: str,
    settings: Settings,
    public_base: str,
) -> None:
    job = job_store.get(job_id)
    if job is None:
        return
    extractor = MediaExtractor(settings)

    def on_progress(value: float) -> None:
        current = job_store.get(job_id)
        if current is not None:
            current.progress = value

    try:
        result = await extractor.download(url, format_id, progress=on_progress)
        token = DownloadTokenService(settings).issue(
            {
                "job": job_id,
                "mime": result["mime"],
                "name": result["name"],
            }
        )
        job.file_path = result["path"]
        job.mime_type = result["mime"]
        job.file_name = result["name"]
        job.filesize = result["filesize"]
        job.progress = 1
        job.download_url = f"{public_base.rstrip('/')}/api/v1/files/{token}"
        job.state = "ready"
    except ApiError as exc:
        job.state = "failed"
        job.error = {"code": exc.code, "message": exc.message}
    except Exception:
        job.state = "failed"
        job.error = {
            "code": "platform_unavailable",
            "message": platform_unavailable().message,
        }
