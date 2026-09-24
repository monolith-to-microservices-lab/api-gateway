"""Route-state exporter: Kong Admin API -> Prometheus.

Kong's own Prometheus plugin tells you where traffic WENT (per route/service
request counters). It cannot tell you where a route POINTS when nobody is
calling it. This exporter publishes the configured mapping so Grafana can
answer "/users -> ?" at any moment:

    gateway_route_upstream_info{route="users-read",domain="users",scope="read",upstream="user-service"} 1
    gateway_route_on_monolith{route="users-read",domain="users",scope="read"} 0
    gateway_admin_api_up 1

Standard library only (no dependencies to patch). Reads the Admin API on
every scrape - no cache, no background thread, never stale. Read-only: it
only issues GET /services and GET /routes.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ADMIN_URL = os.environ.get("KONG_ADMIN_URL", "http://api-gateway:8001").rstrip("/")
PORT = int(os.environ.get("EXPORTER_PORT", "9542"))
TIMEOUT_SECONDS = float(os.environ.get("ADMIN_TIMEOUT_SECONDS", "3"))
MONOLITH_SERVICE = "monolith"

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='{"timestamp":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","message":"%(message)s"}',
)
logger = logging.getLogger("gateway_route_exporter")


def _get(path: str) -> list[dict]:
    """GET a paginated Admin API collection (DB-less returns one page here)."""
    items: list[dict] = []
    url: str | None = f"{ADMIN_URL}{path}?size=1000"
    while url:
        with urllib.request.urlopen(url, timeout=TIMEOUT_SECONDS) as resp:  # noqa: S310 - fixed internal URL
            body = json.load(resp)
        items.extend(body.get("data", []))
        nxt = body.get("next")
        url = f"{ADMIN_URL}{nxt}" if nxt else None
    return items


def _label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\n")


def _split_route(name: str) -> tuple[str, str]:
    domain, _, scope = name.rpartition("-")
    if domain and scope in ("read", "write"):
        return domain, scope
    return name, ""


def collect() -> str:
    started = time.perf_counter()
    lines = [
        "# HELP gateway_route_upstream_info Configured upstream service of each Kong route (always 1).",
        "# TYPE gateway_route_upstream_info gauge",
    ]
    on_monolith = [
        "# HELP gateway_route_on_monolith 1 if the route currently points to the monolith, 0 if strangled.",
        "# TYPE gateway_route_on_monolith gauge",
    ]
    admin_up = 1
    try:
        services = {s["id"]: s["name"] for s in _get("/services")}
        for route in sorted(_get("/routes"), key=lambda r: r.get("name") or ""):
            name = route.get("name")
            service = route.get("service")
            if not name or not service:
                continue  # e.g. gateway-health: answered by Kong itself
            upstream = services.get(service["id"], "unknown")
            domain, scope = _split_route(name)
            labels = f'route="{_label(name)}",domain="{_label(domain)}",scope="{_label(scope)}"'
            lines.append(f'gateway_route_upstream_info{{{labels},upstream="{_label(upstream)}"}} 1')
            on_monolith.append(f"gateway_route_on_monolith{{{labels}}} {1 if upstream == MONOLITH_SERVICE else 0}")
    except Exception as exc:  # noqa: BLE001 - an exporter must answer even when Kong is down
        admin_up = 0
        logger.warning("admin api unreachable: %s", exc)
    lines.extend(on_monolith)
    lines += [
        "# HELP gateway_admin_api_up 1 if the Kong Admin API answered this scrape.",
        "# TYPE gateway_admin_api_up gauge",
        f"gateway_admin_api_up {admin_up}",
        "# HELP gateway_route_exporter_scrape_duration_seconds Time spent reading the Admin API.",
        "# TYPE gateway_route_exporter_scrape_duration_seconds gauge",
        f"gateway_route_exporter_scrape_duration_seconds {time.perf_counter() - started:.6f}",
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - http.server API
        if self.path == "/metrics":
            body = collect().encode()
            self._reply(200, "text/plain; version=0.0.4; charset=utf-8", body)
        elif self.path == "/health":
            self._reply(200, "application/json", b'{"status":"ok"}')
        else:
            self._reply(404, "text/plain", b"not found\n")

    def _reply(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - http.server API
        return  # Prometheus scrapes every 10 s; access lines would be pure noise


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)  # noqa: S104 - container port
    logger.info("listening on :%s, admin api %s", PORT, ADMIN_URL)
    server.serve_forever()


if __name__ == "__main__":
    main()
