from app.providers.extractor import _map_error


def test_youtube_403_is_not_labeled_tiktok() -> None:
    error = _map_error(
        Exception("ERROR: unable to download video data: HTTP Error 403: Forbidden"),
        "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    )
    assert error.code == "platform_unavailable"
    assert "tiktok" not in error.message.lower()
    assert "youtube" in error.message.lower()


def test_tiktok_content_warning_is_labeled_tiktok() -> None:
    error = _map_error(
        Exception(
            "[TikTok] 123: This post may not be comfortable for some audiences. Log in for access."
        ),
        "https://www.tiktok.com/@user/video/123",
    )
    assert error.code == "private_video"
    assert "tiktok" in error.message.lower()


def test_generic_private_video_is_not_tiktok() -> None:
    error = _map_error(
        Exception("[youtube] Private video"),
        "https://youtu.be/abc",
    )
    assert "tiktok" not in error.message.lower()
