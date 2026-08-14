from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import socket
import stat
import tempfile
import threading
import unittest
from unittest import mock


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
AGENT_SOURCE = REPOSITORY / "Integrations" / "noturcode-agent.py"


def load_agent():
    spec = importlib.util.spec_from_file_location("noturcode_remote_agent", AGENT_SOURCE)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class OneShotUnixServer:
    def __init__(self, path: pathlib.Path, response: dict):
        self.path = path
        self.response = response
        self.request = None
        self.raw_request = b""
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.ready = threading.Event()

    def _run(self):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.path))
        server.listen(1)
        self.ready.set()
        connection, _ = server.accept()
        chunks = []
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        self.raw_request = b"".join(chunks)
        self.request = json.loads(self.raw_request.decode("utf-8"))
        connection.sendall(json.dumps(self.response).encode("utf-8"))
        connection.close()
        server.close()

    def start(self):
        self.thread.start()
        self.ready.wait(timeout=1)

    def join(self):
        self.thread.join(timeout=1)


class RemoteAgentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.agent = load_agent()
        self.agent.CONFIG_DIR = self.root / ".config" / "noturcode"
        self.agent.PAIR_FILE = self.agent.CONFIG_DIR / "pair.json"
        self.agent.BACKUP_DIR = self.agent.CONFIG_DIR / "backups"
        self.agent.HOME_DIR = self.root
        self.agent.AGENT_PATH = self.root / ".local" / "bin" / "noturcode-agent"

    def tearDown(self):
        self.temporary.cleanup()

    def test_pair_uses_one_time_code_and_saves_private_token(self):
        socket_path = self.root / "pair.sock"
        server = OneShotUnixServer(socket_path, {"ok": True, "token": "durable-token"})
        server.start()
        with mock.patch.dict(os.environ, {"NOTURCODE_REMOTE_SOCKET": str(socket_path)}):
            self.assertEqual(self.agent.pair("123456"), 0)
        server.join()

        stored = json.loads(self.agent.PAIR_FILE.read_text(encoding="utf-8"))
        self.assertEqual(stored["token"], "durable-token")
        self.assertEqual(stat.S_IMODE(self.agent.PAIR_FILE.stat().st_mode), 0o600)
        self.assertEqual(server.request["type"], "remotePair")
        self.assertEqual(server.request["code"], "123456")
        self.assertTrue(server.raw_request.endswith(b"\n"))

    def test_hook_forwards_payload_and_returns_native_hook_output(self):
        self.agent.private_write(
            self.agent.PAIR_FILE,
            b'{"deviceID":"vps-1","deviceName":"test","token":"token-1"}\n',
        )
        socket_path = self.root / "hook.sock"
        server = OneShotUnixServer(
            socket_path,
            {"ok": True, "hookOutput": {"decision": "block", "reason": "connected"}},
        )
        server.start()
        output = io.StringIO()
        payload = b'{"hook_event_name":"UserPromptSubmit","session_id":"remote-1","prompt":"/nc demo"}'
        with mock.patch.dict(
            os.environ,
            {
                "NOTURCODE_REMOTE_SOCKET": str(socket_path),
                "NOTURCODE_TERMINAL_SESSION_ID": "w0t1:REMOTE",
                "SSH_CONNECTION": "127.0.0.1 50000 127.0.0.1 22",
            },
        ), mock.patch("sys.stdin", io.TextIOWrapper(io.BytesIO(payload))), contextlib.redirect_stdout(output):
            self.assertEqual(self.agent.hook("claude"), 0)
        server.join()

        self.assertEqual(json.loads(output.getvalue()), {"decision": "block", "reason": "connected"})
        self.assertEqual(server.request["type"], "remoteHook")
        self.assertEqual(server.request["terminalSessionID"], "w0t1:REMOTE")

    def test_hook_fails_open_without_a_tunnel(self):
        output = io.StringIO()
        error = io.StringIO()
        with mock.patch("sys.stdin", io.TextIOWrapper(io.BytesIO(b"{}"))), \
             mock.patch.dict(os.environ, {}, clear=True), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            self.assertEqual(self.agent.hook("codex"), 0)
        self.assertEqual(json.loads(output.getvalue()), {})
        self.assertIn("skipped", error.getvalue())

    def test_hook_install_preserves_other_commands_and_creates_backup(self):
        target = self.root / ".claude" / "settings.json"
        target.parent.mkdir(parents=True)
        target.write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "keep-me"}]}]}}),
            encoding="utf-8",
        )
        self.agent.BACKUP_DIR = self.root / ".config" / "noturcode" / "backups"

        self.assertTrue(self.agent.merge_hooks(target, "claude"))
        result = json.loads(target.read_text(encoding="utf-8"))
        commands = [item["command"] for group in result["hooks"]["Stop"] for item in group["hooks"]]
        self.assertIn("keep-me", commands)
        self.assertTrue(any("noturcode-agent" in command for command in commands))
        self.assertEqual(len(list(self.agent.BACKUP_DIR.rglob("settings.json"))), 1)


if __name__ == "__main__":
    unittest.main()
