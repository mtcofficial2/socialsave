from __future__ import annotations

from urllib.parse import urlparse

from app.config import Settings
from app.errors import ApiError, file_too_large, unsupported_format
from app.models import MediaFormat
from app.providers.base import DownloadHandle, MediaMetadata, SocialMediaProvider
from app.providers.extractor import MediaExtractor
from app.providers.http import SafeHttp

VIDEO_EXTENSIONS = {".mp4", ".webm", ".mov", ".m4v", ".mkv"}
ALLOWED_MIME = {
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-m4v": "m4v",
    "video/x-matroska": "mkv",
    "video/mpeg": "mpg",
    "application/octet-stream": None,
}


class DirectVideoProvider(SocialMediaProvider):
    id = "direct"
    display_name = "Direct URL"
    supports_metadata = True
    supports_download = True
    notes = "Public video files and pages that expose a downloadable video."

    def __init__(
        self,
        settings: Settings,
        http: SafeHttp,
        extractor: MediaExtractor | None = None,
    ) -> None:
        self._settings = settings
        self._http = http
        self._extractor = extractor

    def can_handle(self, url: str) -> bool:
        path = urlparse(url).path.lower()
        return any(path.endswith(ext) for ext in VIDEO_EXTENSIONS)

    async def analyze(self, url: str) -> MediaMetadata:
        if self.can_handle(url):
            try:
                return await self._analyze_direct(url)
            except ApiError as exc:
                if exc.code in {"file_too_large", "invalid_url"}:
                    raise
                if self._extractor is not None:
                    return await self._extractor.analyze(
                        url,
                        platform=self.id,
                        display_name=self.display_name,
                    )
                raise
        if self._extractor is None:
            raise unsupported_format()
        return await self._extractor.analyze(
            url,
            platform=self.id,
            display_name=self.display_name,
        )

    async def create_download(self, url: str, format_id: str) -> DownloadHandle:
        if self.can_handle(url):
            try:
                meta = await self._analyze_direct(url)
                fmt = meta.formats[0] if meta.formats else None
                return DownloadHandle(
                    source_url=url,
                    format_id=format_id or "original",
                    mime_type=f"video/{fmt.format}" if fmt else "video/mp4",
                    filesize=fmt.filesize if fmt else None,
                    file_name=f"{meta.title}.{fmt.format if fmt else 'mp4'}",
                    upstream_url=url,
                )
            except ApiError:
                pass
        return DownloadHandle(
            source_url=url,
            format_id=format_id or "auto",
            mime_type="video/mp4",
            prepare_locally=True,
        )

    async def _analyze_direct(self, url: str) -> MediaMetadata:
        title = _filename(url)
        guessed = "mp4"
        path = urlparse(url).path.lower()
        for ext in VIDEO_EXTENSIONS:
            if path.endswith(ext):
                guessed = ext.lstrip(".")
                break
        try:
            response = await self._http.head_or_get(url)
        except ApiError:
            return MediaMetadata(
                platform=self.id,
                title=title,
                source_url=url,
                formats=[
                    MediaFormat(id="original", quality="original", format=guessed)
                ],
                can_download=True,
            )
        if response.status_code >= 400:
            return MediaMetadata(
                platform=self.id,
                title=title,
                source_url=url,
                formats=[
                    MediaFormat(id="original", quality="original", format=guessed)
                ],
                can_download=True,
            )
        content_type = (response.headers.get("content-type") or "").split(";")[0].strip().lower()
        fmt = _format_from_mime(content_type, url)
        length = _content_length(response.headers)
        if length is not None and length > self._settings.max_download_bytes:
            raise file_too_large()
        return MediaMetadata(
            platform=self.id,
            title=title,
            source_url=url,
            formats=[
                MediaFormat(
                    id="original",
                    quality="original",
                    format=fmt,
                    filesize=length,
                )
            ],
            can_download=True,
        )


def _format_from_mime(content_type: str, url: str) -> str:
    path = urlparse(url).path.lower()
    for ext in VIDEO_EXTENSIONS:
        if path.endswith(ext):
            guessed = ext.lstrip(".")
            break
    else:
        guessed = "mp4"
    if not content_type:
        return guessed
    if content_type.startswith("text/html") or content_type.startswith("application/json"):
        raise unsupported_format()
    if content_type in ALLOWED_MIME:
        return ALLOWED_MIME[content_type] or guessed
    if content_type.startswith("video/"):
        return content_type.split("/", 1)[1]
    raise unsupported_format()


def _content_length(headers) -> int | None:
    value = headers.get("content-length") or headers.get("content-range")
    if not value:
        return None
    if "content-range" in {k.lower() for k in headers.keys()} and "/" in str(
        headers.get("content-range", "")
    ):
        total = str(headers.get("content-range", "")).rsplit("/", 1)[-1]
        try:
            return int(total)
        except ValueError:
            return None
    try:
        return int(value)
    except ValueError:
        return None


def _filename(url: str) -> str:
    name = urlparse(url).path.rsplit("/", 1)[-1] or "video"
    if "." in name:
        name = name.rsplit(".", 1)[0]
    return name or "video"
