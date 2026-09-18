from __future__ import annotations

import asyncio
import os
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
from app.providers.base import DownloadHandle, MediaMetadata
from app.providers import social_fallback, youtube_fallback

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


def requested_max_height(format_id: str, default_max_height: int = 480) -> Optional[int]:
    quality = (format_id or "auto").lower()
    if quality in {"original", "best"}:
        return None
    if quality in {"auto", "", "default"}:
        return default_max_height
    if quality == "4k":
        return 2160
    if quality.endswith("p") and quality[:-1].isdigit():
        return int(quality[:-1])
    return default_max_height


def _format_selector(format_id: str, has_ffmpeg: bool, max_height: int = 480) -> str:
    quality = (format_id or "auto").lower()
    if quality in {"auto", "", "default"}:
        quality = f"{max_height}p"
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
        }
        return mapping.get(quality, mapping.get(f"{max_height}p", _BEST_FORMAT))
    mapping = {
        "360p": "best[height<=360][acodec!=none][vcodec!=none]/best[height<=360]/best",
        "480p": "best[height<=480][acodec!=none][vcodec!=none]/best[height<=480]/best",
        "720p": "best[height<=720][acodec!=none][vcodec!=none]/best[height<=720]/best",
        "1080p": "best[height<=1080][acodec!=none][vcodec!=none]/best[height<=1080]/best",
        "1440p": "best[height<=1440][acodec!=none][vcodec!=none]/best[height<=1440]/best",
        "2160p": "best[height<=2160][acodec!=none][vcodec!=none]/best[height<=2160]/best",
        "original": "best[acodec!=none][vcodec!=none]/best",
    }
    return mapping.get(quality, mapping.get(f"{max_height}p", mapping["480p"]))


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
    elif host in {"x.com", "twitter.com"} or host.endswith(".x.com") or host.endswith(".twitter.com"):
        headers["Referer"] = "https://x.com/"

    opts: dict[str, Any] = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "noprogress": True,
        "retries": 5,
        "fragment_retries": 5,
        "socket_timeout": 25,
        "extractor_retries": 3,
        "max_filesize": settings.max_download_bytes,
        "restrictfilenames": True,
        "overwrites": True,
        "no_color": True,
        "ignoreconfig": True,
        "cachedir": False,
        "extract_flat": False,
        "skip_unavailable_fragments": True,
        "concurrent_fragment_downloads": 8,
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
    cookiefile = os.environ.get("YTDLP_COOKIES")
    if cookiefile and Path(cookiefile).is_file():
        opts["cookiefile"] = cookiefile
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
    if "unsupported url" in lower:
        return unsupported_platform()
    if "no video could be found" in lower or "no video formats" in lower:
        return platform_unavailable(
            "This post does not contain a public downloadable video."
        )
    if "empty media response" in lower:
        return private_video(
            "This Instagram post is not available without a login. Try a fully public Reel or post."
        )
    if "cannot parse data" in lower:
        return platform_unavailable(
            "Facebook blocked the public parser. Try a public watch or reel link that opens logged out."
        )
    if _is_tiktok(url) and any(
        token in lower
        for token in ("unable to extract", "webpage video data", "universal data")
    ):
        return platform_unavailable(
            "TikTok blocked the public parser. Try a fully public video, or try again in a moment."
        )
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


def _cookie_header(ydl: Any) -> str:
    jar = getattr(ydl, "cookiejar", None)
    if jar is None:
        return ""
    parts: list[str] = []
    try:
        for cookie in jar:
            name = getattr(cookie, "name", None)
            value = getattr(cookie, "value", None)
            if name and value:
                parts.append(f"{name}={value}")
    except Exception:
        return ""
    return "; ".join(parts)


def _run_ydl_raw(url: str, opts: dict[str, Any], *, download: bool) -> dict[str, Any]:
    import yt_dlp

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=download)
        cookie_header = _cookie_header(ydl)
    if not isinstance(info, dict):
        raise removed_video()
    if cookie_header:
        headers = dict(info.get("http_headers") or {})
        headers.setdefault("Cookie", cookie_header)
        info["http_headers"] = headers
        for item in info.get("formats") or []:
            if not isinstance(item, dict):
                continue
            item_headers = dict(item.get("http_headers") or headers)
            item_headers.setdefault("Cookie", cookie_header)
            item["http_headers"] = item_headers
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


def _impersonate(name: str) -> dict[str, Any]:
    return {"impersonate": name}


