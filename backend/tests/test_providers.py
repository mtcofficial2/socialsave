import pytest

from app.config import Settings
from app.providers.direct import DirectVideoProvider
from app.providers.extractor import MediaExtractor
from app.providers.http import SafeHttp
from app.providers.oembed import TikTokProvider, YouTubeProvider
from app.providers.registry import ProviderRegistry


def test_detects_youtube() -> None:
    extractor = MediaExtractor(Settings())
    assert YouTubeProvider(extractor).can_handle("https://youtu.be/dQw4w9WgXcQ")
    assert YouTubeProvider(extractor).can_handle("https://www.youtube.com/watch?v=dQw4w9WgXcQ")


def test_detects_tiktok() -> None:
    extractor = MediaExtractor(Settings())
    assert TikTokProvider(extractor).can_handle("https://www.tiktok.com/@user/video/123")
    assert TikTokProvider(extractor).can_handle("https://vm.tiktok.com/ZMabcdef/")


def test_tiktok_video_id_from_public_and_photo_links() -> None:
    from app.providers.social_fallback import tiktok_video_id

    assert (
        tiktok_video_id("https://www.tiktok.com/@scout2015/video/6718335390845095173")
        == "6718335390845095173"
    )
    assert tiktok_video_id("https://www.tiktok.com/@user/photo/1234567890123456789") == (
        "1234567890123456789"
    )


def test_ascii_filename_strips_emoji_for_http_headers() -> None:
    from app.routers.download import ascii_filename

    name = ascii_filename("Scramble up ur name 😍❤️ #foryou.mp4")
    assert name.isascii()
    assert name.endswith(".mp4")
    assert '"' not in name


def test_detects_direct_video() -> None:
    provider = DirectVideoProvider(Settings(), SafeHttp(Settings()))
    assert provider.can_handle("https://cdn.example.com/film.mp4")
    assert not provider.can_handle("https://cdn.example.com/page")


def test_auto_format_selector_caps_height() -> None:
    from app.providers.extractor import _format_selector, requested_max_height

    assert requested_max_height("auto", 480) == 480
    assert requested_max_height("720p", 480) == 720
    assert requested_max_height("original", 480) is None
    assert "480" in _format_selector("auto", True, 480)
    assert "720" in _format_selector("720p", True, 480)
    assert "bv*" in _format_selector("original", True, 480)


def test_default_max_download_is_100mb() -> None:
    settings = Settings()
    assert settings.max_download_bytes == 104_857_600
    assert settings.default_max_height == 480


def test_job_store_purges_failed_jobs(monkeypatch) -> None:
    from app.jobs import JobStore

    store = JobStore(ttl_seconds=1)
    job = store.create()
    job.state = "failed"
    job.created_at = 0
    store.purge()
    assert store.get(job.id) is None


def test_disabled_platform_is_rejected() -> None:
    settings = Settings(enabled_platforms="direct")
    registry = ProviderRegistry(settings)
    with pytest.raises(Exception):
        registry.resolve("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
