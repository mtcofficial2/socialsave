from __future__ import annotations

from urllib.parse import urlparse

from app.providers.base import DownloadHandle, MediaMetadata, SocialMediaProvider
from app.providers.extractor import MediaExtractor


class ExtractingProvider(SocialMediaProvider):
    """Public video metadata + download via the server-side extractor."""

    supports_metadata = True
    supports_download = True
    notes = "Public videos can be saved when the source is reachable without a login."
    hosts: tuple[str, ...] = ()

    def __init__(self, extractor: MediaExtractor) -> None:
        self._extractor = extractor

    def can_handle(self, url: str) -> bool:
        host = (urlparse(url).hostname or "").lower().removeprefix("www.")
        return any(host == item or host.endswith(f".{item}") for item in self.hosts)

    async def analyze(self, url: str) -> MediaMetadata:
        return await self._extractor.analyze(
            url,
            platform=self.id,
            display_name=self.display_name,
        )

    async def create_download(self, url: str, format_id: str) -> DownloadHandle:
        return DownloadHandle(
            source_url=url,
            format_id=format_id or "auto",
            mime_type="video/mp4",
            prepare_locally=True,
        )


class TikTokProvider(ExtractingProvider):
    id = "tiktok"
    display_name = "TikTok"
    hosts = ("tiktok.com",)


class InstagramProvider(ExtractingProvider):
    id = "instagram"
    display_name = "Instagram"
    hosts = ("instagram.com", "instagr.am")


class FacebookProvider(ExtractingProvider):
    id = "facebook"
    display_name = "Facebook"
    hosts = ("facebook.com", "fb.com", "fb.watch")


class XProvider(ExtractingProvider):
    id = "x"
    display_name = "X"
    hosts = ("x.com", "twitter.com")


class YouTubeProvider(ExtractingProvider):
    id = "youtube"
    display_name = "YouTube"
    hosts = ("youtube.com", "youtu.be", "youtube-nocookie.com", "m.youtube.com", "music.youtube.com")


class RedditProvider(ExtractingProvider):
    id = "reddit"
    display_name = "Reddit"
    hosts = ("reddit.com", "v.redd.it")


class PinterestProvider(ExtractingProvider):
    id = "pinterest"
    display_name = "Pinterest"
    hosts = ("pinterest.com", "pin.it")
