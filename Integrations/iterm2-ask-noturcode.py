#!/usr/bin/env python3
import asyncio
import datetime
import json
import os
import time
import iterm2

BRIDGE = os.path.expanduser("~/Library/Application Support/Noturcode/bin/noturcode-bridge")
LOG = os.path.expanduser("~/Library/Application Support/Noturcode/selection-provider.log")

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

    async def remote_paste_sessions():
        try:
            process = await asyncio.create_subprocess_exec(
                BRIDGE, "paste-image-sessions",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            output, _ = await process.communicate()
            if process.returncode != 0:
                return None
            payload = json.loads(output.decode("utf-8"))
            return {value for value in payload.get("sessionIDs", []) if value}
        except Exception as error:
            record(f"clipboard session discovery exception={error!r}")
            return None

    async def watch_image_paste():
        tasks = {}
        while True:
            wanted = await remote_paste_sessions()
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

    await watch_image_paste()

iterm2.run_forever(main)
