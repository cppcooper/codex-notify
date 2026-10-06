#!/usr/bin/env python3
"""Exercise the real launcher, protocol relay and existing notifier in isolation."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / "lib/code-notify/hooks/codex/launcher.py"
spec = importlib.util.spec_from_file_location("codex_launcher", LAUNCHER)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)


def send_frame(stream, data, masked=False, opcode=1, final=True):
    if not isinstance(data, bytes):
        data = json.dumps(data, ensure_ascii=False).encode()
    mask = b"test" if masked else b""
    size = len(data)
    code = size if size < 126 else 126 if size < 65536 else 127
    header = bytes([(128 if final else 0) | opcode, (128 if masked else 0) | code])
    if code == 126:
        header += struct.pack("!H", size)
    elif code == 127:
        header += struct.pack("!Q", size)
    stream.write(header + mask + (bytes(x ^ mask[i % 4] for i, x in enumerate(data)) if masked else data))
    stream.flush()


def read_exact(stream, size):
    parts = bytearray()
    while len(parts) < size:
        part = stream.read(size - len(parts))
        if not part:
            raise EOFError
        parts.extend(part)
    return bytes(parts)


def receive_frame(stream):
    head = read_exact(stream, 2)
    size = head[1] & 127
    if size == 126:
        size = struct.unpack("!H", read_exact(stream, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", read_exact(stream, 8))[0]
    mask = read_exact(stream, 4) if head[1] & 128 else b""
    data = read_exact(stream, size)
    if mask:
        data = bytes(x ^ mask[i % 4] for i, x in enumerate(data))
    return bool(head[0] & 128), head[0] & 15, data


def fake_codex():
    args = sys.argv[1:]
    with open(os.environ["FAKE_PROCESSES"], "a") as log:
        log.write(json.dumps({"pid": os.getpid(), "args": args}) + "\n")
    if args == ["app-server", "daemon", "start"]:
        return
    if args == ["app-server", "proxy"]:
        source, target = sys.stdin.buffer, sys.stdout.buffer
        headers = []
        while (line := source.readline()) != b"\r\n":
            headers.append(line)
        assert headers[0] == b"GET / HTTP/1.1\r\n"
        key = next(line.split(b":", 1)[1].strip() for line in headers if line.lower().startswith(b"sec-websocket-key:"))
        accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        target.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        target.flush()
        try:
            while True:
                _, opcode, data = receive_frame(source)
                if opcode != 1:
                    continue
                message = json.loads(data)
                if message.get("method") == "initialize":
                    send_frame(target, {"id": message["id"], "result": {"thread": {"id": "thread", "cwd": "/tmp/resumed project"}, "history": "x" * 131072}})
                elif message.get("method") == "test/stream":
                    for i in range(1000):
                        send_frame(target, {"method": "item/agentMessage/delta", "params": {"delta": str(i)}})
                elif message.get("method") == "test/emit":
                    event = message["params"]
                    # An interleaved control frame must not discard fragments.
                    payload = json.dumps(event, ensure_ascii=False).encode()
                    send_frame(target, payload[:20], final=False)
                    send_frame(target, b"ping", opcode=9)
                    send_frame(target, payload[20:], opcode=0)
                else:
                    with open(os.environ["FAKE_RESPONSES"], "a") as log:
                        log.write(json.dumps(message) + "\n")
        except EOFError:
            return
    if args and args[0] in ("--help", "--version"):
        return
    assert args[:1] == ["--remote"], args
    assert args[2:] == ["resume", "--last", "-c", "model=example", "prompt with spaces"], args
    endpoint = urlparse(args[1])
    sock = socket.create_connection((endpoint.hostname, endpoint.port), timeout=5)
    stream = sock.makefile("rwb", buffering=0)
    key = base64.b64encode(b"0123456789abcdef")
    stream.write(f"GET {endpoint.path} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ".encode() + key + b"\r\n\r\n")
    assert stream.readline().startswith(b"HTTP/1.1 101")
    while stream.readline() != b"\r\n":
        pass

    def receive():
        parts = bytearray()
        while True:
            final, opcode, data = receive_frame(stream)
            if opcode == 9:
                send_frame(stream, data, masked=True, opcode=10)
                continue
            parts.extend(data)
            if final:
                return json.loads(parts)

    send_frame(stream, {"id": 0, "method": "initialize", "params": {}}, masked=True)
    assert receive()["id"] == 0
    if os.environ.get("FAKE_HOLD"):
        signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
        Path(os.environ["FAKE_READY"]).touch()
        while True:
            time.sleep(0.05)

    def alerts(action, alert=None):
        subprocess.run(["bash", str(ROOT / "bin/code-notify"), "alerts", action, *([alert] if alert else [])], check=True, stdout=subprocess.DEVNULL)

    def emit(event):
        send_frame(stream, {"id": 99, "method": "test/emit", "params": event}, masked=True)
        assert receive() == event  # All IDs, text and parameters reach the UI.
        if event.get("id"):
            send_frame(stream, {"id": event["id"], "result": {"decision": "accept", "answeredBy": "user"}}, masked=True)

    def count(expected, quiet=False):
        path = Path(os.environ["FAKE_NOTIFICATIONS"])
        if quiet:
            time.sleep(0.2)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            actual = len(path.read_text().splitlines()) if path.exists() else 0
            if actual == expected:
                return
            time.sleep(0.02)
        raise AssertionError((expected, actual))

    approval = {"id": 10, "method": "item/commandExecution/requestApproval", "params": {"threadId": "thread", "itemId": "tool", "command": "sample"}}
    question = {"id": 20, "method": "item/tool/requestUserInput", "params": {"threadId": "thread", "isBlocking": True, "questions": [{"id": "choice", "header": "Choice", "question": "Which café?", "options": None}]}}
    alerts("add", "permission_prompt")
    alerts("add", "ask_user")
    send_frame(stream, {"id": 99, "method": "test/stream"}, masked=True)
    for i in range(1000):
        assert receive() == {"method": "item/agentMessage/delta", "params": {"delta": str(i)}}
    emit({"method": "item/guardianApprovalReview/completed", "params": {"status": "approved"}})
    emit({"method": "thread/status/changed", "params": {"threadId": "thread", "status": {"type": "active", "activeFlags": ["waitingOnUserInput"]}}})
    emit({**question, "id": 21, "params": {**question["params"], "isBlocking": False}})
    count(0, quiet=True)
    emit(approval)
    count(1)
    emit(approval)  # Replay does not alert twice.
    count(1, quiet=True)
    alerts("remove", "permission_prompt")
    emit({**approval, "id": 11})
    count(1, quiet=True)
    alerts("add", "permission_prompt")
    emit({**approval, "id": 12})
    count(2)
    emit(question)
    count(3)
    alerts("remove", "ask_user")
    emit({**question, "id": 22})
    count(3, quiet=True)
    emit({"method": "turn/completed", "params": {"threadId": "thread"}})
    count(3, quiet=True)  # Completion remains owned by the existing Stop hook.
    subprocess.run(["bash", str(ROOT / "bin/code-notify"), "off", "codex"], check=True, stdout=subprocess.DEVNULL)
    emit({**approval, "id": 13})
    count(3, quiet=True)
    sys.exit(23)


class CodexLauncherTests(unittest.TestCase):
    def test_confirmed_request_classification(self):
        delivered = []
        events = launcher.AttentionEvents(delivered.append, "/tmp/current")
        events.observe({"id": 1, "result": {"thread": {"id": "other", "cwd": "file:///tmp/resumed%20project"}}})
        for i, method in enumerate(launcher.APPROVAL_METHODS, start=10):
            events.observe({"id": i, "method": method, "params": {"threadId": "other"}})
        question = {"id": 20, "method": "item/tool/requestUserInput", "params": {"threadId": "other", "questions": [{"question": "Choose?"}]}}
        events.observe(question)  # Missing blocking status is not confirmation.
        events.observe({**question, "params": {**question["params"], "isBlocking": False}})
        events.observe({**question, "params": {**question["params"], "isBlocking": True}})
        events.observe({"id": 30, "method": "mcpServer/elicitation/request", "params": {"threadId": "other"}})
        events.observe({"id": 31, "method": "guardian/assessment", "params": {"approval": "required"}})
        events.observe({"type": "approval_requested", "id": 32, "params": {}})
        events.observe({"method": "thread/started", "params": []})
        events.observe([])
        self.assertEqual([event["type"] for event in delivered], ["permission_prompt"] * 3 + ["ask_user", "elicitation_dialog"])
        self.assertTrue(all(event["cwd"] == "/tmp/resumed project" for event in delivered))
        self.assertEqual(delivered[3]["tool_input"]["questions"], question["params"]["questions"])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "HOME": str(self.dir), "CODEX_HOME": str(self.dir / ".codex"), "PATH": f"{self.bin}:{os.environ['PATH']}", "CODE_NOTIFY_COMMAND_NAME": "cn", "CODE_NOTIFY_TAIL_SYNC": "1", "PYTHONDONTWRITEBYTECODE": "1"}
        for key in ("TMUX", "TMUX_PANE", "OPENCODE", "OPENCODE_PID", "CLAUDE_HOOK_TYPE"):
            self.env.pop(key, None)
        for key in ("PROCESSES", "RESPONSES", "NOTIFICATIONS", "READY"):
            self.env[f"FAKE_{key}"] = str(self.dir / key.lower())
        (self.bin / "codex").write_text(f"#!{sys.executable}\nimport runpy\nrunpy.run_path({str(Path(__file__).resolve())!r})['fake_codex']()\n")
        self.bin.joinpath("codex").chmod(0o755)
        self.bin.joinpath("notify-send").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FAKE_NOTIFICATIONS"\n')
        self.bin.joinpath("notify-send").chmod(0o755)
        # macOS's existing notifier uses terminal-notifier instead.
        self.bin.joinpath("terminal-notifier").write_text('#!/bin/sh\n[ "$1" = "-help" ] && exit 0\nprintf "%s\\n" "$*" >> "$FAKE_NOTIFICATIONS"\n')
        self.bin.joinpath("terminal-notifier").chmod(0o755)
        subprocess.run(["bash", "-c", 'source "$1/lib/code-notify/core/config.sh"; enable_codex_hooks', "test", str(ROOT)], env=self.env, check=True)

    def command(self):
        return ["bash", str(ROOT / "bin/code-notify"), "codex", "resume", "--last", "-c", "model=example", "prompt with spaces"]

    def test_protocol_delivery_and_live_settings(self):
        result = subprocess.run(self.command(), env=self.env, capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 23, result.stderr)
        notices = Path(self.env["FAKE_NOTIFICATIONS"]).read_text()
        self.assertEqual(len(notices.splitlines()), 3)
        self.assertIn("resumed project", notices)
        self.assertIn("Which café?", notices)
        responses = [json.loads(line) for line in Path(self.env["FAKE_RESPONSES"]).read_text().splitlines()]
        self.assertTrue(responses)
        self.assertTrue(all(message["result"]["answeredBy"] == "user" for message in responses))
        self.assert_children_gone()

    def assert_children_gone(self):
        for line in Path(self.env["FAKE_PROCESSES"]).read_text().splitlines():
            with self.assertRaises(ProcessLookupError):
                os.kill(json.loads(line)["pid"], 0)

    def test_terminal_signals_and_cleanup(self):
        for sig, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=sig):
                Path(self.env["FAKE_READY"]).unlink(missing_ok=True)
                process = subprocess.Popen(self.command(), env={**self.env, "FAKE_HOLD": "1"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                self.addCleanup(lambda p=process: p.kill() if p.poll() is None else None)
                deadline = time.monotonic() + 5
                while not Path(self.env["FAKE_READY"]).exists():
                    self.assertIsNone(process.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.02)
                os.killpg(process.pid, sig)
                _, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, expected, stderr.decode())
                self.assert_children_gone()

    def test_help_passthrough_and_unsupported_modes(self):
        result = subprocess.run([sys.executable, str(LAUNCHER), "--help"], env=self.env, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(Path(self.env["FAKE_PROCESSES"]).read_text().splitlines()), 1)
        for arg in ("--remote=ws://example", "--no-daemon"):
            result = subprocess.run([sys.executable, str(LAUNCHER), arg], env=self.env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"local Codex daemon", result.stderr)


if __name__ == "__main__":
    unittest.main()
