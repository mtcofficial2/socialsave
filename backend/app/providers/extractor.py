from __future__ import annotations

import asyncio
import re
import shutil
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, Optional
from urllib.parse import urlparse

from app.config import Settings
from app.errors import (
    file_too_large,
    platform_unavailable,
    private_video,
    removed_video,
    unsupported_format,
    unsupported_platform,
)
from app.models import MediaFormat
from app.providers.base import MediaMetadata

_EXECUTOR = ThreadPoolExecutor(max_workers=2)
_QUALITY_STEPS = (360, 480, 720, 1080, 1440, 2160)
_BEST_FORMAT = "bv*+ba/b"


def _ffmpeg_dir() -> Optional[str]:
    found = shutil.which("ffmpeg")
    if found:
        return str(Path(found).parent)
    try:
        import imageio_ffmpeg

        exe = Path(imageio_ffmpeg.get_ffmpeg_exe())
        alias = exe.parent / "ffmpeg"
        if exe.name != "ffmpeg" and not alias.exists():
            try:
                alias.symlink_to(exe)
            except OSError:
                shutil.copy2(exe, alias)
        return str(exe.parent)
    except Exception:
        return None


def _js_runtimes() -> dict[str, dict[str, str]]:
    runtimes: dict[str, dict[str, str]] = {}
    deno = shutil.which("deno")
    node = shutil.which("node") or shutil.which("nodejs")
    if deno:
        runtimes["deno"] = {"path": deno}
    if node:
        runtimes["node"] = {"path": node}
    return runtimes


def _hostname(url: str) -> str:
    return (urlparse(url).hostname or "").lower()


def _is_youtube(url: str) -> bool:
    host = _hostname(url)
    return host == "youtu.be" or host.endswith("youtube.com") or "youtube" in host


def _is_tiktok(url: str) -> bool:
    return "tiktok.com" in _hostname(url)


def _format_selector(format_id: str, has_ffmpeg: bool) -> str:
    quality = (format_id or "auto").lower()
    if has_ffmpeg:
        mapping = {
            "360p": "bv*[height<=360]+ba/b[height<=360]/b",
            "480p": "bv*[height<=480]+ba/b[height<=480]/b",
            "720p": "bv*[height<=720]+ba/b[height<=720]/b",
            "1080p": "bv*[height<=1080]+ba/b[height<=1080]/b",
            "1440p": "bv*[height<=1440]+ba/b[height<=1440]/b",
            "2160p": "bv*[height<=2160]+ba/b[height<=2160]/b",
            "4k": "bv*[height<=2160]+ba/b[height<=2160]/b",
            "original": _BEST_FORMAT,
            "auto": _BEST_FORMAT,
        }
        return mapping.get(quality, _BEST_FORMAT)
    mapping = {
        "360p": "best[height<=360][acodec!=none][vcodec!=none]/best[height<=360]/best",
        "480p": "best[height<=480][acodec!=none][vcodec!=none]/best[height<=480]/best",
        "720p": "best[height<=720][acodec!=none][vcodec!=none]/best[height<=720]/best",
        "1080p": "best[height<=1080][acodec!=none][vcodec!=none]/best[height<=1080]/best",
        "1440p": "best[height<=1440][acodec!=none][vcodec!=none]/best[height<=1440]/best",
        "2160p": "best[height<=2160][acodec!=none][vcodec!=none]/best[height<=2160]/best",
        "original": "best[acodec!=none][vcodec!=none]/best",
        "auto": "best[acodec!=none][vcodec!=none]/best",
    }
    return mapping.get(quality, mapping["auto"])


def _base_opts(settings: Settings, url: str) -> dict[str, Any]:
    ffmpeg_dir = _ffmpeg_dir()
    host = _hostname(url)
    headers = {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/131.0.0.0 Safari/537.36"
        ),
        "Accept-Language": "en-US,en;q=0.9",
    }
    if "tiktok.com" in host:
        headers["Referer"] = "https://www.tiktok.com/"
    elif "instagram.com" in host or host.endswith("instagr.am"):
        headers["Referer"] = "https://www.instagram.com/"
    elif _is_youtube(url):
        headers["Referer"] = "https://www.youtube.com/"
    elif "reddit.com" in host or host.endswith("redd.it"):
        headers["Referer"] = "https://www.reddit.com/"
    elif "facebook.com" in host or host.endswith("fb.watch") or host.endswith("fb.com"):
        headers["Referer"] = "https://www.facebook.com/"
    elif "pinterest.com" in host or host.endswith("pin.it"):
        headers["Referer"] = "https://www.pinterest.com/"

    opts: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "noprogress": True,
        "retries": 3,
        "fragment_retries": 3,
        "socket_timeout": 30,
        "max_filesize": settings.max_download_bytes,
        "restrictfilenames": True,
        "overwrites": True,
        "no_color": True,
        "ignoreconfig": True,
        "cachedir": False,
        "extract_flat": False,
        "skip_unavailable_fragments": True,
        "concurrent_fragment_downloads": 3,
        "format_sort": ["res", "fps", "hdr:12", "codec:av01:vp9.2:vp9:h265:h264", "size", "br"],
        "http_headers": headers,
        "remote_components": ["ejs:github", "ejs:npm"],
    }
    runtimes = _js_runtimes()
    if runtimes:
        opts["js_runtimes"] = runtimes
    if _is_youtube(url):
        opts["no_warnings"] = False
    if ffmpeg_dir:
        opts["ffmpeg_location"] = ffmpeg_dir
        opts["merge_output_format"] = "mp4"
    return opts


