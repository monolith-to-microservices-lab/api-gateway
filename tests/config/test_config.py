"""Configuration tests - no gateway, no Docker.

Every routing profile is rendered through the REAL script
(scripts/render-config.ps1) and the resulting Kong declarative config is
checked for the invariants this repo promises: default = monolith, PATH +
METHOD routing, no silent retries, security plugins present and sane,
nothing internal exposed, Admin API never public. Kong's own parser
(`kong config parse`) is run separately by scripts/validate-config.ps1.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
import yaml

from tests.helpers import REPO_ROOT, run_script

PROFILES_DIR = REPO_ROOT / "routing" / "profiles"
PROFILES = sorted(p.stem for p in PROFILES_DIR.glob("*.json"))
ROUTES = ["users-read", "users-write", "sales-read", "sales-write"]
ALLOWED = {
    "users-read": {"monolith", "user-service"},
    "users-write": {"monolith", "user-service"},
    "sales-read": {"monolith", "sales-service"},
    "sales-write": {"monolith", "sales-service"},
}
READ_METHODS = {"GET", "HEAD", "OPTIONS"}
WRITE_METHODS = {"POST", "PUT", "PATCH", "DELETE"}


@pytest.fixture(scope="session")
def rendered(tmp_path_factory) -> dict[str, dict]:
    out = tmp_path_factory.mktemp("rendered")
    configs = {}
    for name in PROFILES:
        target = out / f"{name}.yml"
        r = run_script("render-config", "-Name", name, "-OutFile", str(target))
        assert r.returncode == 0, r.stdout + r.stderr
        configs[name] = yaml.safe_load(target.read_text(encoding="utf-8"))
    return configs


def profile(name: str) -> dict:
    return json.loads((PROFILES_DIR / f"{name}.json").read_text(encoding="utf-8"))


def routes_by_name(cfg: dict) -> dict[str, dict]:
    return {r["name"]: r for r in cfg["routes"]}


def plugins_by_name(cfg: dict) -> dict[str, dict]:
    return {p["name"]: p.get("config", {}) for p in cfg["plugins"]}


# --- profiles -----------------------------------------------------------------


def test_the_four_requested_modes_exist():
    for mode in ("mode-1-all-monolith", "mode-2-users-service", "mode-3-sales-service", "mode-4-all-services"):
        assert mode in PROFILES


@pytest.mark.parametrize("name", PROFILES)
def test_profile_is_well_formed(name):
    p = profile(name)
    assert p["name"] == name
    assert p["description"]
    assert set(p["routes"]) == set(ROUTES)
    for route, target in p["routes"].items():
        assert target in ALLOWED[route], f"{name}: {route} -> {target}"


def test_default_profile_routes_everything_to_the_monolith():
    assert set(profile("mode-1-all-monolith")["routes"].values()) == {"monolith"}


def test_compatibility_matrix_covers_every_allowed_target():
    compat = json.loads((REPO_ROOT / "routing" / "compatibility.json").read_text(encoding="utf-8"))
    for route, targets in ALLOWED.items():
        entry = compat["routes"][route]
        assert set(entry["targets"]) == targets
        assert entry["targets"]["monolith"]["flags"] == []  # source of truth: never guarded
    # every write route to a microservice must be flagged as a write cutover
    for route in ("users-write", "sales-write"):
        service = next(t for t in ALLOWED[route] if t != "monolith")
        assert "write-cutover" in compat["routes"][route]["targets"][service]["flags"]


# --- rendered config ------------------------------------------------------------


def test_committed_default_config_is_the_rendered_mode_1():
    committed = (REPO_ROOT / "kong" / "kong.default.yml").read_text(encoding="utf-8").replace("\r\n", "\n")
    r = run_script("render-config", "-Name", "mode-1-all-monolith")
    assert r.returncode == 0, r.stderr
    assert committed.strip() == r.stdout.replace("\r\n", "\n").strip()


@pytest.mark.parametrize("name", PROFILES)
def test_routes_follow_the_profile(rendered, name):
    cfg = rendered[name]
    routes = routes_by_name(cfg)
    services = {s["name"] for s in cfg["services"]}
    for route, target in profile(name)["routes"].items():
        assert routes[route]["service"] == target
        assert target in services
    assert not re.search(r"__[A-Z_]+__", json.dumps(cfg))


def test_path_plus_method_routing(rendered):
    routes = routes_by_name(rendered["mode-1-all-monolith"])
    for domain in ("users", "sales"):
        read, write = routes[f"{domain}-read"], routes[f"{domain}-write"]
        assert set(read["methods"]) == READ_METHODS
        assert set(write["methods"]) == WRITE_METHODS
        assert read["paths"] == write["paths"]
        for r in (read, write):
            assert r["strip_path"] is False
            # preserve_host: redirects (FastAPI 307 on trailing slash) must
            # point at the public gateway host, not the internal backend name.
            assert r["preserve_host"] is True
            assert r["protocols"] == ["http"]


def test_nothing_internal_is_exposed(rendered):
    cfg = rendered["mode-4-all-services"]
    all_paths = [p for r in cfg["routes"] for p in r.get("paths", [])]
    assert sorted(all_paths) == sorted(
        ["~/users(/.*)?$", "~/users(/.*)?$", "~/sales(/.*)?$", "~/sales(/.*)?$", "/gateway/health"]
    )
    for forbidden in ("/internal", "/docs", "/openapi.json", "/metrics", "/health"):
        for p in all_paths:
            regex = p[1:] if p.startswith("~") else re.escape(p) + ".*"
            if p == "/gateway/health":
                continue
            assert not re.match(regex, forbidden + "/x"), f"{p} would expose {forbidden}"


def test_services_never_retry_and_use_health_checked_upstreams(rendered):
    cfg = rendered["mode-1-all-monolith"]
    upstreams = {u["name"]: u for u in cfg["upstreams"]}
    for svc in cfg["services"]:
        assert svc["retries"] == 0, f"{svc['name']}: a retry could duplicate a POST"
        up = upstreams[svc["host"]]
        active = up["healthchecks"]["active"]
        assert active["http_path"] == "/health"
        assert active["healthy"]["interval"] > 0 and active["unhealthy"]["interval"] > 0
    targets = {u["name"]: u["targets"][0]["target"] for u in cfg["upstreams"]}
    assert targets == {
        "monolith.upstream": "monolith-backend:8000",
        "user-service.upstream": "user-service:8000",
        "sales-service.upstream": "sales-service:8000",
    }
    assert "localhost" not in json.dumps(cfg["upstreams"]) and "127.0.0.1" not in json.dumps(cfg["upstreams"])


def test_security_plugins(rendered):
    plugins = plugins_by_name(rendered["mode-1-all-monolith"])
    for required in (
        "rate-limiting",
        "request-size-limiting",
        "cors",
        "response-transformer",
        "correlation-id",
        "prometheus",
        "file-log",
        "opentelemetry",
        "pre-function",
    ):
        assert required in plugins, required

    rl = plugins["rate-limiting"]
    assert rl["policy"] == "local" and rl["limit_by"] == "ip"
    assert 50 <= rl["second"] <= 1000 and rl["minute"] >= 1000  # generous enough for E2E

    assert plugins["request-size-limiting"]["size_unit"] == "megabytes"
    assert plugins["request-size-limiting"]["allowed_payload_size"] <= 1

    cors = plugins["cors"]
    assert "*" not in cors["origins"]
    assert "http://localhost:5173" in cors["origins"]
    assert cors["credentials"] is False
    assert "X-Request-ID" in cors["exposed_headers"]

    headers = plugins["response-transformer"]["add"]["headers"]
    assert "X-Content-Type-Options:nosniff" in headers
    assert "X-Frame-Options:DENY" in headers
    assert any(h.startswith("Referrer-Policy:") for h in headers)
    assert "Server" in plugins["response-transformer"]["remove"]["headers"]

    cid = plugins["correlation-id"]
    assert cid["header_name"] == "X-Request-ID" and cid["echo_downstream"] is True


def test_observability_plugins(rendered):
    plugins = plugins_by_name(rendered["mode-1-all-monolith"])
    prom = plugins["prometheus"]
    assert prom["status_code_metrics"] and prom["latency_metrics"] and prom["upstream_health_metrics"]
    assert prom["per_consumer"] is False  # cardinality

    fields = plugins["file-log"]["custom_fields_by_lua"]
    assert plugins["file-log"]["path"] == "/dev/stdout"
    for field in ("request_id", "route", "upstream", "method", "status", "trace_id"):
        assert field in fields
    # headers can carry credentials once auth exists: never logged
    assert fields["request.headers"] == "return nil" and fields["response.headers"] == "return nil"

    otel = plugins["opentelemetry"]
    assert otel["traces_endpoint"].startswith("http://otel-collector:4318")
    assert otel["propagation"]["extract"] == ["w3c"] and otel["propagation"]["inject"] == ["w3c"]


# --- compose / scripts --------------------------------------------------------------


def test_compose_pins_images_and_keeps_admin_api_local():
    text = (REPO_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    compose = yaml.safe_load(text)
    kong = compose["services"]["api-gateway"]
    base = (REPO_ROOT / "kong-image" / "Dockerfile").read_text(encoding="utf-8")
    assert re.search(r"^FROM kong:\d+\.\d+\.\d+$", base, re.M)  # pinned OSS base, never :latest
    assert re.search(r"^USER 1001$", base, re.M)  # back to non-root (kong) after patching
    ports = kong["ports"]
    assert any(p.endswith(":8000") and not p.startswith("127.0.0.1") for p in ports)  # proxy: public
    assert any(p.startswith("127.0.0.1:") and p.endswith(":8001") for p in ports)  # admin: localhost only
    assert any(p.startswith("127.0.0.1:") and p.endswith(":8100") for p in ports)  # status: localhost only
    assert kong["environment"]["KONG_ADMIN_GUI_LISTEN"] == "off"
    assert kong["environment"]["KONG_DATABASE"] == "off"
    for svc in compose["services"].values():
        assert ":latest" not in str(svc.get("image", ""))
        for p in svc.get("ports", []):
            if not p.endswith(":8000"):
                assert p.startswith("127.0.0.1:"), f"{p} should be localhost-only"
    dockerfile = (REPO_ROOT / "exporter" / "Dockerfile").read_text(encoding="utf-8")
    assert re.search(r"^FROM python:\d+\.\d+\.\d+-", dockerfile, re.M)
    assert re.search(r"^USER 1000$", dockerfile, re.M)


@pytest.mark.parametrize(
    "script,args,expected",
    [
        ("route-users-to-service", ["-Scope", "All"], "WRITE CUTOVER"),
        ("route-sales-to-service", [], "KNOWN INCOMPATIBLE"),
        ("set-routing-profile", ["-Name", "mode-2-users-service"], "WRITE CUTOVER"),
        ("set-routing-profile", ["-Name", "mode-4-all-services"], "WRITE CUTOVER"),
        ("set-routing-profile", ["-Name", "../../etc/passwd"], "Invalid profile name"),
        ("set-routing-profile", ["-Name", "no-such-mode"], "Unknown profile"),
    ],
)
def test_guarded_switches_are_refused_before_touching_the_gateway(script, args, expected, monkeypatch):
    # Point the scripts at a port where nothing listens: the refusal must
    # happen BEFORE any Admin API call (nothing applied, nothing persisted).
    monkeypatch.setenv("GATEWAY_ADMIN_URL", "http://127.0.0.1:9")
    monkeypatch.setenv("GATEWAY_STATE_DIR", str(Path(REPO_ROOT, ".it-state-unused")))
    r = run_script(script, *args)
    assert r.returncode != 0
    out = (r.stdout + r.stderr).replace("\n", " ")
    assert expected in re.sub(r"\s+", " ", out), out
    assert not Path(REPO_ROOT, ".it-state-unused", "routing.json").exists()


def test_profile_list_shows_guards():
    r = run_script("set-routing-profile", "-List")
    assert r.returncode == 0, r.stderr
    assert "mode-1-all-monolith" in r.stdout
    assert "needs: incompatible, write-cutover" in r.stdout or "needs: write-cutover, incompatible" in r.stdout