def _site_attempts(url: str) -> list[dict[str, Any]]:
    host = _hostname(url)
    attempts: list[dict[str, Any]] = []
    if "instagram.com" in host or host.endswith("instagr.am"):
        attempts.append({"extractor_args": {"instagram": {"app_id": ["936619743392459"]}}})
        attempts.append(_impersonate("chrome"))
    elif "facebook.com" in host or host.endswith("fb.com") or host.endswith("fb.watch"):
        attempts.append(_impersonate("chrome"))
    elif host in {"x.com", "twitter.com"} or host.endswith(".x.com") or host.endswith(".twitter.com"):
        attempts.append(
            {"extractor_args": {"twitter": {"api": ["syndication", "graphql", "legacy"]}}}
        )
        attempts.append(_impersonate("chrome"))
    elif "pinterest.com" in host or host.endswith("pin.it"):
        attempts.append(_impersonate("chrome"))
    elif "tiktok.com" in host:
        attempts.append(_impersonate("chrome"))
        attempts.append(_impersonate("safari"))
    attempts.append({})
    return attempts


def _extract_sync(url: str, settings: Settings) -> dict[str, Any]:
    if _is_tiktok(url):
        fallback = social_fallback.extract(url)
        if fallback is not None:
            return fallback
    if _is_youtube(url):
        mapped = _youtube_fallback_info(url)
        if mapped is not None:
            return mapped
        extras = _youtube_attempts()[:1]
    else:
        extras = _site_attempts(url)
    last_error: Exception | None = None
    for extra in extras:
        opts = _base_opts(settings, url)
        opts["skip_download"] = True
        if _is_youtube(url):
            opts["socket_timeout"] = 12
        opts.update(extra)
        try:
            return _unwrap_info(_run_ydl_raw(url, opts, download=False))
        except Exception as exc:  # noqa: BLE001
            last_error = exc
            continue
    if not _is_youtube(url):
        fallback = social_fallback.extract(url)
        if fallback is not None:
            return fallback
    if _is_youtube(url):
        raise platform_unavailable(
            "YouTube is blocking this free cloud server. TikTok and direct MP4 links still work."
        )
    raise _map_error(last_error or Exception("analyze failed"), url)


def _stream_needs_session(url: str, headers: Any) -> bool:
    cookies = ""
    if isinstance(headers, dict):
        cookies = str(headers.get("Cookie") or headers.get("cookie") or "")
    return "tt_chain_token" in url and "tt_chain_token" not in cookies


def _as_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _pick_progressive(
    info: dict[str, Any],
    *,
    max_height: Optional[int] = None,
) -> Optional[dict[str, Any]]:
    formats = [item for item in (info.get("formats") or []) if isinstance(item, dict)]
    progressive: list[dict[str, Any]] = []
    for item in formats:
        url = item.get("url")
        if not isinstance(url, str) or not url.startswith("http"):
            continue
        protocol = str(item.get("protocol") or "")
        if protocol.startswith("m3u8") or protocol.startswith("http_dash") or ".m3u8" in url:
            continue
        vcodec = item.get("vcodec")
        acodec = item.get("acodec")
        if vcodec in {None, "none"}:
            continue
        progressive.append(item)
        if acodec not in {None, "none"}:
            progressive.append(item)
    if not progressive and isinstance(info.get("url"), str) and str(info["url"]).startswith("http"):
        return {
            "url": info["url"],
            "ext": info.get("ext") or "mp4",
            "filesize": info.get("filesize") or info.get("filesize_approx"),
            "http_headers": info.get("http_headers") or {},
        }
    if not progressive:
        return None
    if max_height:
        capped = [
            item
            for item in progressive
            if not isinstance(item.get("height"), int) or item["height"] <= max_height
        ]
        if capped:
            progressive = capped
    def score(item: dict[str, Any]) -> tuple[int, int, int]:
        has_audio = 1 if item.get("acodec") not in {None, "none"} else 0
        height = item.get("height") if isinstance(item.get("height"), int) else 0
        tbr = int(item.get("tbr") or 0)
        return (has_audio, height, tbr)

    best = max(progressive, key=score)
    headers = best.get("http_headers") or info.get("http_headers") or {}
    return {
        "url": best["url"],
        "ext": best.get("ext") or info.get("ext") or "mp4",
        "filesize": best.get("filesize") or best.get("filesize_approx"),
        "http_headers": headers if isinstance(headers, dict) else {},
        "filename": info.get("title"),
    }


