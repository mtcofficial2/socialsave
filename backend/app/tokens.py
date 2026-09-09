from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from typing import Any

from app.config import Settings
from app.errors import unauthorized


class DownloadTokenService:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def issue(self, payload: dict[str, Any]) -> str:
        body = {
            **payload,
            "exp": int(time.time()) + self._settings.token_ttl_seconds,
        }
        raw = base64.urlsafe_b64encode(json.dumps(body, separators=(",", ":")).encode()).decode()
        signature = self._sign(raw)
        return f"{raw}.{signature}"

    def parse(self, token: str) -> dict[str, Any]:
        try:
            raw, signature = token.split(".", 1)
        except ValueError as exc:
            raise unauthorized() from exc
        expected = self._sign(raw)
        if not hmac.compare_digest(signature, expected):
            raise unauthorized()
        try:
            payload = json.loads(base64.urlsafe_b64decode(raw.encode()))
        except (ValueError, json.JSONDecodeError) as exc:
            raise unauthorized() from exc
        if int(payload.get("exp", 0)) < int(time.time()):
            raise unauthorized()
        return payload

    def _sign(self, raw: str) -> str:
        digest = hmac.new(
            self._settings.secret_key.encode(),
            raw.encode(),
            hashlib.sha256,
        ).digest()
        return base64.urlsafe_b64encode(digest).decode()
