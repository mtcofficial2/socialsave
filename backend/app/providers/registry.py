from __future__ import annotations

from app.config import Settings
from app.errors import platform_disabled, unsupported_platform
from app.providers.base import SocialMediaProvider
from app.providers.direct import DirectVideoProvider
from app.providers.extractor import MediaExtractor
from app.providers.http import SafeHttp
from app.providers.oembed import (
    FacebookProvider,
    InstagramProvider,
    PinterestProvider,
    RedditProvider,
    TikTokProvider,
    XProvider,
    YouTubeProvider,
)


class ProviderRegistry:
    def __init__(self, settings: Settings) -> None:
        http = SafeHttp(settings)
        extractor = MediaExtractor(settings)
        self._settings = settings
        self._providers: list[SocialMediaProvider] = [
            TikTokProvider(extractor),
            InstagramProvider(extractor),
            FacebookProvider(extractor),
            XProvider(extractor),
            YouTubeProvider(extractor),
            RedditProvider(extractor),
            PinterestProvider(extractor),
            DirectVideoProvider(settings, http, extractor),
        ]

    def all(self) -> list[SocialMediaProvider]:
        return list(self._providers)

    def is_enabled(self, provider: SocialMediaProvider) -> bool:
        return provider.id in self._settings.enabled_platform_set

    def resolve(self, url: str) -> SocialMediaProvider:
        for provider in self._providers:
            if provider.can_handle(url):
                if not self.is_enabled(provider):
                    raise platform_disabled()
                return provider
        direct = next(item for item in self._providers if item.id == "direct")
        if self.is_enabled(direct):
            return direct
        raise unsupported_platform()