def _map_error(exc: Exception, url: str = ""):
    text = str(exc)
    lower = text.lower()
    extractor = ""
    match = re.search(r"\[([a-z0-9_]+)\]", lower)
    if match:
        extractor = match.group(1)

    tiktok_login = any(
        token in lower
        for token in (
            "not be comfortable",
            "some audiences",
            "log in for access",
        )
    )
    if extractor == "tiktok" or (_is_tiktok(url) and tiktok_login):
        if tiktok_login or "login" in lower or "sign in" in lower:
            return private_video(
                "TikTok is hiding this video behind a login or content warning. "
                "Try a fully public TikTok that opens while logged out."
            )

    if extractor == "youtube" or _is_youtube(url):
        if any(
            token in lower
            for token in (
                "sign in to confirm",
                "age-restricted",
                "members-only",
                "join this channel",
                "private video",
            )
        ):
            return private_video(
                "This YouTube video is private, age-restricted, or members-only."
            )
        if "unable to download video data" in lower or "http error 403" in lower:
            return platform_unavailable(
                "YouTube refused the file download. Try another quality, or try again in a moment."
            )

    if any(
        token in lower
        for token in (
            "private video",
            "this video is private",
            "login required",
            "members-only",
            "members only",
            "join this channel",
            "age-restricted",
        )
    ):
        return private_video()
    if "drm" in lower:
        return private_video("This video is DRM-protected and cannot be saved.")
    if any(token in lower for token in ("not found", "http error 404", "has been deleted")):
        return removed_video()
    if "unsupported url" in lower or "no video formats" in lower:
        return unsupported_platform()
    if "unable to download video data" in lower or "http error 403" in lower:
        return platform_unavailable(
            "The source refused the video file. Try another quality, or try again."
        )
    summary = text.strip().splitlines()[-1][:240]
    return platform_unavailable(f"Could not fetch this video from the source. {summary}")


def _build_formats(info: dict[str, Any]) -> list[MediaFormat]:
    raw = info.get("formats") or []
    heights: dict[int, dict[str, Any]] = {}
    for item in raw:
        if not isinstance(item, dict):
            continue
        if item.get("vcodec") in {None, "none"}:
            continue
        height = item.get("height")
        if not isinstance(height, int) or height <= 0:
            continue
        bucket = min((step for step in _QUALITY_STEPS if height <= step), default=2160)
        current = heights.get(bucket)
        if current is None or (item.get("tbr") or 0) > (current.get("tbr") or 0):
            heights[bucket] = item

    ext = (info.get("ext") or "mp4").replace(".", "")
    formats = [
        MediaFormat(
            id="original",
            quality="original",
            format=ext if ext else "mp4",
            filesize=info.get("filesize") or info.get("filesize_approx"),
            width=info.get("width"),
            height=info.get("height"),
        )
    ]
    for step in reversed(_QUALITY_STEPS):
        item = heights.get(step)
        if item is None:
            continue
        item_ext = (item.get("ext") or "mp4").replace(".", "")
        formats.append(
            MediaFormat(
                id=f"{step}p",
                quality=f"{step}p",
                format=item_ext if item_ext in {"mp4", "webm", "mov", "m4v", "mkv"} else "mp4",
                filesize=item.get("filesize") or item.get("filesize_approx"),
                width=item.get("width"),
                height=item.get("height"),
                has_audio=item.get("acodec") not in {None, "none"},
                has_video=True,
            )
        )
    formats.append(
        MediaFormat(
            id="auto",
            quality="auto",
            format="mp4",
            filesize=info.get("filesize") or info.get("filesize_approx"),
            width=info.get("width"),
            height=info.get("height"),
        )
    )
    return formats


def _unwrap_info(info: dict[str, Any]) -> dict[str, Any]:
    if info.get("_type") == "playlist":
        entries = [entry for entry in (info.get("entries") or []) if isinstance(entry, dict)]
        if not entries:
            raise removed_video()
        return entries[0]
    return info


def _run_ydl_raw(url: str, opts: dict[str, Any], *, download: bool) -> dict[str, Any]:
    import yt_dlp

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=download)
    if not isinstance(info, dict):
        raise removed_video()
    return info


def _run_ydl(url: str, opts: dict[str, Any], *, download: bool) -> dict[str, Any]:
    try:
        return _run_ydl_raw(url, opts, download=download)
    except Exception as exc:  # noqa: BLE001
        raise _map_error(exc, url) from exc


