"""Integration tests: real Kong image + real config + real scripts, against
CONTROLLED stub upstreams (tests/integration/stub-upstream) on an isolated
network. Run through scripts/test-integration.ps1, which sets GATEWAY_* so
every script here operates on the throw-away gateway, never the lab's.

The stubs echo which backend answered and what it received, so routing,
X-Request-ID and traceparent propagation are asserted on what the BACKEND
saw, not only on what Kong claims.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import re
import time
import uuid

import httpx
import pytest

from tests.helpers import REPO_ROOT, docker, poll_until, run_script

PROXY = os.environ.get("GATEWAY_PROXY_URL", "http://localhost:18088")
ADMIN = os.environ.get("GATEWAY_ADMIN_URL", "http://127.0.0.1:18089")
STATUS = os.environ.get("GATEWAY_STATUS_URL", "http://127.0.0.1:18090")
EXPORTER = os.environ.get("GATEWAY_EXPORTER_URL", "http://127.0.0.1:19542")
PROJECT = os.environ.get("GATEWAY_COMPOSE_PROJECT", "api-gateway-it")
KONG_CONTAINER = f"{PROJECT}-api-gateway-1"
STATE_DIR = REPO_ROOT / os.environ.get("GATEWAY_STATE_DIR", ".it-state")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

pytestmark = pytest.mark.skipif(
    os.environ.get("GATEWAY_COMPOSE_PROJECT") is None,
    reason="run through scripts/test-integration.ps1 (needs the isolated gateway)",
)


def call(method: str, path: str, **kw) -> httpx.Response:
    return httpx.request(method, f"{PROXY}{path}", timeout=15, **kw)


def served_by(resp: httpx.Response) -> str:
    """Which stub answered - from the BODY the backend produced. A response
    Kong generated itself (429, 5xx...) has no such field."""
    try:
        return resp.json().get("service") or f"(kong {resp.status_code})"
    except ValueError:
        return f"(non-json {resp.status_code})"


def switch(script: str, *args: str) -> str:
    r = run_script(script, *args, "-Reason", "integration test")
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def routing() -> dict[str, str]:
    services = {s["id"]: s["name"] for s in httpx.get(f"{ADMIN}/services", timeout=5).json()["data"]}
    return {
        r["name"]: services[r["service"]["id"]]
        for r in httpx.get(f"{ADMIN}/routes", timeout=5).json()["data"]
        if r.get("service")
    }


def metric_value(text: str, name: str, **labels: str) -> float:
    total = 0.0
    for line in text.splitlines():
        if not line.startswith(name + "{"):
            continue
        if all(f'{k}="{v}"' in line for k, v in labels.items()):
            total += float(line.rsplit(" ", 1)[1])
    return total


def kong_access_logs(since_s: int = 120) -> list[dict]:
    r = docker("logs", "--since", f"{since_s}s", KONG_CONTAINER)
    out = []
    for line in (r.stdout + r.stderr).splitlines():
        line = line.strip()
        if line.startswith("{") and '"log_type":"access"' in line:
            out.append(json.loads(line))
    return out


@pytest.fixture(autouse=True)
def back_to_default():
    """Every test starts AND ends on the default routing."""
    run_script("rollback-all-to-monolith", "-Reason", "integration test reset")
    yield
    run_script("rollback-all-to-monolith", "-Reason", "integration test reset")


@pytest.fixture(scope="session", autouse=True)
def upstreams_healthy():
    def all_healthy() -> bool:
        for up in ("monolith", "user-service", "sales-service"):
            data = httpx.get(f"{ADMIN}/upstreams/{up}.upstream/health", timeout=5).json()["data"]
            if data[0]["health"] != "HEALTHY":
                return False
        return True

    poll_until(all_healthy, timeout=60, desc="all stub upstreams HEALTHY in Kong")


# --- default routing -----------------------------------------------------------------


def test_default_boot_routes_everything_to_the_monolith():
    assert routing() == {
        "users-read": "monolith",
        "users-write": "monolith",
        "sales-read": "monolith",
        "sales-write": "monolith",
    }
    for method, path in (("GET", "/users"), ("GET", "/users/1"), ("POST", "/users"), ("GET", "/sales/7"), ("POST", "/sales")):
        resp = call(method, path, json={} if method == "POST" else None)
        assert resp.status_code in (200, 201)
        assert served_by(resp) == "monolith"
        assert resp.headers["X-Upstream-Service"] == "monolith"
        assert resp.json()["method"] == method and resp.json()["path"] == path  # no strip_path, no rewrite


def test_route_status_reports_runtime_routing():
    r = run_script("route-status")
    assert r.returncode == 0, r.stderr
    assert "mode-1-all-monolith" in r.stdout
    assert "in sync" in r.stdout
    assert "user-service=HEALTHY" in r.stdout


# --- switching ------------------------------------------------------------------------


def test_users_reads_switch_then_rollback_with_the_same_url():
    url = "/users/42"
    assert served_by(call("GET", url)) == "monolith"

    out = switch("route-users-to-service")
    assert "users-read" in out
    assert routing()["users-read"] == "user-service"
    for _ in range(10):  # every worker, every request - deterministic
        assert served_by(call("GET", url)) == "user-service"
    # writes stay on the monolith: READ first, WRITE later
    assert served_by(call("POST", "/users", json={"name": "x"})) == "monolith"
    assert served_by(call("GET", "/sales/1")) == "monolith"

    state = json.loads((STATE_DIR / "routing.json").read_text(encoding="utf-8"))
    assert state["profile"] == "mode-2r-users-reads-service"
    assert state["routes"]["users-read"] == "user-service"
    assert "users-read monolith->user-service" in (STATE_DIR / "history.log").read_text(encoding="utf-8")

    switch("route-users-to-monolith")
    assert routing()["users-read"] == "monolith"
    assert served_by(call("GET", url)) == "monolith"


def test_sales_switch_needs_acknowledged_incompatibility():
    refused = run_script("route-sales-to-service")
    assert refused.returncode != 0
    assert routing()["sales-read"] == "monolith"  # nothing applied

    switch("route-sales-to-service", "-AcceptIncompatibility")
    assert served_by(call("GET", "/sales/5")) == "sales-service"
    assert served_by(call("POST", "/sales", json={})) == "monolith"

    switch("route-sales-to-monolith")
    assert served_by(call("GET", "/sales/5")) == "monolith"


def test_write_cutover_is_refused_by_default_and_explicit_when_accepted():
    refused = run_script("route-users-to-service", "-Scope", "All")
    assert refused.returncode != 0
    assert "WRITE CUTOVER" in re.sub(r"\s+", " ", refused.stdout + refused.stderr)
    assert routing()["users-write"] == "monolith"

    switch("route-users-to-service", "-Scope", "All", "-AcceptWriteDivergence", "-AcceptIncompatibility")
    assert served_by(call("POST", "/users", json={"name": "x"})) == "user-service"

    # Rollback of writes is always allowed - and warns that data is not reconciled.
    out = run_script("route-users-to-monolith", "-Reason", "integration test")
    assert out.returncode == 0
    assert "does not reconcile data" in re.sub(r"\s+", " ", out.stdout + out.stderr)
    assert served_by(call("POST", "/users", json={"name": "x"})) == "monolith"


def test_all_four_modes_apply():
    expectations = {
        "mode-1-all-monolith": ("monolith", "monolith"),
        "mode-2-users-service": ("user-service", "monolith"),
        "mode-3-sales-service": ("monolith", "sales-service"),
        "mode-4-all-services": ("user-service", "sales-service"),
    }
    for mode, (users, sales) in expectations.items():
        switch("set-routing-profile", "-Name", mode, "-AcceptWriteDivergence", "-AcceptIncompatibility")
        for method in ("GET", "POST"):
            assert served_by(call(method, "/users", json={} if method == "POST" else None)) == users, (mode, method)
            assert served_by(call(method, "/sales", json={} if method == "POST" else None)) == sales, (mode, method)


def test_applied_routing_survives_a_kong_restart():
    switch("route-users-to-service")
    r = docker("restart", KONG_CONTAINER, timeout=120)
    assert r.returncode == 0, r.stderr
    poll_until(lambda: httpx.get(f"{STATUS}/status/ready", timeout=3).status_code == 200, timeout=90, desc="kong ready")
    assert routing()["users-read"] == "user-service"
    poll_until(lambda: served_by(call("GET", "/users/1")) == "user-service", timeout=30, desc="user-service after restart")


def test_route_state_exporter_reflects_the_switch():
    def info() -> str:
        return httpx.get(f"{EXPORTER}/metrics", timeout=5).text

    assert 'gateway_route_upstream_info{route="users-read",domain="users",scope="read",upstream="monolith"} 1' in info()
    switch("route-users-to-service")
    text = info()
    assert 'gateway_route_upstream_info{route="users-read",domain="users",scope="read",upstream="user-service"} 1' in text
    assert 'gateway_route_on_monolith{route="users-read",domain="users",scope="read"} 0' in text
    assert "gateway_admin_api_up 1" in text


# --- correlation / tracing ------------------------------------------------------------------


def test_client_request_id_is_preserved_end_to_end():
    rid = f"it-{uuid.uuid4()}"
    resp = call("GET", "/users/1", headers={"X-Request-ID": rid})
    assert resp.headers["X-Request-ID"] == rid
    assert resp.json()["headers"]["x-request-id"] == rid  # what the backend received
    poll_until(lambda: any(e.get("request_id") == rid for e in kong_access_logs()), timeout=10, desc="access log line")
    line = next(e for e in kong_access_logs() if e.get("request_id") == rid)
    assert line["route"] == "users-read" and line["upstream"] == "monolith" and line["status"] == 200
    assert "headers" not in line["request"] and "headers" not in line["response"]  # never logged
    assert "id" not in line["request"]  # no second, Kong-only id


def test_missing_request_id_is_generated_once_and_shared():
    resp = call("GET", "/users/1")
    rid = resp.headers["X-Request-ID"]
    assert UUID_RE.match(rid)
    assert resp.json()["headers"]["x-request-id"] == rid  # same id downstream, not a new one
    assert "X-Kong-Request-Id" not in resp.headers


def test_malformed_request_id_is_replaced():
    resp = call("GET", "/users/1", headers={"X-Request-ID": "bad value <script>" + "x" * 200})
    assert UUID_RE.match(resp.headers["X-Request-ID"])
    assert resp.json()["headers"]["x-request-id"] == resp.headers["X-Request-ID"]


def test_w3c_traceparent_is_continued_not_fabricated():
    trace_id = uuid.uuid4().hex
    parent = uuid.uuid4().hex[:16]
    resp = call("GET", "/users/1", headers={"traceparent": f"00-{trace_id}-{parent}-01"})
    received = resp.json()["headers"]["traceparent"]
    version, got_trace, got_parent, _flags = received.split("-")
    assert version == "00"
    assert got_trace == trace_id  # same trace
    assert got_parent != parent  # Kong's own span is the backend's parent


# --- security --------------------------------------------------------------------------------


def test_security_headers_and_no_version_banner():
    resp = call("GET", "/users/1")
    assert resp.headers["X-Content-Type-Options"] == "nosniff"
    assert resp.headers["X-Frame-Options"] == "DENY"
    assert resp.headers["Referrer-Policy"] == "no-referrer"
    assert "Server" not in resp.headers  # upstream "stub/..." and Kong banner both removed
    assert "Via" not in resp.headers


def test_cors_is_answered_by_the_gateway():
    pre = call(
        "OPTIONS",
        "/users",
        headers={
            "Origin": "http://localhost:5173",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )
    assert pre.status_code == 200
    assert pre.headers["Access-Control-Allow-Origin"] == "http://localhost:5173"
    assert "POST" in pre.headers["Access-Control-Allow-Methods"]
    assert "X-Upstream-Service" not in pre.headers  # preflight never reached a backend

    actual = call("GET", "/users/1", headers={"Origin": "http://localhost:5173"})
    assert actual.headers["Access-Control-Allow-Origin"] == "http://localhost:5173"
    assert "X-Request-ID" in actual.headers["Access-Control-Expose-Headers"]
    # the backend's own credentials=true is stripped: one CORS policy, the gateway's
    assert "Access-Control-Allow-Credentials" not in actual.headers

    evil = call("GET", "/users/1", headers={"Origin": "http://evil.example"})
    assert "Access-Control-Allow-Origin" not in evil.headers


def test_client_forwarded_headers_are_not_trusted():
    # No trusted_ips: a client cannot pick the IP Kong rate-limits / logs on,
    # nor hand the backend a forged client address.
    spoofed = "203.0.113.66"
    resp = call("GET", "/users/1", headers={"X-Forwarded-For": spoofed, "X-Real-IP": spoofed})
    received = resp.json()["headers"]
    real_peer = received["x-real-ip"]
    assert real_peer != spoofed  # X-Real-IP is overwritten with the real peer
    # X-Forwarded-For is APPENDED to (standard proxy behaviour): only the last
    # hop is trustworthy, the leftmost entries are whatever the client sent.
    assert received["x-forwarded-for"].split(",")[-1].strip() == real_peer
    rid = resp.headers["X-Request-ID"]
    poll_until(lambda: any(e.get("request_id") == rid for e in kong_access_logs()), timeout=10, desc="access log")
    assert next(e for e in kong_access_logs() if e.get("request_id") == rid)["client_ip"] != spoofed


def test_oversized_payload_is_rejected_at_the_edge():
    before = len([e for e in kong_access_logs() if e.get("status") == 413])
    resp = call("POST", "/users", content=b"x" * (2 * 1024 * 1024), headers={"Content-Type": "application/json"})
    assert resp.status_code == 413
    assert "X-Upstream-Service" not in resp.headers  # Kong answered, backend never saw it
    poll_until(lambda: len([e for e in kong_access_logs() if e.get("status") == 413]) > before, timeout=10, desc="413 logged")


def test_internal_and_admin_endpoints_are_not_routed():
    for path in ("/internal/users/import", "/docs", "/openapi.json", "/metrics", "/health", "/services", "/config"):
        assert call("GET", path).status_code == 404, path
    assert call("POST", "/internal/users/import", json={}).status_code == 404
    ports = json.loads(docker("inspect", "-f", "{{json .NetworkSettings.Ports}}", KONG_CONTAINER).stdout)
    assert all(b["HostIp"] == "127.0.0.1" for b in ports["8001/tcp"]), ports["8001/tcp"]  # Admin API
    assert all(b["HostIp"] == "127.0.0.1" for b in ports["8100/tcp"]), ports["8100/tcp"]  # Status/metrics


def test_prometheus_metrics_per_route_and_upstream():
    call("GET", "/users/1")
    text = httpx.get(f"{STATUS}/metrics", timeout=5).text
    assert metric_value(text, "kong_http_requests_total", service="monolith", route="users-read", code="200") >= 1
    assert "kong_upstream_latency_ms_bucket" in text
    assert 'kong_upstream_target_health{upstream="user-service.upstream"' in text


def test_rate_limit_returns_429_then_recovers():
    # /gateway/health is answered by Kong itself: the burst never loads a backend.
    # Keep-alive connections: new TCP connections through Docker Desktop's port
    # forwarding are too slow to exceed 100 req/s on some machines.
    client = httpx.Client(timeout=10, limits=httpx.Limits(max_connections=10, max_keepalive_connections=10))

    def hit(_):
        return client.get(f"{PROXY}/gateway/health")

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        responses = list(pool.map(hit, range(400)))
    codes = [r.status_code for r in responses]
    limited = [r for r in responses if r.status_code == 429]
    assert limited, f"no 429 in a 400-request burst: {sorted(set(codes))}"
    assert set(codes) <= {200, 429}
    assert limited[0].headers["RateLimit-Limit"] == "100"
    assert "API rate limit exceeded" in limited[0].text
    # per-second window: recovers right after
    poll_until(lambda: hit(0).status_code == 200, timeout=5, desc="rate limit window reset")


# --- failure ---------------------------------------------------------------------------------


def test_upstream_down_gives_controlled_error_then_recovers():
    stub = f"{PROJECT}-stub-user-service-1"
    switch("route-users-to-service")
    assert served_by(call("GET", "/users/1")) == "user-service"
    metrics_before = httpx.get(f"{STATUS}/metrics", timeout=5).text
    failures_before = sum(
        metric_value(metrics_before, "kong_http_requests_total", service="user-service", route="users-read", code=c)
        for c in ("502", "503", "504")
    )
    assert docker("stop", stub).returncode == 0
    try:
        started = time.monotonic()
        seen: list[int] = []

        def failing() -> bool:
            resp = call("GET", "/users/1")
            seen.append(resp.status_code)
            return resp.status_code in (502, 503, 504)

        poll_until(failing, timeout=30, interval=0.5, desc="gateway 5xx for a stopped upstream")
        resp = call("GET", "/users/1", headers={"X-Request-ID": "it-upstream-down"})
        assert resp.status_code in (502, 503, 504), resp.text
        assert "X-Upstream-Service" not in resp.headers
        assert "user-service" not in resp.text  # no fake success, no backend body
        # NO silent fallback: the same read did NOT go to the monolith
        assert routing()["users-read"] == "user-service"
        print(
            f"\n  upstream down -> {resp.status_code} after {time.monotonic() - started:.1f}s (codes seen: {sorted(set(seen))})"
        )

        poll_until(
            lambda: any(e.get("request_id") == "it-upstream-down" for e in kong_access_logs()), timeout=10, desc="error logged"
        )
        line = next(e for e in kong_access_logs() if e.get("request_id") == "it-upstream-down")
        assert line["upstream"] == "user-service" and line["status"] == resp.status_code

        metrics_after = httpx.get(f"{STATUS}/metrics", timeout=5).text
        failures_after = sum(
            metric_value(metrics_after, "kong_http_requests_total", service="user-service", route="users-read", code=c)
            for c in ("502", "503", "504")
        )
        assert failures_after > failures_before
        # the monolith keeps serving its routes meanwhile
        assert served_by(call("POST", "/users", json={})) == "monolith"
    finally:
        assert docker("start", stub).returncode == 0

    started = time.monotonic()

    def stably_recovered() -> bool:
        # DNS re-resolution and the active health check converge separately,
        # so a single 200 can be followed by a transient 503: require 3 in a row.
        return all(served_by(call("GET", "/users/1")) == "user-service" for _ in range(3))

    poll_until(stably_recovered, timeout=90, interval=1, desc="stable recovery after upstream restart")
    print(f"  recovered in {time.monotonic() - started:.1f}s")
