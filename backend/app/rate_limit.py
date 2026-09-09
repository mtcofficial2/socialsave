from __future__ import annotations

import time
from collections import defaultdict, deque

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware


class InMemoryRateLimiter(BaseHTTPMiddleware):
    """Simple per-IP limiter. Replace with Redis in production multi-instance deploys."""

    def __init__(self, app, analyze_per_minute: int = 30, download_per_minute: int = 10) -> None:
        super().__init__(app)
        self._analyze = analyze_per_minute
        self._download = download_per_minute
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    async def dispatch(self, request: Request, call_next):
        limit = self._limit_for(request.url.path)
        if limit is None:
            return await call_next(request)
        ip = request.client.host if request.client else "unknown"
        key = f"{ip}:{request.url.path.split('/')[3] if len(request.url.path.split('/')) > 3 else request.url.path}"
        now = time.time()
        window = self._hits[key]
        while window and now - window[0] > 60:
            window.popleft()
        if len(window) >= limit:
            return JSONResponse(
                status_code=429,
                content={
                    "success": False,
                    "error": {
                        "code": "rate_limited",
                        "message": "Too many requests. Please wait a moment and try again.",
                    },
                },
            )
        window.append(now)
        return await call_next(request)

    def _limit_for(self, path: str) -> int | None:
        if path.endswith("/analyze"):
            return self._analyze
        if path.endswith("/download") or "/files/" in path:
            return self._download
        return None
