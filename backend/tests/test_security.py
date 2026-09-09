import pytest

from app.errors import ApiError
from app.security import validate_public_url


def test_rejects_localhost() -> None:
    with pytest.raises(ApiError):
        validate_public_url("http://localhost/video.mp4")


def test_rejects_loopback_ip() -> None:
    with pytest.raises(ApiError):
        validate_public_url("http://127.0.0.1/video.mp4")


def test_rejects_private_ip() -> None:
    with pytest.raises(ApiError):
        validate_public_url("http://192.168.1.10/video.mp4")


def test_rejects_file_scheme() -> None:
    with pytest.raises(ApiError):
        validate_public_url("file:///etc/passwd")


def test_rejects_credentials() -> None:
    with pytest.raises(ApiError):
        validate_public_url("https://user:pass@example.com/video.mp4")


def test_accepts_https_public_host() -> None:
    url = validate_public_url(
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4"
    )
    assert url.startswith("https://")
