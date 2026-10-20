"""A stand-in for WebDriverAgent that speaks real HTTP on loopback.

Most unit tests replace `_req` with a script, so they can never catch a bug
in the wire layer itself: a timeout that a reused keep-alive socket ignores,
or a misread WDA error body. This server answers with the bodies the vendored
WDA builds (FBResponsePayload.m, FBCommandStatus.m, FBSessionCommands.m),
keeps HTTP/1.1 connections open the way CocoaHTTPServer does, and can be told
to stall, drop a connection, or have its session taken by another client.

    server = FakeWDAServer().start()
    ...point IMIRROR_WDA at server.url...
    server.stop()
"""
from __future__ import annotations

import base64
import json
import re
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlsplit

PNG = b"\x89PNG\r\n\x1a\nfake"
W3C_ELEMENT_KEY = "element-6066-11e4-a52e-4f735466cecf"

# WDA puts NSThread.callStackSymbols here: long, and useless to an agent.
TRACEBACK = "\n".join(f"{i}   WebDriverAgentLib   0x00000001{i:08x} -[FBRoute mountRequest:]"
                      for i in range(40))

SOURCE_XML = ('<?xml version="1.0" encoding="UTF-8"?><XCUIElementTypeApplication '
              'type="XCUIElementTypeApplication" name="Fake" label="Fake" enabled="true" '
              'visible="true" x="0" y="0" width="402" height="874">'
              '<XCUIElementTypeButton type="XCUIElementTypeButton" name="OK" label="OK" '
              'enabled="true" visible="true" hittable="true" x="20" y="700" width="120" '
              'height="44"/></XCUIElementTypeApplication>')

SOURCE_JSON = {"type": "XCUIElementTypeApplication", "name": "Fake", "label": "Fake",
               "isEnabled": "1", "isVisible": "1",
               "rect": {"x": 0, "y": 0, "width": 402, "height": 874},
               "children": [{"type": "XCUIElementTypeButton", "name": "OK", "label": "OK",
                             "isEnabled": "1", "isVisible": "1",
                             "rect": {"x": 20, "y": 700, "width": 120, "height": 44}}]}


