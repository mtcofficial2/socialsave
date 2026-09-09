import pytest

from app.config import Settings
from app.errors import ApiError
from app.tokens import DownloadTokenService


def test_round_trip_token() -> None:
    service = DownloadTokenService(Settings(secret_key="test-secret"))
    token = service.issue({"url": "https://example.com/a.mp4"})
    payload = service.parse(token)
    assert payload["url"] == "https://example.com/a.mp4"


def test_rejects_tampered_token() -> None:
    service = DownloadTokenService(Settings(secret_key="test-secret"))
    token = service.issue({"url": "https://example.com/a.mp4"})
    tampered = token[:-2] + "aa"
    with pytest.raises(ApiError):
        service.parse(tampered)