def _youtube_attempts() -> list[dict[str, Any]]:
    """Innertube clients first: Render IPs often get a bot page instead of ytInitialPlayerResponse."""
    return [
        {
            "extractor_args": {
                "youtube": {
                    "player_client": ["android", "ios", "tv"],
                    "player_skip": ["webpage"],
                }
            }
        },
        {
            "extractor_args": {
                "youtube": {"player_client": ["tv", "android_vr", "mweb", "web"]}
            }
        },
        {},
    ]


def _extract_sync(url: str, settings: Settings) -> dict[str, Any]:
    extras = _youtube_attempts() if _is_youtube(url) else [{}]
    last_error: Exception | None = None
    for extra in extras:
        opts = _base_opts(settings, url)
        opts["skip_download"] = True
        opts.update(extra)
        try:
            return _unwrap_info(_run_ydl_raw(url, opts, download=False))
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue
    raise _map_error(last_error or Exception("analyze failed"), url)


def _clear_workdir(workdir: Path) -> None:
    for path in workdir.iterdir():
        try:
            if path.is_file():
                path.unlink()
        except OSError:
            pass


def _download_sync(
    url: str,
    format_id: str,
    settings: Settings,
    progress: Optional[Callable[[float], None]] = None,
) -> dict[str, Any]:
    has_ffmpeg = _ffmpeg_dir() is not None
    workdir = Path(tempfile.mkdtemp(prefix="socialsave-", dir=str(_temp_root())))
    attempts: list[dict[str, Any]] = [
        {
            "format": _format_selector(format_id, has_ffmpeg),
        }
    ]
    if _is_youtube(url):
        attempts.extend(
            {
                "format": extra.get("format", _format_selector(format_id, has_ffmpeg)),
                **{k: v for k, v in extra.items() if k != "format"},
            }
            for extra in _youtube_attempts()
        )
        attempts.append(
            {
                "format": "18/22/best[ext=mp4][acodec!=none]/best",
                "extractor_args": {
                    "youtube": {
                        "player_client": ["android", "ios"],
                        "player_skip": ["webpage"],
                    }
                },
            }
        )

    hook = None
    if progress is not None:

        def hook(status: dict[str, Any]) -> None:
            if status.get("status") != "downloading":
                return
            total = status.get("total_bytes") or status.get("total_bytes_estimate") or 0
            received = status.get("downloaded_bytes") or 0
            if total:
                progress(min(received / total, 0.99))

    last_error: Exception | None = None
    info: dict[str, Any] | None = None
    for extra in attempts:
        opts = _base_opts(settings, url)
        opts.update(
            {
                "outtmpl": str(workdir / "%(title).80B.%(ext)s"),
                "skip_download": False,
                **extra,
            }
        )
        if hook is not None:
            opts["progress_hooks"] = [hook]
        try:
            info = _run_ydl_raw(url, opts, download=True)
            last_error = None
            break
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            _clear_workdir(workdir)
            continue
    if info is None:
        raise _map_error(last_error or Exception("download failed"), url)

    files = [
        path
        for path in workdir.iterdir()
        if path.is_file() and path.suffix.lower() in {".mp4", ".webm", ".mov", ".m4v", ".mkv", ".m4a"}
    ]
    if not files:
        raise unsupported_format()
    video = max(files, key=lambda path: path.stat().st_size)
    if video.stat().st_size > settings.max_download_bytes:
        raise file_too_large()
    info = _unwrap_info(info) if isinstance(info, dict) else {}
    ext = video.suffix.lstrip(".").lower() or "mp4"
    title = _safe_title(str(info.get("title") or video.stem))
    return {
        "path": str(video.resolve()),
        "mime": f"video/{ext}" if ext != "m4a" else "audio/mp4",
        "name": f"{title}.{ext}",
        "filesize": video.stat().st_size,
    }


def _temp_root() -> Path:
    root = Path(tempfile.gettempdir()) / "socialsave-jobs"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _safe_title(title: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*]+', "_", title).strip() or "video"
    return cleaned[:80]


class MediaExtractor:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    async def analyze(self, url: str, *, platform: str, display_name: str) -> MediaMetadata:
        info = await asyncio.get_running_loop().run_in_executor(
            _EXECUTOR,
            _extract_sync,
            url,
            self._settings,
        )
        duration = info.get("duration")
        return MediaMetadata(
            platform=platform,
            title=str(info.get("title") or f"{display_name} video"),
            source_url=url,
            thumbnail=info.get("thumbnail") if isinstance(info.get("thumbnail"), str) else None,
            duration=int(duration) if isinstance(duration, (int, float)) else None,
            author=info.get("uploader") or info.get("creator") or info.get("channel"),
            formats=_build_formats(info),
            can_download=True,
        )

    async def download(
        self,
        url: str,
        format_id: str,
        progress: Optional[Callable[[float], None]] = None,
    ) -> dict[str, Any]:
        return await asyncio.get_running_loop().run_in_executor(
            _EXECUTOR,
            lambda: _download_sync(url, format_id, self._settings, progress),
        )
