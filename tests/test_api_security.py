import logging

import pytest

from tests.api_helpers import SAMPLE, make_client

TOKEN = "tok-4f8a1c-secret"


def post(client, headers=None, **kw):
    return client.post("/api/translate", json={"text": SAMPLE}, headers=headers or {}, **kw)


@pytest.mark.parametrize("host", ["evil.com", "localhost.evil.com", "127.0.0.1.nip.io", "192.168.1.5"])
def test_unknown_hosts_rejected_in_local_mode(host):
    client, fake = make_client()
    assert post(client, {"host": host}).status_code == 400
    assert fake.calls == []


@pytest.mark.parametrize("host", ["localhost:8000", "127.0.0.1:8000", "[::1]:8000", "localhost"])
def test_loopback_hosts_ok(host):
    client, _ = make_client()
    assert post(client, {"host": host}).status_code == 200


def test_lan_mode_allows_private_ip_and_dot_local_only():
    client, _ = make_client(allow_lan=True, client_ip="192.168.1.20")
    assert post(client, {"host": "192.168.1.5:8000"}).status_code == 200
    assert post(client, {"host": "my-mac.local:8000"}).status_code == 200
    assert post(client, {"host": "8.8.8.8"}).status_code == 400
    assert post(client, {"host": "evil.com"}).status_code == 400


def test_extra_hosts_setting():
    client, _ = make_client(extra_hosts=("mymac",))
    assert post(client, {"host": "mymac:8000"}).status_code == 200


@pytest.mark.parametrize("ip,lan,ok", [
    ("127.0.0.1", False, True), ("::1", False, True), ("192.168.1.20", False, False),
    ("192.168.1.20", True, True), ("10.1.2.3", True, True), ("172.16.5.5", True, True),
    ("172.32.0.1", True, False), ("8.8.8.8", True, False), ("::ffff:8.8.8.8", True, False),
    ("testclient", True, False), ("", True, False),
])
def test_client_ip_rules(ip, lan, ok):
    client, fake = make_client(client_ip=ip, allow_lan=lan, base_url="http://localhost")
    r = post(client)
    assert (r.status_code == 200) is ok
    if not ok:
        assert r.status_code == 403 and fake.calls == []


def test_forwarded_header_is_not_trusted():
    client, _ = make_client(client_ip="8.8.8.8", allow_lan=True)
    assert post(client, {"x-forwarded-for": "192.168.1.2"}).status_code == 403


def test_cross_origin_post_rejected_and_no_cors_headers():
    client, fake = make_client()
    r = post(client, {"origin": "http://evil.example"})
    assert r.status_code == 403 and fake.calls == []
    r = post(client, {"origin": "null"})
    assert r.status_code == 403
    ok = post(client, {"origin": "http://localhost"})
    assert ok.status_code == 200
    assert not any(k.lower().startswith("access-control") for k in ok.headers)
    pre = client.options("/api/translate", headers={"origin": "http://evil.example",
                                                    "access-control-request-method": "POST"})
    assert "access-control-allow-origin" not in pre.headers


def test_text_plain_cross_site_form_post_rejected():
    client, fake = make_client()
    r = client.post("/api/translate", content='{"text": "あいうえおかきく"}',
                    headers={"content-type": "text/plain"})
    assert r.status_code == 415 and fake.calls == []


def test_token_required_when_configured():
    client, fake = make_client(token=TOKEN)
    assert post(client).status_code == 401
    assert post(client, {"x-mazemaze-token": "wrong"}).status_code == 401
    assert client.post("/api/translate?token=" + TOKEN, json={"text": SAMPLE}).status_code == 401
    # token check precedes validation
    assert client.post("/api/translate", json={"text": ""}).status_code == 401
    assert client.get("/api/status").status_code == 401
    assert fake.calls == []
    assert post(client, {"x-mazemaze-token": TOKEN}).status_code == 200


