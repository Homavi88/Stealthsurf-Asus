#!/usr/bin/env python3
"""Local mock of the standalone :1131 panel for README screenshots."""
from __future__ import annotations

import json
import os
import time
import urllib.parse
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "dist", "panel"))
EXT = os.path.join(ROOT, "ext", "ssurf")
os.makedirs(EXT, exist_ok=True)
os.makedirs(os.path.join(ROOT, "cgi-bin"), exist_ok=True)

BOOTSTRAP = {
    "ok": True,
    "standalone": True,
    "panel": {"url": "http://127.0.0.1:1131/", "ip": "192.168.50.1", "port": 1131},
    "xray": {
        "router": {
            "name": "RT-AX88U",
            "firmware": "3004.388.8",
            "language": "ru",
            "ip": "192.168.50.1",
            "territory": "RU/01",
            "wan_ip": "203.0.113.10",
            "wan_connected": True,
            "features": "ipv6 merlin",
            "is_gnuton": False,
            "cpu": 4,
            "devices_online": {},
            "devices": {},
        },
        "server": {"isRunning": True, "b4sni_isRunning": False},
        "custom_settings": {
            "stealthsurf_version": "1.4.16",
            "stealthsurf_startup": "y",
            "stealthsurf_page": "user2.asp",
        },
    },
}

UI_RESPONSE = {
    "xray": {
        "core_version": "26.9.9",
        "tested_core": "26.9.9",
        "ui_version": "1.4.16",
        "running": True,
        "uptime": 3600,
        "profile": "config.json",
        "profiles": ["config.json"],
        "ipsec": "off",
        "geodata": {"geoip": "2026-11-01", "geosite": "2026-11-01"},
    },
    "loading": False,
    "progress": 100,
}

XRAY_CONFIG = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "all-in",
            "protocol": "dokodemo-door",
            "listen": "0.0.0.0",
            "port": 5699,
            "settings": {"network": "tcp,udp", "followRedirect": True},
            "streamSettings": {"sockopt": {"tproxy": "tproxy"}},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        }
    ],
    "outbounds": [
        {
            "tag": "ss-101",
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": "nl.example.com",
                        "port": 443,
                        "users": [{"id": "00000000-0000-0000-0000-000000000001", "encryption": "none"}],
                    }
                ]
            },
            "streamSettings": {"network": "tcp", "security": "reality"},
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "outboundTag": "ss-101",
                "network": "tcp,udp",
                "name": "stealthsurf-default",
            }
        ],
    },
    "dns": {"servers": ["localhost"]},
}

FILES = {
    "xray-ui-response": UI_RESPONSE,
    "xray-config": XRAY_CONFIG,
    "connection-status": {
        "ss-101": {"alive": True, "delay": 42, "lastError": ""},
        "direct": {"alive": True, "delay": 1},
    },
    "ss_configs": [
        {
            "id": 101,
            "title": "Netherlands · Amsterdam",
            "protocol": "vless",
            "is_online": True,
            "_ss_source": "config",
            "_ss_location_title": "Netherlands",
            "_ss_location_code": "NL",
        },
        {
            "id": 202,
            "title": "Germany · Frankfurt",
            "protocol": "vless",
            "is_online": True,
            "_ss_source": "config",
            "_ss_location_title": "Germany",
            "_ss_location_code": "DE",
        },
    ],
    "balances": {
        "fetched_at": 1731800000,
        "total_balance": 450.0,
        "total_referral": 12.5,
        "currency": "RUB",
        "message": "Balances updated",
        "keys": [
            {
                "ok": True,
                "label": "primary",
                "key": "stlth_demo_000000000000000000000001",
                "balance": 450.0,
                "referral_balance": 12.5,
                "email": "user@example.com",
            }
        ],
    },
    "api_keys": [{"label": "primary", "hint": "stlth_…abc"}],
    "subscriptions": [],
    "clients-online": {},
    "geotags": {"geosite": ["google", "telegram"], "geoip": ["private", "cn"], "xrayui": []},
    "ss_locations": [{"id": "nl", "title": "Netherlands", "code": "NL"}],
    "ss_profile": {"email": "user@example.com"},
    "ss_subscriptions": [],
    "ss_paid_options": [],
    "ss_cloud_servers": [],
    "ss_tariffs": [],
    "ss_traffic": {},
    "ss_server_stats": {},
    "ss_available_servers": [],
    "ss_autofit": {},
    "failover-state": {},
    "rtls-results": {},
    "b4sni": {},
}

for name, data in FILES.items():
    for ext in (".json", ".cab"):
        with open(os.path.join(EXT, name + ext), "w", encoding="utf-8") as fh:
            json.dump(data, fh)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, fmt, *args):  # noqa: A003
        return

    def do_GET(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path.rstrip("/") == "/cgi-bin/bootstrap":
            body = json.dumps(BOOTSTRAP).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path.rstrip("/") == "/cgi-bin/status":
            now = time.time()
            # Rising counters so the UI can show non-zero rates between polls
            base = int(now * 40)
            body = json.dumps(
                {
                    "ok": True,
                    "running": True,
                    "pid": 4242,
                    "cpu_pct": 6 + int(now) % 5,
                    "mem_used_mb": 820,
                    "mem_total_mb": 2048,
                    "app_rss_mb": 93,
                    "wan_ip": "5.231.117.209",
                    "traffic": {
                        "vpn_up": base + 1200,
                        "vpn_down": base * 3 + 5000,
                        "direct_up": base // 4,
                        "direct_down": base // 8,
                    },
                    "ts": int(now),
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()

    def do_POST(self):  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path.rstrip("/") == "/cgi-bin/api":
            length = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(length)
            body = json.dumps({"ok": True, "queued": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)


def main() -> None:
    if not os.path.isfile(os.path.join(ROOT, "index.html")):
        raise SystemExit(f"missing {ROOT}/index.html — run pnpm build first")
    host, port = "127.0.0.1", 1131
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"MOCK_PANEL http://{host}:{port}/", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
