from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.base import BaseHTTPMiddleware

from app.config import get_settings
from app.errors import ApiError
from app.jobs import job_store
from app.rate_limit import InMemoryRateLimiter
from app.routers import analyze, download, health, platforms

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        path = request.url.path
        if path.startswith("/api/") or path == "/health":
            response.headers["Cache-Control"] = "no-store"
        elif path.endswith((".js", ".css", ".png", ".jpg", ".svg", ".json", ".webp")):
            response.headers["Cache-Control"] = "public, max-age=3600"
        return response


@asynccontextmanager
async def lifespan(_: FastAPI):
    settings = get_settings()
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s")
    job_store.configure(ttl_seconds=settings.job_ttl_seconds)
    job_store.start_reaper()
    logging.getLogger("socialsave.delivery").info(
        "api ready max_download_bytes=%s default_max_height=%s",
        settings.max_download_bytes,
        settings.default_max_height,
    )
    yield
    job_store.stop_reaper()


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title=settings.app_name,
        version="1.0.0",
        summary="Compliant media metadata and download API for SocialSave",
        lifespan=lifespan,
    )
    app.add_middleware(SecurityHeadersMiddleware)
    app.add_middleware(InMemoryRateLimiter)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["GET", "POST"],
        allow_headers=["Authorization", "Content-Type", "X-API-Key"],
    )
    app.include_router(health.router)
    app.include_router(platforms.router)
    app.include_router(analyze.router)
    app.include_router(download.router)

    @app.exception_handler(ApiError)
    async def api_error_handler(_, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.detail)

    if STATIC_DIR.is_dir():
        app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="web")

    return app


app = create_app()