def test_page_is_served_without_token_and_does_not_contain_it():
    client, _ = make_client(token=TOKEN)
    r = client.get("/")
    assert r.status_code == 200 and TOKEN not in r.text
    assert "default-src 'self'" in r.headers["content-security-policy"]
    assert r.headers["x-content-type-options"] == "nosniff"


def test_token_never_logged(caplog):
    caplog.set_level(logging.DEBUG)
    client, _ = make_client(token=TOKEN)
    post(client, {"x-mazemaze-token": TOKEN})
    post(client, {"x-mazemaze-token": "bad-" + TOKEN})
    assert TOKEN not in caplog.text


@pytest.mark.parametrize("path", ["/static/../backend/app.py", "/static/%2e%2e/backend/app.py",
                                  "/static/..%2fbackend%2fapp.py", "/.env", "/static/.env",
                                  "/docs", "/openapi.json"])
def test_no_file_leaks(path):
    client, _ = make_client()
    r = client.get(path)
    assert r.status_code in (404, 400) and "FastAPI" not in r.text and "import" not in r.text


def test_static_assets_served():
    client, _ = make_client()
    assert client.get("/static/app.js").status_code == 200
    assert client.get("/static/style.css").status_code == 200


def test_post_without_content_length_is_rejected():
    client, fake = make_client()

    def chunks():
        yield b'{"text": "'
        yield "あ".encode() * 10
        yield b'"}'

    r = client.post("/api/translate", content=chunks(), headers={"content-type": "application/json"})
    assert r.status_code == 411 and fake.calls == []


def test_early_rejections_still_carry_security_headers():
    client, _ = make_client(token=TOKEN)
    for r in (post(client), post(client, {"host": "evil.com"}), post(client, {"origin": "http://x"})):
        assert r.status_code in (400, 401, 403)
        assert r.headers["x-content-type-options"] == "nosniff"
        assert "default-src 'self'" in r.headers["content-security-policy"]


def test_ipv4_mapped_addresses_judged_by_embedded_ipv4():
    client, _ = make_client(client_ip="::ffff:192.168.1.5", allow_lan=True)
    assert post(client).status_code == 200
    client, _ = make_client(client_ip="::ffff:8.8.8.8", allow_lan=True)
    assert post(client).status_code == 403


def test_settings_from_env(monkeypatch):
    from backend.config import Settings
    for k in ("MAZEMAZE_MODEL", "OLLAMA_URL", "MAZEMAZE_ALLOW_LAN", "MAZEMAZE_TOKEN",
              "MAZEMAZE_ALLOWED_HOSTS", "MAZEMAZE_DEADLINE", "MAZEMAZE_CALL_TIMEOUT"):
        monkeypatch.delenv(k, raising=False)
    s = Settings.from_env()
    assert (s.model, s.allow_lan, s.token, s.extra_hosts) == ("qwen3.5:9b", False, None, ())
    monkeypatch.setenv("MAZEMAZE_ALLOW_LAN", "1")
    monkeypatch.setenv("MAZEMAZE_TOKEN", "abc")
    monkeypatch.setenv("MAZEMAZE_ALLOWED_HOSTS", "Mymac, other.local")
    s = Settings.from_env()
    assert s.allow_lan and s.token == "abc" and s.extra_hosts == ("mymac", "other.local")
    monkeypatch.setenv("MAZEMAZE_DEADLINE", "nan-ish")
    import pytest
    from backend.config import ConfigError
    with pytest.raises(ConfigError):
        Settings.from_env()


def test_run_scripts_bind_correctly():
    from pathlib import Path
    root = Path(__file__).resolve().parent.parent / "scripts"
    local = (root / "run_local.sh").read_text()
    lan = (root / "run_lan.sh").read_text()
    assert "--host \"$HOST\"" in local and "HOST=127.0.0.1" in local and "0.0.0.0" not in local
    assert "--host 0.0.0.0" in lan and "MAZEMAZE_ALLOW_LAN=1" in lan and "openssl rand" in lan
    for text in (local, lan):
        assert "--no-proxy-headers" in text and "--workers" not in text.replace("# --workers", "")
