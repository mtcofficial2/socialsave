from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Optional
from urllib.parse import parse_qs, urlparse

import httpx

from app.errors import file_too_large, platform_unavailable, removed_video
from app.models import MediaFormat

_VIDEO_ID = re.compile(
    r"(?:youtu\.be/|youtube\.com/(?:watch\?v=|embed/|shorts/|live/))([A-Za-z0-9_-]{11})"
)
_INSTANCES = (
    "https://invidious.tiekoetter.com",
    "https://invidious.f5.si",
    "https://yt.chocolatemoo53.com",
    "https://inv.nadeko.net",
    "https://invidious.nerdvpn.de",
)
_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json",
}


def video_id_from_url(url: str) -> Optional[str]:
    match = _VIDEO_ID.search(url)
    if match:
        return match.group(1)
    parsed = urlparse(url)
    if "youtube.com" in (parsed.hostname or "") and parsed.path == "/watch":
        values = parse_qs(parsed.query).get("v") or []
        if values and len(values[0]) == 11:
            return values[0]
    return None


def fetch_info(video_id: str) -> dict[str, Any]:
    last_error: Exception | None = None
    with httpx.Client(timeout=20.0, follow_redirects=True, headers=_HEADERS) as client:
        for base in _INSTANCES:
            try:
                response = client.get(f"{base}/api/v1/videos/{video_id}")
                if response.status_code == 404:
                    raise removed_video()
                response.raise_for_status()
                data = response.json()
                if isinstance(data, dict) and data.get("title") and (
                    data.get("formatStreams") or data.get("adaptiveFormats")
                ):
                    return data
            except removed_video:
                raise
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                continue
    raise platform_unavailable(
        "YouTube blocked the cloud server. Try again in a minute, or use TikTok / a direct MP4."
    ) from last_error


def to_formats(info: dict[str, Any]) -> list[MediaFormat]:
    streams = [item for item in (info.get("formatStreams") or []) if isinstance(item, dict)]
    formats = [
        MediaFormat(
            id="original",
            quality="original",
            format="mp4",
            filesize=_filesize(streams[-1] if streams else None),
            width=_int(info.get("width")),
            height=_int(info.get("height")),
        )
    ]
    seen: set[str] = set()
    for item in streams:
        label = str(item.get("qualityLabel") or item.get("quality") or "").lower()
        if not label.endswith("p") or label in seen:
            continue
        seen.add(label)
        formats.append(
            MediaFormat(
                id=label,
                quality=label,
                format=str(item.get("container") or "mp4").replace(".", "") or "mp4",
                filesize=_filesize(item),
                width=_int(item.get("size", "").split("x")[0] if isinstance(item.get("size"), str) else None),
                height=_int(label.replace("p", "")),
                has_audio=True,
                has_video=True,
            )
        )
    formats.append(
        MediaFormat(
            id="auto",
            quality="auto",
            format="mp4",
            filesize=_filesize(streams[-1] if streams else None),
            width=_int(info.get("width")),
            height=_int(info.get("height")),
        )
    )
    return formats


def thumbnail_url(info: dict[str, Any]) -> Optional[str]:
    thumbs = info.get("videoThumbnails") or []
    preferred = {"maxres", "maxresdefault", "high", "medium"}
    for item in thumbs:
        if isinstance(item, dict) and item.get("url") and item.get("quality") in preferred:
            return str(item["url"])
    for item in thumbs:
        if isinstance(item, dict) and item.get("url"):
            return str(item["url"])
    return None


def download_stream(url: str, dest: Path, max_bytes: int) -> int:
    headers = {
        **_HEADERS,
        "Referer": "https://www.youtube.com/",
        "Accept": "*/*",
    }
    written = 0
    with httpx.Client(timeout=120.0, follow_redirects=True, headers=headers) as client:
        with client.stream("GET", url) as response:
            response.raise_for_status()
            with dest.open("wb") as handle:
                for chunk in response.iter_bytes(1024 * 64):
                    written += len(chunk)
                    if written > max_bytes:
                        raise file_too_large()
                    handle.write(chunk)
    if written <= 0:
        raise platform_unavailable("YouTube returned an empty file.")
    return written


def pick_stream(info: dict[str, Any], format_id: str) -> dict[str, Any]:
    streams = [item for item in (info.get("formatStreams") or []) if isinstance(item, dict) and item.get("url")]
    if not streams:
        raise platform_unavailable("YouTube did not return a downloadable file.")
    wanted = (format_id or "auto").lower()
    chosen = streams[-1]
    if wanted not in {"auto", "original"}:
        height = _int(wanted.replace("p", ""))
        if height:
            matching = [
                item
                for item in streams
                if _label_height(item) and _label_height(item) <= height
            ]
            if matching:
                chosen = max(matching, key=_label_height)
    return chosen


def _label_height(item: dict[str, Any]) -> int:
    label = str(item.get("qualityLabel") or "")
    return _int(label.replace("p", "")) or 0


def _filesize(item: Optional[dict[str, Any]]) -> Optional[int]:
    if not item:
        return None
    value = item.get("clen") or item.get("contentLength") or item.get("filesize")
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _int(value: Any) -> Optional[int]:
    try:
        return int(value) if value is not None and str(value).strip() != "" else None
    except (TypeError, ValueError):
        return None
