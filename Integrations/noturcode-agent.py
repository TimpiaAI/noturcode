#!/usr/bin/env python3
"""Zero-dependency Noturcode helper for Linux and remote macOS shells."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import socket
import stat
import subprocess
import sys
import uuid


HOME_DIR = pathlib.Path.home()
CONFIG_DIR = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", HOME_DIR / ".config")) / "noturcode"
PAIR_FILE = CONFIG_DIR / "pair.json"
BACKUP_DIR = CONFIG_DIR / "backups"
AGENT_PATH = HOME_DIR / ".local" / "bin" / "noturcode-agent"
ENVIRONMENT_KEYS = (
    "PWD",
    "HOME",
    "TERM",
    "TERM_PROGRAM",
    "TERM_SESSION_ID",
    "LC_TERMINAL",
    "TERMINAL_EMULATOR",
    "SSH_TTY",
    "SSH_CONNECTION",
    "TMUX",
    "TMUX_PANE",
    "ZELLIJ",
    "ZELLIJ_SESSION_NAME",
    "ZELLIJ_PANE_ID",
    "WEZTERM_PANE",
    "WEZTERM_UNIX_SOCKET",
    "KITTY_WINDOW_ID",
    "KITTY_LISTEN_ON",
    "NOTURCODE_SESSION_NAME",
    "NOTURCODE_REMOTE_HOST",
)


HOOKS = {
    "claude": {
        "SessionStart": None,
        "SessionEnd": None,
        "UserPromptSubmit": None,
        "UserPromptExpansion": "^nc$",
        "PreToolUse": "*",
        "PostToolUse": "*",
        "PostToolUseFailure": "*",
        "Notification": "agent_needs_input|agent_completed",
        "SubagentStart": "*",
        "SubagentStop": "*",
        "Stop": None,
        "StopFailure": None,
    },
    "codex": {
        "SessionStart": None,
        "SessionEnd": None,
        "UserPromptSubmit": None,
        "PreToolUse": "*",
        "PostToolUse": "*",
        "SubagentStart": "*",
        "SubagentStop": "*",
        "Stop": None,
    },
    "gemini": {
        "SessionStart": None,
        "SessionEnd": None,
        "BeforeAgent": None,
        "AfterAgent": None,
        "BeforeTool": "*",
        "AfterTool": "*",
        "Notification": "*",
    },
}


def private_write(path: pathlib.Path, payload: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_pair() -> dict[str, str]:
    try:
        data = json.loads(PAIR_FILE.read_text(encoding="utf-8"))
        if data.get("deviceID") and data.get("token"):
            return data
    except (OSError, ValueError, TypeError):
        pass
    return {}


def device_id() -> str:
    stored = load_pair().get("deviceID")
    return stored or str(uuid.uuid4())


def socket_path() -> str:
    path = os.environ.get("NOTURCODE_REMOTE_SOCKET", "").strip()
    if not path:
        raise RuntimeError("No Noturcode tunnel. Start this VPS with nc on your Mac.")
    return path


def exchange(request: dict) -> dict:
    payload = json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n"
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2.0)
    try:
        client.connect(socket_path())
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        return json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        client.close()


def _read_frame(connection: socket.socket) -> bytes:
    payload = bytearray()
    while len(payload) < 2_000_000:
        chunk = connection.recv(16_384)
        if not chunk:
            break
        payload.extend(chunk)
        newline = payload.find(b"\n")
        if newline >= 0:
            return bytes(payload[:newline])
    return bytes(payload)


def _forward_frame(payload: bytes, target_path: str) -> bytes:
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    upstream.settimeout(3.0)
    try:
        upstream.connect(target_path)
        upstream.sendall(payload)
        upstream.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = upstream.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)
    finally:
        upstream.close()


def serve_proxy(listen_path: str, target_path: str, max_connections: int | None = None) -> int:
    listen = pathlib.Path(listen_path)
    try:
        status = listen.lstat()
        if status.st_uid != os.getuid() or not stat.S_ISSOCK(status.st_mode):
            raise RuntimeError(f"Refusing to replace unsafe proxy path: {listen}")
        listen.unlink()
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    handled = 0
    try:
        server.bind(str(listen))
        os.chmod(listen, 0o600)
        server.listen(16)
        while max_connections is None or handled < max_connections:
            connection, _ = server.accept()
            try:
                request = _read_frame(connection)
                response = _forward_frame(request, target_path)
                connection.sendall(response)
            except Exception as error:
                connection.sendall(json.dumps({"ok": False, "error": str(error)}).encode("utf-8"))
            finally:
                connection.close()
            handled += 1
        return 0
    finally:
        server.close()
        try:
            listen.unlink()
        except FileNotFoundError:
            pass


def pair(code: str) -> int:
    identifier = device_id()
    response = exchange(
        {
            "type": "remotePair",
            "code": code,
            "deviceID": identifier,
            "deviceName": socket.gethostname(),
        }
    )
    if not response.get("ok") or not response.get("token"):
        print(response.get("error") or "Pairing failed.", file=sys.stderr)
        return 1
    private_write(
        PAIR_FILE,
        (json.dumps(
            {
                "deviceID": identifier,
                "deviceName": socket.gethostname(),
                "token": response["token"],
            },
            indent=2,
            sort_keys=True,
        ) + "\n").encode("utf-8"),
    )
    print(f"Paired {socket.gethostname()} with Noturcode.")
    return 0


def hook(source: str) -> int:
    # Hooks must fail open. A network or pairing fault must never stop the harness.
    try:
        raw = sys.stdin.buffer.read()
        payload = json.loads(raw.decode("utf-8")) if raw.strip() else {}
        paired = load_pair()
        if not paired:
            raise RuntimeError("This VPS is not paired.")
        environment = {key: os.environ[key] for key in ENVIRONMENT_KEYS if os.environ.get(key)}
        response = exchange(
            {
                "type": "remoteHook",
                "token": paired["token"],
                "deviceID": paired["deviceID"],
                "source": source,
                "payload": payload,
                "environment": environment,
                "sourceProcessID": os.getppid(),
                "terminalSessionID": os.environ.get("NOTURCODE_TERMINAL_SESSION_ID"),
            }
        )
        if response.get("ok"):
            print(json.dumps(response.get("hookOutput") or {}, separators=(",", ":")))
        else:
            print("{}")
            print(response.get("error") or "Noturcode rejected the remote event.", file=sys.stderr)
    except Exception as error:  # fail open by contract
        print("{}")
        print(f"Noturcode remote hook skipped: {error}", file=sys.stderr)
    return 0


def backup(path: pathlib.Path) -> None:
    if not path.exists():
        return
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    try:
        relative = path.resolve().relative_to(HOME_DIR.resolve())
    except ValueError as error:
        raise RuntimeError(f"Refusing to back up a file outside {HOME_DIR}") from error
    destination = BACKUP_DIR / stamp / relative
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copy2(path, destination)


def contains_agent(group: object) -> bool:
    if not isinstance(group, dict):
        return False
    return any(
        isinstance(item, dict) and "noturcode-agent" in str(item.get("command", ""))
        for item in group.get("hooks", [])
    )


def hook_group(source: str, matcher: str | None) -> dict:
    command = f'"{AGENT_PATH}" hook --source {source}'
    timeout = 2000 if source == "gemini" else 2
    value = {"hooks": [{"type": "command", "command": command, "timeout": timeout}]}
    if matcher is not None:
        value["matcher"] = matcher
    return value


def merge_hooks(path: pathlib.Path, source: str) -> bool:
    try:
        root = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Invalid JSON in {path}: {error}") from error
    hooks = root.setdefault("hooks", {})
    changed = False
    for event, matcher in HOOKS[source].items():
        existing = [group for group in hooks.get(event, []) if not contains_agent(group)]
        desired = existing + [hook_group(source, matcher)]
        if desired != hooks.get(event, []):
            hooks[event] = desired
            changed = True
    if not changed:
        return False
    backup(path)
    private_write(path, (json.dumps(root, indent=2, sort_keys=True) + "\n").encode("utf-8"))
    return True


def install_hooks() -> int:
    targets = {
        "claude": HOME_DIR / ".claude" / "settings.json",
        "codex": HOME_DIR / ".codex" / "hooks.json",
        "gemini": HOME_DIR / ".gemini" / "settings.json",
    }
    configured: list[str] = []
    unchanged: list[str] = []
    for source, path in targets.items():
        executable = shutil.which(source)
        if not executable and not path.parent.exists():
            continue
        if merge_hooks(path, source):
            configured.append(source)
        else:
            unchanged.append(source)
    names = configured + unchanged
    print("Hooks ready: " + (", ".join(names) if names else "no supported CLI found yet"))
    return 0


def doctor() -> int:
    paired = load_pair()
    print("pair: " + (f"ready ({paired.get('deviceName', 'VPS')})" if paired else "missing"))
    try:
        path = socket_path()
        mode = stat.S_IMODE(os.stat(path).st_mode)
        print(f"tunnel: ready ({path}, mode {mode:o})")
    except (OSError, RuntimeError) as error:
        print(f"tunnel: unavailable ({error})")
    print(f"agent: {pathlib.Path(__file__).resolve()}")
    return 0 if paired else 1


def active_codex_session_ids(process_list: str) -> list[str]:
    identifiers: list[str] = []
    for match in re.finditer(r"\bcodex\s+resume\s+([0-9a-fA-F-]{36})\b", process_list):
        identifier = match.group(1).lower()
        if identifier not in identifiers:
            identifiers.append(identifier)
    return identifiers


def resume_codex() -> int:
    process_scan = subprocess.run(
        ["pgrep", "-af", "codex"],
        check=False,
        capture_output=True,
        text=True,
    )
    active = active_codex_session_ids(process_scan.stdout)
    if active:
        print("", file=sys.stderr)
        print("[!] Codex chats with an active writer:", file=sys.stderr)
        for identifier in active:
            print(f"    {identifier}", file=sys.stderr)
        print("    Close one in its old terminal before you select it here.", file=sys.stderr)
        print("", file=sys.stderr)
    try:
        result = subprocess.call(["codex", "resume", "--all"])
    except FileNotFoundError:
        print("Noturcode: Codex is not installed on this VPS.", file=sys.stderr)
        return 127
    if result != 0:
        print("", file=sys.stderr)
        print("Noturcode: The chat was not resumed.", file=sys.stderr)
        print("Choose another chat, or close its active writer first.", file=sys.stderr)
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="noturcode-agent")
    commands = parser.add_subparsers(dest="command", required=True)
    pair_parser = commands.add_parser("pair")
    pair_parser.add_argument("code")
    hook_parser = commands.add_parser("hook")
    hook_parser.add_argument("--source", required=True, choices=("claude", "codex", "gemini"))
    commands.add_parser("install")
    commands.add_parser("doctor")
    commands.add_parser("resume")
    proxy_parser = commands.add_parser("proxy")
    proxy_parser.add_argument("--listen", required=True)
    proxy_parser.add_argument("--target", required=True)
    proxy_parser.add_argument("--max-connections", type=int)
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    if arguments.command == "pair":
        return pair(arguments.code)
    if arguments.command == "hook":
        return hook(arguments.source)
    if arguments.command == "install":
        return install_hooks()
    if arguments.command == "doctor":
        return doctor()
    if arguments.command == "resume":
        return resume_codex()
    if arguments.command == "proxy":
        return serve_proxy(arguments.listen, arguments.target, arguments.max_connections)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
