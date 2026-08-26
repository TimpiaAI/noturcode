#!/usr/bin/env python3
import asyncio
import datetime
import json
import os
import re
import time
import uuid
import iterm2

BRIDGE = os.path.expanduser("~/Library/Application Support/Noturcode/bin/noturcode-bridge")
LOG = os.path.expanduser("~/Library/Application Support/Noturcode/selection-provider.log")
REMOTE_TERMINALS = os.path.expanduser("~/Library/Application Support/Noturcode/remote-terminals")
CONNECTED_SESSIONS = os.path.expanduser("~/Library/Application Support/Noturcode/connected-sessions.json")
UUID_PATTERN = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
AGENT_SOURCES = {"claude", "codex", "gemini", "pi", "omp", "opencode", "grok", "harness"}

def record(message):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a", encoding="utf-8") as handle:
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        handle.write(f"{stamp} {message}\n")

async def main(connection):
    @iterm2.ContextMenuProviderRPC
    async def ask_noturcode(session_id=iterm2.Reference("id"), text=iterm2.Reference("selection")):
        record(f"invoked session={session_id!r} selection_chars={len(text or '')}")
        if not text or not text.strip():
            record("ignored empty selection")
            return
        try:
            process = await asyncio.create_subprocess_exec(
                BRIDGE, "ask-selection", "--session", session_id,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            output, error = await process.communicate(text.encode("utf-8"))
            record(
                f"bridge exit={process.returncode} stdout={output.decode(errors='replace').strip()!r} "
                f"stderr={error.decode(errors='replace').strip()!r}"
            )
        except Exception as error:
            record(f"bridge exception={error!r}")
            raise

    await ask_noturcode.async_register(
        connection,
        "Ask Noturcode",
        "ro.noturcode.ask-selection",
    )
    record("provider registered")

    def paste_pattern(modifier):
        pattern = iterm2.KeystrokePattern()
        pattern.required_modifiers = [modifier]
        pattern.forbidden_modifiers = [
            value for value in (
                iterm2.Modifier.COMMAND,
                iterm2.Modifier.CONTROL,
                iterm2.Modifier.OPTION,
                iterm2.Modifier.SHIFT,
                iterm2.Modifier.FUNCTION,
                iterm2.Modifier.NUMPAD,
            ) if value != modifier
        ]
        pattern.keycodes = [iterm2.Keycode.ANSI_V]
        return pattern

    async def invoke_image_paste(session_id):
        try:
            process = await asyncio.create_subprocess_exec(
                BRIDGE, "paste-image", "--session", session_id,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            output, error = await process.communicate()
            record(
                f"clipboard paste session={session_id!r} exit={process.returncode} "
                f"stdout={output.decode(errors='replace').strip()!r} "
                f"stderr={error.decode(errors='replace').strip()!r}"
            )
        except Exception as error:
            record(f"clipboard paste exception={error!r}")

    async def watch_session_paste(session_id):
        patterns = [
            paste_pattern(iterm2.Modifier.COMMAND),
            paste_pattern(iterm2.Modifier.CONTROL),
        ]
        last_paste = 0.0
        record(f"clipboard filter attached session={session_id!r}")
        try:
            async with iterm2.KeystrokeFilter(connection, patterns, session_id):
                async with iterm2.KeystrokeMonitor(connection, session_id) as monitor:
                    while True:
                        key = await monitor.async_get()
                        modifiers = set(key.modifiers)
                        if key.keycode != iterm2.Keycode.ANSI_V:
                            continue
                        if modifiers not in (
                            {iterm2.Modifier.COMMAND},
                            {iterm2.Modifier.CONTROL},
                        ):
                            continue
                        now = time.monotonic()
                        if now - last_paste < 0.35:
                            record(f"clipboard duplicate suppressed session={session_id!r}")
                            continue
                        last_paste = now
                        await invoke_image_paste(session_id)
        finally:
            record(f"clipboard filter detached session={session_id!r}")

    state_signature = None
    cached_sessions = set()

    def remote_paste_sessions():
        nonlocal state_signature, cached_sessions
        try:
            try:
                registry_metadata = os.stat(REMOTE_TERMINALS)
                registry_signature = (registry_metadata.st_mtime_ns, registry_metadata.st_size)
            except FileNotFoundError:
                registry_signature = None
            signature = registry_signature
            if signature == state_signature:
                return set(cached_sessions)
            found = set()
            if registry_signature is not None:
                for name in os.listdir(REMOTE_TERMINALS):
                    if name.endswith(".json"):
                        session_id = name[:-5]
                        try:
                            found.add(str(uuid.UUID(session_id)).upper())
                        except ValueError:
                            pass
            state_signature = signature
            cached_sessions = found
            return set(found)
        except Exception as error:
            record(f"clipboard session discovery exception={error!r}")
            return None

    async def watch_image_paste():
        tasks = {}
        while True:
            wanted = remote_paste_sessions()
            if wanted is None:
                await asyncio.sleep(1.0)
                continue
            for session_id, task in list(tasks.items()):
                if task.done():
                    record(f"clipboard watcher stopped session={session_id!r}")
                    tasks.pop(session_id)
            for session_id in set(tasks) - wanted:
                tasks.pop(session_id).cancel()
            for session_id in wanted - set(tasks):
                tasks[session_id] = asyncio.create_task(watch_session_paste(session_id))
            await asyncio.sleep(1.0)

    def normalized_terminal_id(value):
        if not isinstance(value, str):
            return None
        match = UUID_PATTERN.search(value)
        if match is None:
            return None
        try:
            return str(uuid.UUID(match.group(0))).upper()
        except ValueError:
            return None

    def tracked_iterm_cards():
        try:
            with open(CONNECTED_SESSIONS, "r", encoding="utf-8") as handle:
                payload = json.load(handle)
            found = {}
            for item in payload if isinstance(payload, list) else []:
                key = item.get("key") if isinstance(item, dict) else None
                terminal = item.get("terminal") if isinstance(item, dict) else None
                source = key.get("source") if isinstance(key, dict) else None
                session_id = key.get("sessionID") if isinstance(key, dict) else None
                terminal_value = terminal.get("sessionID") if isinstance(terminal, dict) else None
                terminal_id = normalized_terminal_id(terminal_value)
                if terminal_id and source in AGENT_SOURCES and isinstance(session_id, str) and session_id:
                    found.setdefault(terminal_id, []).append((source, session_id))
            return found
        except FileNotFoundError:
            return {}
        except Exception as error:
            record(f"pane card discovery exception={error!r}")
            return None

    async def emit_session_ended(source, session_id, terminal_id):
        try:
            process = await asyncio.create_subprocess_exec(
                BRIDGE, "emit", "--source", source, "--session", session_id,
                "--kind", "sessionEnded",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            output, error = await process.communicate()
            record(
                f"pane closed terminal={terminal_id!r} source={source!r} session={session_id!r} "
                f"exit={process.returncode} stdout={output.decode(errors='replace').strip()!r} "
                f"stderr={error.decode(errors='replace').strip()!r}"
            )
            return process.returncode == 0
        except Exception as error:
            record(f"pane close bridge exception={error!r}")
            return False

    async def watch_closed_sessions(connection):
        missing_counts = {}
        emitted = set()
        while True:
            cards = tracked_iterm_cards()
            if cards is None:
                await asyncio.sleep(1.0)
                continue
            try:
                app = await iterm2.async_get_app(connection)
                live = {
                    terminal_id
                    for window in app.windows
                    for tab in window.tabs
                    for session in tab.all_sessions
                    if (terminal_id := normalized_terminal_id(session.session_id)) is not None
                }
            except Exception as error:
                record(f"pane inventory exception={error!r}")
                await asyncio.sleep(1.0)
                continue

            missing_counts = {
                terminal_id: count
                for terminal_id, count in missing_counts.items()
                if terminal_id in cards
            }
            active_keys = {card for values in cards.values() for card in values}
            emitted.intersection_update(active_keys)
            for terminal_id, card_keys in cards.items():
                if terminal_id in live:
                    missing_counts.pop(terminal_id, None)
                    continue
                missing_counts[terminal_id] = missing_counts.get(terminal_id, 0) + 1
                if missing_counts[terminal_id] >= 2:
                    for source, session_id in card_keys:
                        key = (source, session_id)
                        if key not in emitted:
                            if await emit_session_ended(source, session_id, terminal_id):
                                emitted.add(key)
            await asyncio.sleep(1.0)

    await asyncio.gather(
        watch_image_paste(),
        watch_closed_sessions(connection),
    )

iterm2.run_forever(main)
