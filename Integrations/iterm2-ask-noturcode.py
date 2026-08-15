#!/usr/bin/env python3
import asyncio
import datetime
import os
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

    async def watch_image_paste():
        app = await iterm2.async_get_app(connection)
        paste_pattern = iterm2.KeystrokePattern()
        paste_pattern.required_modifiers = [iterm2.Modifier.COMMAND]
        paste_pattern.forbidden_modifiers = [
            iterm2.Modifier.CONTROL,
            iterm2.Modifier.OPTION,
            iterm2.Modifier.SHIFT,
            iterm2.Modifier.FUNCTION,
            iterm2.Modifier.NUMPAD,
        ]
        paste_pattern.keycodes = [iterm2.Keycode.ANSI_V]
        async with iterm2.KeystrokeFilter(connection, [paste_pattern]):
            async with iterm2.KeystrokeMonitor(connection) as monitor:
                while True:
                    key = await monitor.async_get()
                    if key.keycode != iterm2.Keycode.ANSI_V:
                        continue
                    if set(key.modifiers) != {iterm2.Modifier.COMMAND}:
                        continue
                    window = app.current_terminal_window
                    tab = window.current_tab if window else None
                    session = tab.current_session if tab else None
                    if not session:
                        continue
                    try:
                        process = await asyncio.create_subprocess_exec(
                            BRIDGE, "paste-image", "--session", session.session_id,
                            stdout=asyncio.subprocess.PIPE,
                            stderr=asyncio.subprocess.PIPE,
                        )
                        output, error = await process.communicate()
                        record(
                            f"clipboard paste session={session.session_id!r} exit={process.returncode} "
                            f"stdout={output.decode(errors='replace').strip()!r} "
                            f"stderr={error.decode(errors='replace').strip()!r}"
                        )
                    except Exception as error:
                        record(f"clipboard paste exception={error!r}")

    await watch_image_paste()

iterm2.run_forever(main)
