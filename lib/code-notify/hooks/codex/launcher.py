#!/usr/bin/env python3
"""Run the Codex TUI through its local protocol, observing human requests only.

The CLI still owns the terminal and every protocol response. The stdio proxy
connects to Codex's normal daemon; this bridge neither answers requests nor
changes thread settings. Delivery and alert settings belong to notifier.sh.
"""

import asyncio
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import struct
import sys
from urllib.parse import unquote, urlparse


APPROVAL_METHODS = {
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
}
MAX_MESSAGE = 64 * 1024 * 1024


class AttentionEvents:
    def __init__(self, notify, cwd):
        self.notify = notify
        self.cwd = cwd
        self.threads = {}
        self.seen = set()

    def observe(self, message):
        if not isinstance(message, dict):
            return
        # Start/resume responses carry the actual project directory, including
        # when `codex resume` selects a thread from another project.
        thread = message.get("result", {}).get("thread") if isinstance(message.get("result"), dict) else None
        if message.get("method") == "thread/started" and isinstance(message.get("params"), dict):
            thread = message.get("params", {}).get("thread")
        if isinstance(thread, dict) and isinstance(thread.get("id"), str):
            self.threads[thread["id"]] = thread.get("cwd") or self.cwd

        method = message.get("method")
        if "id" not in message or message["id"] is None:
            return  # Lifecycle/Guardian notifications are not human requests.
        params = message.get("params")
        if not isinstance(params, dict):
            return
        alert = None
        if method in APPROVAL_METHODS:
            alert = "permission_prompt"
        elif method == "item/tool/requestUserInput":
            if params.get("isBlocking") is True and params.get("questions"):
                alert = "ask_user"
        elif method == "mcpServer/elicitation/request":
            alert = "elicitation_dialog"
        if alert is None:
            return
        identity = (params.get("threadId"), message["id"])
        if identity in self.seen:
            return
        self.seen.add(identity)
        cwd = params.get("cwd") or self.threads.get(params.get("threadId")) or self.cwd
        if isinstance(cwd, str) and cwd.startswith("file://"):
            cwd = unquote(urlparse(cwd).path)
        payload = {"type": alert, "cwd": cwd, "thread-id": params.get("threadId"), "client": "codex-cli"}
        if alert == "ask_user":
            payload["tool_input"] = {"questions": params["questions"]}
        self.notify(payload)


async def read_frame(reader):
    header = await reader.readexactly(2)
    first, second = header
    final, opcode, masked = bool(first & 128), first & 15, bool(second & 128)
    length = second & 127
    if length == 126:
        extra = await reader.readexactly(2)
        header += extra
        length = struct.unpack("!H", extra)[0]
    elif length == 127:
        extra = await reader.readexactly(8)
        header += extra
        length = struct.unpack("!Q", extra)[0]
    if masked or length > MAX_MESSAGE or first & 112:
        raise ValueError("invalid Codex WebSocket frame")
    data = await reader.readexactly(length)
    return header + data, final, opcode, data


