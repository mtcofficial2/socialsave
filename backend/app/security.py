from __future__ import annotations

import ipaddress
import socket
from urllib.parse import urlparse

from app.errors import invalid_url

BLOCKED_NETWORKS = (
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("100.64.0.0/10"),
)

ALLOWED_SCHEMES = {"http", "https"}
BLOCKED_HOSTS = {"localhost", "metadata.google.internal"}


def validate_public_url(raw: str) -> str:
    if not raw or not isinstance(raw, str):
        raise invalid_url()
    trimmed = raw.strip()
    if len(trimmed) > 2048 or " " in trimmed:
        raise invalid_url("That URL is not valid.")
    parsed = urlparse(trimmed)
    if parsed.scheme not in ALLOWED_SCHEMES:
        raise invalid_url("Only http and https URLs are allowed.")
    if parsed.username or parsed.password:
        raise invalid_url("URLs with embedded credentials are not allowed.")
    host = (parsed.hostname or "").lower()
    if not host or host in BLOCKED_HOSTS or host.endswith(".localhost"):
        raise invalid_url("That host cannot be used.")
    try:
        ip = ipaddress.ip_address(host)
        if any(ip in network for network in BLOCKED_NETWORKS) or ip.is_private or ip.is_loopback:
            raise invalid_url("Private or local network addresses are not allowed.")
    except ValueError:
        pass
    _assert_public_host(host)
    return trimmed


def _assert_public_host(host: str) -> None:
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror as exc:
        raise invalid_url("The host could not be resolved.") from exc
    if not infos:
        raise invalid_url("The host could not be resolved.")
    for info in infos:
        ip_str = info[4][0]
        ip = ipaddress.ip_address(ip_str)
        if any(ip in network for network in BLOCKED_NETWORKS):
            raise invalid_url("Private or local network addresses are not allowed.")
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
            raise invalid_url("Private or local network addresses are not allowed.")


def assert_redirect_safe(url: str) -> None:
    validate_public_url(url)
