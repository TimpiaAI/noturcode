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

iterm2.run_forever(main)