async def bridge(reader, writer, proxy, events, header):
    # app-server proxy is a byte relay to the daemon's WebSocket socket. Keep
    # its native handshake and framing, changing only our private URL path.
    _, rest = header.split(b"\r\n", 1)
    proxy.stdin.write(b"GET / HTTP/1.1\r\n" + rest)
    await proxy.stdin.drain()
    writer.write(await proxy.stdout.readuntil(b"\r\n\r\n"))
    await writer.drain()

    async def to_server():
        while data := await reader.read(65536):
            proxy.stdin.write(data)
            await proxy.stdin.drain()

    async def to_client():
        parts = bytearray()
        while True:
            raw, final, opcode, data = await read_frame(proxy.stdout)
            # Forward before starting notification work so UI latency never
            # depends on desktop, sound, voice or remote notification delivery.
            writer.write(raw)
            await writer.drain()
            if opcode == 1:
                if final:
                    # Normal streaming messages need no reassembly or copy.
                    if b'"id"' in data:
                        try:
                            events.observe(json.loads(data))
                        except (ValueError, TypeError, KeyError):
                            pass
                    continue
                parts = bytearray(data)
            elif opcode == 0:
                parts.extend(data)
            else:
                continue  # Ping/pong/close belong to the native clients.
            if len(parts) > MAX_MESSAGE:
                raise ValueError("Codex message too large")
            if final:
                # Deltas have no request id; avoid parsing them on the hot path.
                if b'"id"' in parts:
                    try:
                        events.observe(json.loads(parts))
                    except (ValueError, TypeError, KeyError):
                        pass
                parts.clear()

    tasks = [asyncio.create_task(to_server()), asyncio.create_task(to_client())]
    try:
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def launch(codex, args):
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGINT, lambda: None)
    owner = asyncio.current_task()
    loop.add_signal_handler(signal.SIGTERM, owner.cancel)
    bootstrap = await asyncio.create_subprocess_exec(codex, "app-server", "daemon", "start", stdout=asyncio.subprocess.DEVNULL, start_new_session=True)
    if await bootstrap.wait():
        raise RuntimeError("cn codex requires Codex with app-server daemon/proxy support")
    proxy = None
    notifications = set()
    notifier = Path(__file__).resolve().parents[2] / "core" / "notifier.sh"

    async def deliver(payload):
        env = {**os.environ, "CODE_NOTIFY_CODEX_ATTENTION": "1"}
        process = await asyncio.create_subprocess_exec("bash", str(notifier), "notification", "codex", env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await process.communicate(json.dumps(payload).encode())

    def notify(payload):
        task = asyncio.create_task(deliver(payload))
        notifications.add(task)
        task.add_done_callback(notifications.discard)

    events = AttentionEvents(notify, os.getcwd())
    token = secrets.token_urlsafe(24)
    connected = False

    async def handle(reader, writer):
        nonlocal connected
        owns_connection = False
        try:
            header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
            if connected or not header.startswith(f"GET /{token} HTTP/1.1\r\n".encode()):
                return
            connected = owns_connection = True
            await bridge(reader, writer, proxy, events, header)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        except (ValueError, KeyError) as error:
            print(f"cn codex: {error}", file=sys.stderr)
        finally:
            if owns_connection:
                proxy.stdin.close()
            writer.close()

    server = await asyncio.start_server(handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    cli = None
    try:
        proxy = await asyncio.create_subprocess_exec(codex, "app-server", "proxy", stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, start_new_session=True)
        cli = await asyncio.create_subprocess_exec(codex, "--remote", f"ws://127.0.0.1:{port}/{token}", *args)
        # Ctrl-C belongs to the real CLI, which shares this terminal's process
        # group. Termination still tears down both children and the bridge.
        result = await cli.wait()
        if notifications:
            await asyncio.gather(*notifications, return_exceptions=True)
        return result
    finally:
        server.close()
        await server.wait_closed()
        for process in (cli, proxy):
            if process is not None and process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), 2)
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()


def main():
    codex = shutil.which("codex")
    if not codex:
        print("cn codex: Codex CLI is not installed", file=sys.stderr)
        return 1
    args = sys.argv[1:]
    # Help and maintenance commands do not open an interactive session.
    commands = {"exec", "e", "review", "login", "logout", "mcp", "mcp-server", "app-server", "completion", "sandbox", "debug", "apply", "a", "cloud", "features", "agents"}
    if any(arg in ("--help", "-h", "--version", "-V") for arg in args) or (args and args[0] in commands):
        os.execv(codex, [codex, *args])
    if any(arg == "--no-daemon" or arg == "--remote" or arg.startswith("--remote=") for arg in args):
        print("cn codex: attention alerts require the local Codex daemon; omit --remote/--no-daemon", file=sys.stderr)
        return 1
    try:
        return asyncio.run(launch(codex, args))
    except (OSError, RuntimeError) as error:
        print(f"cn codex: {error}", file=sys.stderr)
        return 1
    except asyncio.CancelledError:
        return 128 + signal.SIGTERM


if __name__ == "__main__":
    sys.exit(main())
