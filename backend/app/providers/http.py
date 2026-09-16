from __future__ import annotations

from typing import Any, Optional

import httpx

from app.config import Settings
from app.errors import platform_unavailable, private_video, removed_video
from app.security import assert_redirect_safe, validate_public_url


class SafeHttp:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=self._settings.request_timeout_seconds,
            follow_redirects=False,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/126.0.0.0 Safari/537.36"
                )
            },
        )

    async def get_json(self, url: str, *, params: Optional[dict[str, Any]] = None) -> dict[str, Any]:
        validate_public_url(url)
        async with self.client() as client:
            response = await self._get_following_redirects(client, url, params=params)
        if response.status_code in {401, 403}:
            raise private_video()
        if response.status_code == 404:
            raise removed_video()
        if response.status_code >= 500:
            raise platform_unavailable()
        if response.status_code >= 400:
            raise private_video()
        try:
            data = response.json()
        except ValueError as exc:
            raise platform_unavailable() from exc
        if not isinstance(data, dict):
            raise platform_unavailable()
        return data

    async def head_or_get(self, url: str) -> httpx.Response:
        validate_public_url(url)
        async with self.client() as client:
            response = await self._request_following_redirects(client, "HEAD", url)
            if response.status_code in {403, 405, 501}:
                response = await self._request_following_redirects(
                    client,
                    "GET",
                    url,
                    headers={"Range": "bytes=0-0"},
                )
            return response

    async def stream(self, url: str, extra_headers: Optional[dict[str, str]] = None):
        validate_public_url(url)
        client = self.client()
        request = client.build_request("GET", url, headers=extra_headers)
        response = await client.send(request, stream=True)
        redirects = 0
        while response.is_redirect:
            redirects += 1
            if redirects > self._settings.max_redirects:
                await response.aclose()
                await client.aclose()
                raise private_video()
            location = response.headers.get("location")
            await response.aclose()
            if not location:
                await client.aclose()
                raise private_video()
            next_url = str(response.url.join(location))
            assert_redirect_safe(next_url)
            request = client.build_request("GET", next_url, headers=extra_headers)
            response = await client.send(request, stream=True)
        return client, response

    async def _get_following_redirects(
        self,
        client: httpx.AsyncClient,
        url: str,
        params: Optional[dict[str, Any]] = None,
    ) -> httpx.Response:
        return await self._request_following_redirects(
            client,
            "GET",
            url,
            params=params,
        )

    async def _request_following_redirects(
        self,
        client: httpx.AsyncClient,
        method: str,
        url: str,
        params: Optional[dict[str, Any]] = None,
        headers: Optional[dict[str, str]] = None,
    ) -> httpx.Response:
        current = url
        for _ in range(self._settings.max_redirects + 1):
            validate_public_url(current)
            response = await client.request(
                method,
                current,
                params=params,
                headers=headers,
            )
            if not response.is_redirect:
                return response
            location = response.headers.get("location")
            if not location:
                return response
            current = str(response.url.join(location))
            assert_redirect_safe(current)
            params = None
        raise private_video()