def _youtube_fallback_info(url: str) -> Optional[dict[str, Any]]:
    video_id = youtube_fallback.video_id_from_url(url)
    if not video_id:
        return None
    try:
        info = youtube_fallback.fetch_info(video_id)
    except Exception as exc:  # noqa: BLE001
        print(f"youtube fallback: {type(exc).__name__}: {exc}", flush=True)
        return None
    raw_formats: list[dict[str, Any]] = []
    for item in info.get("formatStreams") or []:
        if not isinstance(item, dict):
            continue
        label = str(item.get("qualityLabel") or "")
        height = youtube_fallback._int(label.replace("p", "")) if label.endswith("p") else None
        if not height:
            continue
        raw_formats.append(
            {
                "vcodec": "avc1",
                "acodec": "aac",
                "height": height,
                "ext": str(item.get("container") or "mp4"),
                "filesize": youtube_fallback._filesize(item),
            }
        )
    return {
        "title": info.get("title") or "YouTube video",
        "thumbnail": youtube_fallback.thumbnail_url(info),
        "duration": info.get("lengthSeconds"),
        "uploader": info.get("author"),
        "width": info.get("width"),
        "height": info.get("height"),
        "ext": "mp4",
        "formats": raw_formats,
        "_fallback": info,
    }


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
    selector = _format_selector(format_id, has_ffmpeg, settings.default_max_height)
    attempts: list[dict[str, Any]] = [
        {
            "format": selector,
        }
    ]
    if _is_youtube(url):
        attempts.extend(
            {
                "format": extra.get("format", selector),
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

    try:
        return _download_sync_inner(
            url,
            format_id,
            settings,
            workdir,
            attempts,
            hook,
        )
    except Exception:
        shutil.rmtree(workdir, ignore_errors=True)
        raise


def _download_sync_inner(
    url: str,
    format_id: str,
    settings: Settings,
    workdir: Path,
    attempts: list[dict[str, Any]],
    hook: Any,
) -> dict[str, Any]:
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
    if info is None and _is_youtube(url):
        # yt-dlp is often IP-blocked on Render; try a public metadata API then a direct file URL.
        video_id = youtube_fallback.video_id_from_url(url)
        if video_id:
            fallback = youtube_fallback.fetch_info(video_id)
            stream = youtube_fallback.pick_stream(fallback, format_id)
            dest = workdir / "youtube.mp4"
            size = youtube_fallback.download_stream(
                str(stream["url"]), dest, settings.max_download_bytes
            )
            title = _safe_title(str(fallback.get("title") or "youtube"))
            return {
                "path": str(dest.resolve()),
                "mime": "video/mp4",
                "name": f"{title}.mp4",
                "filesize": size,
            }
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
        raise file_too_large(settings.max_download_bytes)
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

    async def resolve_handle(self, url: str, format_id: str) -> DownloadHandle:
        info = await asyncio.get_running_loop().run_in_executor(
            _EXECUTOR,
            _extract_sync,
            url,
            self._settings,
        )
        title = _safe_title(str(info.get("title") or "video"))
        max_height = requested_max_height(format_id, self._settings.default_max_height)
        stream = _pick_progressive(info, max_height=max_height)
        if stream and isinstance(stream.get("url"), str) and _stream_needs_session(str(stream["url"]), stream.get("http_headers") or {}):
            fallback = social_fallback.extract(url) if _is_tiktok(url) else None
            if fallback is not None:
                stream = _pick_progressive(fallback, max_height=max_height) or stream
            else:
                stream = None
        if stream and isinstance(stream.get("url"), str):
            ext = str(stream.get("ext") or "mp4").replace(".", "") or "mp4"
            raw_headers = stream.get("http_headers") or {}
            headers = {
                str(key): str(value)
                for key, value in raw_headers.items()
                if isinstance(key, str)
            }
            if "User-Agent" not in headers:
                headers["User-Agent"] = _base_opts(self._settings, url)["http_headers"]["User-Agent"]
            if "Referer" not in headers:
                referer = (_base_opts(self._settings, url).get("http_headers") or {}).get("Referer")
                if referer:
                    headers["Referer"] = referer
            size = _as_int(stream.get("filesize"))
            if size is not None and size > self._settings.max_download_bytes:
                raise file_too_large(self._settings.max_download_bytes)
            return DownloadHandle(
                source_url=url,
                format_id=format_id or "auto",
                mime_type=f"video/{ext}" if ext != "m4a" else "audio/mp4",
                filesize=size,
                file_name=f"{title}.{ext}",
                upstream_url=str(stream["url"]),
                prepare_locally=False,
                http_headers=headers,
            )
        return DownloadHandle(
            source_url=url,
            format_id=format_id or "auto",
            mime_type="video/mp4",
            file_name=f"{title}.mp4",
            prepare_locally=True,
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