class FakeWDAServer:
    """One fake phone's WDA. Tests change the public attributes to script it;
    every request is logged in `requests` as (method, path, body)."""

    def __init__(self, *, session: str | None = None):
        self.lock = threading.Lock()
        self.active: str | None = session      # WDA keeps one session per phone
        self.requests: list[tuple[str, str, Any]] = []
        self.connections = 0                   # TCP connections accepted
        self.settings: dict[str, Any] = {}
        self.window = {"width": 402, "height": 874}
        # label -> element ids handed out in turn (the last one repeats).
        self.find_ids: dict[str, list[str]] = {}
        self.stale: set[str] = set()           # ids whose click says "stale"
        # route path (no query) -> seconds to sleep, one entry per request.
        self.delays: dict[str, list[float]] = {}
        # route path -> how many replies to cut off halfway (IncompleteRead).
        self.drops: dict[str, int] = {}
        # Close the socket silently after this many more replies, the way
        # CocoaHTTPServer drops an idle keep-alive connection.
        self.close_after: int | None = None
        self.json_source = True                # False: format=json is a 400
        self._httpd: ThreadingHTTPServer | None = None

    # ---- lifecycle ----------------------------------------------------------

    def start(self) -> "FakeWDAServer":
        httpd = _Server(("127.0.0.1", 0), _Handler)
        httpd.fake = self
        self._httpd = httpd
        threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.05},
                         daemon=True).start()
        return self

    def stop(self) -> None:
        if self._httpd is not None:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None

    @property
    def url(self) -> str:
        assert self._httpd is not None, "start() the server first"
        return f"http://127.0.0.1:{self._httpd.server_address[1]}"

    # ---- things other clients do to this phone -------------------------------

    def new_session(self) -> str:
        """Another client (an agent, the iMirror app) creates a session,
        which ends whichever session was active."""
        with self.lock:
            self.active = _new_id()
            self.settings = {}
            return self.active

    def restart(self) -> None:
        """WDA restarted: no session at all."""
        with self.lock:
            self.active = None
            self.settings = {}

    # ---- what tests read back -------------------------------------------------

    def paths(self, method: str | None = None) -> list[str]:
        with self.lock:
            return [p for m, p, _ in self.requests if method in (None, m)]

    def count(self, method: str, path: str) -> int:
        return sum(1 for p in self.paths(method) if p == path)

    # ---- routing (called with self.lock held) ----------------------------------

    def _ok(self, value: Any) -> tuple[int, dict]:
        return 200, {"value": value, "sessionId": self.active}

    def _err(self, status: int, error: str, message: str) -> tuple[int, dict]:
        return status, {"value": {"error": error, "message": message,
                                  "traceback": TRACEBACK},
                        "sessionId": self.active}

    def _route(self, method: str, raw_path: str, body: Any) -> tuple[int, dict]:
        parts = urlsplit(raw_path)
        path, query = parts.path, parse_qs(parts.query)
        if method == "GET" and path == "/status":
            return self._ok({
                "ready": True, "message": "WebDriverAgent is ready to accept commands",
                "state": "success",
                "os": {"name": "iOS", "version": "26.6", "sdkVersion": "26.0",
                       "testmanagerdVersion": 65535},
                "ios": {"ip": None}, "build": {"time": "Oct 19 2026 09:00:00",
                                               "productBundleIdentifier":
                                                   "com.facebook.WebDriverAgentRunner"},
                "device": "iphone"})
        if method == "POST" and path == "/session":
            if not isinstance((body or {}).get("capabilities"), dict):
                return self._err(500, "session not created",
                                 "'capabilities' is mandatory to create a new session")
            self.active = _new_id()
            self.settings = {}                 # resetSessionSettings
            return self._ok({"sessionId": self.active,
                             "capabilities": {"device": "iphone", "sdkVersion": "26.6"}})
        m = re.match(r"^/session/([^/]+)(/.*)?$", path)
        if m:
            if m.group(1) != self.active:      # FBRoute.decorateRequest
                return self._err(404, "invalid session id", "Session does not exist")
            return self._session_route(method, m.group(2) or "", body)
        if method == "GET" and path == "/window/size":
            return self._ok(dict(self.window))
        if method == "GET" and path == "/screenshot":
            return self._ok(base64.b64encode(PNG).decode())
        if method == "GET" and path == "/source":
            if query.get("format") == ["json"]:
                if not self.json_source:
                    return self._err(400, "invalid argument",
                                     "The format 'json' is not supported")
                return self._ok(SOURCE_JSON)
            return self._ok(SOURCE_XML)
        if method == "POST" and path == "/wda/homescreen":
            return self._ok(None)
        return self._err(404, "unknown command", "Unhandled route")

    def _session_route(self, method: str, sub: str, body: Any) -> tuple[int, dict]:
        if method == "POST" and sub == "/appium/settings":
            self.settings.update((body or {}).get("settings") or {})
            return self._ok(dict(self.settings))
        if method == "POST" and sub == "/element":
            value = str((body or {}).get("value", ""))
            label = re.search(r"'((?:[^'\\]|\\.)*)'", value)
            ids = self.find_ids.get(label.group(1).replace("\\'", "'") if label else "")
            if not ids:
                return self._err(404, "no such element",
                                 f"unable to find an element using "
                                 f"'{(body or {}).get('using')}', value '{value}'")
            eid = ids.pop(0) if len(ids) > 1 else ids[0]
            return self._ok({"ELEMENT": eid, W3C_ELEMENT_KEY: eid})
        m = re.match(r"^/element/([^/]+)/click$", sub)
        if method == "POST" and m:
            if m.group(1) in self.stale:
                return self._err(404, "stale element reference",
                                 f'The element identified by "{m.group(1)}" is either not '
                                 "present or it has expired from the internal cache. "
                                 "Try to find it again")
            return self._ok(None)
        if method == "POST" and sub in ("/actions", "/wda/keys", "/url", "/orientation",
                                        "/wda/apps/launch", "/wda/apps/terminate",
                                        "/wda/apps/activate", "/wda/pressButton"):
            return self._ok(None)
        if method == "POST" and sub == "/wda/apps/state":
            return self._ok(4)
        if method == "GET" and sub == "/window/size":
            return self._ok(dict(self.window))
        if method == "GET" and sub == "/orientation":
            return self._ok("PORTRAIT")
        return self._err(404, "unknown command", "Unhandled route")


def _new_id() -> str:
    return str(uuid.uuid4()).upper()


class _Server(ThreadingHTTPServer):
    daemon_threads = True
    fake: FakeWDAServer

    def handle_error(self, request, client_address):
        pass  # a client that timed out and hung up is expected here


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"             # keep-alive, like CocoaHTTPServer
    server: _Server

    def setup(self) -> None:
        super().setup()
        with self.server.fake.lock:
            self.server.fake.connections += 1

    def log_message(self, *args: Any) -> None:
        pass

    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def do_DELETE(self) -> None:
        self._handle("DELETE")

    def _handle(self, method: str) -> None:
        fake = self.server.fake
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw.decode("utf-8", "replace")
        route = urlsplit(self.path).path
        with fake.lock:
            fake.requests.append((method, self.path, body))
            delays = fake.delays.get(route)
            delay = delays.pop(0) if delays else 0.0
            drop = fake.drops.get(route, 0) > 0
            if drop:
                fake.drops[route] -= 1
        if delay:
            time.sleep(delay)
        with fake.lock:
            status, payload = fake._route(method, self.path, body)
            closing = False
            if fake.close_after is not None:
                fake.close_after -= 1
                closing = fake.close_after <= 0
                if closing:
                    fake.close_after = None
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json;charset=UTF-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if drop:
            # Promise the whole body, send half, hang up.
            self.wfile.write(data[: len(data) // 2])
            self.wfile.flush()
            self._hang_up()
            return
        self.wfile.write(data)
        self.wfile.flush()
        if closing:
            self._hang_up()                    # no "Connection: close": silent

    def _hang_up(self) -> None:
        self.close_connection = True
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
