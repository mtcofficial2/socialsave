"""Public-page fallbacks when yt-dlp cannot extract Instagram, X, Facebook, or Pinterest."""

from __future__ import annotations

import json
import re
from typing import Any, Optional
from urllib.parse import parse_qs, unquote, urlparse

import httpx

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)


def extract(url: str) -> Optional[dict[str, Any]]:
    host = (urlparse(url).hostname or "").lower()
    if "tiktok.com" in host:
        return _tiktok(url)
    if "instagram.com" in host or host.endswith("instagr.am"):
        return _instagram(url)
    if host in {"x.com", "twitter.com"} or host.endswith(".x.com") or host.endswith(".twitter.com"):
        return _twitter(url)
    if "facebook.com" in host or host.endswith("fb.com") or host.endswith("fb.watch"):
        return _facebook(url)
    if "pinterest.com" in host or host.endswith("pin.it"):
        return _pinterest(url)
    return None


def _client() -> httpx.Client:
    return httpx.Client(
        timeout=25,
        follow_redirects=True,
        headers={"User-Agent": _UA, "Accept-Language": "en-US,en;q=0.9"},
    )


def tiktok_video_id(url: str) -> Optional[str]:
    match = re.search(r"/(?:video|photo|v)/(\d{6,})", url)
    if match:
        return match.group(1)
    query = parse_qs(urlparse(url).query)
    for key in ("item_id", "aweme_id", "id"):
        value = query.get(key)
        if value and value[0].isdigit():
            return value[0]
    return None


def _twitter_id(url: str) -> Optional[str]:
    match = re.search(r"/(?:status|statuses)/(\d+)", url)
    if match:
        return match.group(1)
    query = parse_qs(urlparse(url).query)
    if query.get("id"):
        return query["id"][0]
    return None


def _instagram_id(url: str) -> Optional[str]:
    match = re.search(r"/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)", url)
    return match.group(1) if match else None


def _facebook_id(url: str) -> Optional[str]:
    parsed = urlparse(url)
    query = parse_qs(parsed.query)
    for key in ("v", "video_id", "story_fbid"):
        if query.get(key):
            return query[key][0]
    match = re.search(r"/(?:videos|reel|watch)/(?:vb\.\d+/)?(\d+)", parsed.path)
    return match.group(1) if match else None


def _pinterest_id(url: str) -> Optional[str]:
    match = re.search(r"/pin/(\d+)", url)
    return match.group(1) if match else None


def _as_info(
    *,
    title: str,
    webpage: str,
    stream: str,
    thumbnail: Optional[str] = None,
    duration: Optional[int] = None,
    author: Optional[str] = None,
    ext: str = "mp4",
) -> dict[str, Any]:
    return {
        "title": title or "Public video",
        "webpage_url": webpage,
        "url": stream,
        "ext": ext,
        "thumbnail": thumbnail,
        "duration": duration,
        "uploader": author,
        "formats": [
            {
                "url": stream,
                "ext": ext,
                "vcodec": "avc1",
                "acodec": "aac",
                "height": 720,
                "protocol": "https",
            }
        ],
        "http_headers": {"User-Agent": _UA, "Referer": webpage},
    }


def _tiktok(url: str) -> Optional[dict[str, Any]]:
    resolved = _follow(url)
    video_id = tiktok_video_id(resolved) or tiktok_video_id(url)
    with _client() as client:
        for api in (
            "https://www.tikwm.com/api/",
            "https://tikwm.com/api/",
        ):
            try:
                response = client.get(
                    api,
                    params={"url": resolved, "hd": 1},
                    headers={
                        "Accept": "application/json",
                        "Referer": "https://www.tikwm.com/",
                    },
                )
                if response.status_code >= 400:
                    continue
                data = response.json()
            except Exception:
                continue
            payload = data.get("data") if isinstance(data, dict) else None
            if not isinstance(payload, dict):
                continue
            stream = payload.get("hdplay") or payload.get("play") or payload.get("wmplay")
            if not isinstance(stream, str) or not stream.startswith("http"):
                continue
            author = payload.get("author") if isinstance(payload.get("author"), dict) else {}
            duration = payload.get("duration")
            return _as_info(
                title=str(payload.get("title") or "TikTok video")[:80],
                webpage=resolved,
                stream=stream,
                thumbnail=payload.get("cover") or payload.get("origin_cover"),
                duration=int(duration) if isinstance(duration, (int, float)) else None,
                author=str(author.get("unique_id") or author.get("nickname") or ""),
            )
        if video_id:
            embed = _tiktok_embed(client, video_id, resolved)
            if embed is not None:
                return embed
    return None


def _tiktok_embed(client: httpx.Client, video_id: str, webpage: str) -> Optional[dict[str, Any]]:
    try:
        response = client.get(f"https://www.tiktok.com/embed/v2/{video_id}")
        html = response.text
    except Exception:
        return None
    stream = (
        _search_url(html, r'"playAddr"\s*:\s*"([^"]+)"')
        or _search_url(html, r'"downloadAddr"\s*:\s*"([^"]+)"')
        or _search_url(html, r'"play_addr"[^]]*?"url_list"\s*:\s*\[\s*"([^"]+)"')
    )
    if not stream:
        return None
    title = _search_text(html, r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"') or "TikTok video"
    thumb = _search_url(html, r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"')
    return _as_info(title=title, webpage=webpage, stream=stream, thumbnail=thumb)


def _follow(url: str) -> str:
    with _client() as client:
        try:
            response = client.head(url)
            if str(response.url).startswith("http"):
                return str(response.url)
        except Exception:
            pass
        try:
            response = client.get(url)
            if str(response.url).startswith("http"):
                return str(response.url)
        except Exception:
            pass
    return url


def _twitter(url: str) -> Optional[dict[str, Any]]:
    status_id = _twitter_id(url)
    if not status_id:
        return None
    with _client() as client:
        for api in (
            f"https://api.fxtwitter.com/status/{status_id}",
            f"https://api.vxtwitter.com/status/{status_id}",
        ):
            try:
                response = client.get(api)
                if response.status_code >= 400:
                    continue
                data = response.json()
            except Exception:
                continue
            tweet = data.get("tweet") if isinstance(data, dict) else None
            if not isinstance(tweet, dict):
                tweet = data if isinstance(data, dict) else {}
            media = tweet.get("media") if isinstance(tweet.get("media"), dict) else {}
            videos = media.get("videos") if isinstance(media, dict) else None
            if not videos:
                videos = tweet.get("media_extended") or data.get("media_extended")
            if not isinstance(videos, list):
                continue
            best: Optional[str] = None
            for item in videos:
                if not isinstance(item, dict):
                    continue
                candidate = item.get("url") or item.get("video_url")
                variants = item.get("variants") if isinstance(item.get("variants"), list) else []
                for variant in variants:
                    if isinstance(variant, dict) and str(variant.get("content_type") or "").startswith("video"):
                        candidate = variant.get("url") or candidate
                if isinstance(candidate, str) and candidate.startswith("http"):
                    best = candidate
            if not best:
                continue
            return _as_info(
                title=str(tweet.get("text") or tweet.get("raw_text") or "X video")[:80],
                webpage=url,
                stream=best,
                thumbnail=_first_url(media.get("photos") if isinstance(media, dict) else None)
                or tweet.get("media_preview"),
                author=str((tweet.get("author") or {}).get("screen_name") or ""),
            )
    return None


def _instagram(url: str) -> Optional[dict[str, Any]]:
    shortcode = _instagram_id(url)
    if not shortcode:
        return None
    with _client() as client:
        for path in (f"/reel/{shortcode}/embed/", f"/p/{shortcode}/embed/", f"/tv/{shortcode}/embed/"):
            try:
                response = client.get("https://www.instagram.com" + path)
            except Exception:
                continue
            html = response.text
            video = _search_url(html, r'"video_url"\s*:\s*"([^"]+)"') or _search_url(
                html, r'<meta[^>]+property="og:video"[^>]+content="([^"]+)"'
            )
            if not video:
                continue
            title = _search_text(html, r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"') or "Instagram video"
            thumb = _search_url(html, r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"')
            return _as_info(title=title, webpage=url, stream=video, thumbnail=thumb)
    return None


def _facebook(url: str) -> Optional[dict[str, Any]]:
    video_id = _facebook_id(url)
    href = url
    if video_id:
        href = f"https://www.facebook.com/watch/?v={video_id}"
    from urllib.parse import quote

    plugin = "https://www.facebook.com/plugins/video.php?href=" + quote(href, safe="")
    with _client() as client:
        try:
            response = client.get(plugin)
        except Exception:
            return None
        html = response.text
        for pattern in (
            r'"playable_url_quality_hd"\s*:\s*"([^"]+)"',
            r'"playable_url"\s*:\s*"([^"]+)"',
            r'"hd_src(?:_no_ratelimit)?"\s*:\s*"([^"]+)"',
            r'"sd_src(?:_no_ratelimit)?"\s*:\s*"([^"]+)"',
            r'<meta[^>]+property="og:video"[^>]+content="([^"]+)"',
        ):
            video = _search_url(html, pattern)
            if video:
                title = _search_text(html, r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"') or "Facebook video"
                thumb = _search_url(html, r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"')
                return _as_info(title=title, webpage=href, stream=video, thumbnail=thumb)
    return None


def _pinterest(url: str) -> Optional[dict[str, Any]]:
    with _client() as client:
        try:
            response = client.get(url)
        except Exception:
            return None
        html = response.text
        video = (
            _search_url(html, r'"V_720P"\s*:\s*\{[^}]*"url"\s*:\s*"([^"]+)"')
            or _search_url(html, r'"V_480P"\s*:\s*\{[^}]*"url"\s*:\s*"([^"]+)"')
            or _search_url(html, r'"video_url"\s*:\s*"([^"]+)"')
            or _search_url(html, r'<meta[^>]+property="og:video"[^>]+content="([^"]+)"')
        )
        if not video:
            return None
        title = _search_text(html, r'<meta[^>]+property="og:title"[^>]+content="([^"]+)"') or "Pinterest video"
        thumb = _search_url(html, r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"')
        return _as_info(title=title, webpage=str(response.url), stream=video, thumbnail=thumb)


def _search_url(html: str, pattern: str) -> Optional[str]:
    match = re.search(pattern, html, re.I)
    if not match:
        return None
    value = _decode_js_string(match.group(1))
    if value.startswith("http"):
        return value
    return None


def _search_text(html: str, pattern: str) -> Optional[str]:
    match = re.search(pattern, html, re.I)
    if not match:
        return None
    return _decode_js_string(match.group(1))


def _decode_js_string(value: str) -> str:
    value = value.replace("\\/", "/")
    try:
        return json.loads(f'"{value}"')
    except Exception:
        return unquote(value.replace("\\u0026", "&"))


def _first_url(photos: Any) -> Optional[str]:
    if not isinstance(photos, list) or not photos:
        return None
    first = photos[0]
    if isinstance(first, dict):
        url = first.get("url") or first.get("media_url_https")
        return url if isinstance(url, str) else None
    return first if isinstance(first, str) else None
