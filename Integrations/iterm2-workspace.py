#!/usr/bin/env python3
"""Snapshot and restore the full iTerm2 workspace for Noturcode.

Usage:
  iterm2-workspace.py snapshot <json-path>
  iterm2-workspace.py restore <json-path>

Snapshot walks every window -> tab -> split-pane tree and records, per pane,
the working directory, the foreground command line, and the pane size in
cells. Restore rebuilds the same windows, tabs, and split grid in new
windows, cds every pane to its saved directory, and retypes the saved
command. It never touches windows that already exist.
"""

import asyncio
import json
import os
import shlex
import subprocess
import sys

import iterm2

SHELL_JOBS = {"zsh", "bash", "fish", "sh", "tcsh", "dash", "csh", "ksh", "login"}


def is_shell(job_name):
    return (job_name or "").lstrip("-").split("/")[-1] in SHELL_JOBS


def cwd_from_pid(pid):
    if not pid:
        return ""
    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", str(int(pid)), "-d", "cwd", "-Fn"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        for line in out.splitlines():
            if line.startswith("n"):
                return line[1:]
    except Exception:
        pass
    return ""


def children_by_parent():
    table = {}
    try:
        out = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=10,
        ).stdout
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) < 3:
                continue
            pid, ppid, command = int(parts[0]), int(parts[1]), parts[2]
            table.setdefault(ppid, []).append((pid, command))
    except Exception:
        pass
    return table


def foreground_command(shell_pid, table):
    """Descend from the pane's shell to the first non-shell child.

    That child's argv is the command the user actually typed (iTerm2's own
    `commandLine` variable reports rewritten process titles instead).
    """
    queue = [shell_pid]
    while queue:
        pid = queue.pop(0)
        for child_pid, command in table.get(pid, []):
            base = command.split()[0].rsplit("/", 1)[-1]
            if base.lstrip("-") in SHELL_JOBS:
                queue.append(child_pid)
            else:
                return strip_interpreter(command.strip())
    return ""


def strip_interpreter(command):
    """`node /opt/homebrew/bin/codex resume X` -> `/opt/homebrew/bin/codex resume X`."""
    tokens = command.split()
    if len(tokens) >= 2:
        interpreter = tokens[0].rsplit("/", 1)[-1]
        if interpreter in ("node", "python", "python3") \
                and tokens[1].startswith("/") and os.access(tokens[1], os.X_OK):
            return " ".join(tokens[1:])
    return command


async def describe_session(session, process_table):
    async def var(name):
        try:
            return await session.async_get_variable(name) or ""
        except Exception:
            return ""

    shell_pid = 0
    try:
        shell_pid = int(await var("pid") or 0)
    except (TypeError, ValueError):
        pass
    cwd = await var("path")
    if not cwd:
        cwd = cwd_from_pid(shell_pid)
    job = await var("jobName")
    command = "" if is_shell(job) else foreground_command(shell_pid, process_table)
    pane = {"cwd": cwd, "cmd": command, "job": job, "name": session.name}
    grid = session.grid_size
    if grid:
        pane["cols"] = grid.width
        pane["rows"] = grid.height
    return pane


async def describe_node(node, process_table):
    if isinstance(node, iterm2.Splitter):
        return {
            "split": "v" if node.vertical else "h",
            "children": [await describe_node(child, process_table)
                         for child in node.children],
        }
    return {"pane": await describe_session(node, process_table)}


async def snapshot(connection, path):
    app = await iterm2.async_get_app(connection)
    process_table = children_by_parent()
    windows = []
    pane_count = 0
    for window in app.windows:
        tabs = []
        for tab in window.tabs:
            tabs.append({"tree": await describe_node(tab.root, process_table)})
            pane_count += len(tab.sessions)
        if not tabs:
            continue
        frame = await window.async_get_frame()
        windows.append({
            "frame": [frame.origin.x, frame.origin.y,
                      frame.size.width, frame.size.height],
            "tabs": tabs,
        })
    if not windows:
        raise RuntimeError("iTerm2 has no windows to snapshot.")
    payload = {"version": 1, "windows": windows}
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    print(json.dumps({"windows": len(windows), "panes": pane_count}))


async def build_node(node, session):
    """Recreate `node` inside `session`. Returns [(pane, session)] leaves."""
    if "pane" in node:
        return [(node["pane"], session)]
    vertical = node.get("split") == "v"
    children = node.get("children", [])
    regions = [session]
    for _ in range(len(children) - 1):
        regions.append(await regions[-1].async_split_pane(vertical=vertical))
    leaves = []
    for child, region in zip(children, regions):
        leaves.extend(await build_node(child, region))
    return leaves


async def restore(connection, path):
    # Registers the app delegate the session/window objects rely on.
    await iterm2.async_get_app(connection)
    with open(path, encoding="utf-8") as handle:
        payload = json.load(handle)
    windows = payload.get("windows", [])
    if not windows:
        raise RuntimeError("The saved layout file has no windows.")

    window_count = 0
    all_leaves = []
    for spec in windows:
        window = await iterm2.Window.async_create(connection)
        if window is None:
            raise RuntimeError("iTerm2 refused to create a window.")
        window_count += 1
        frame = spec.get("frame")
        if frame and len(frame) == 4:
            try:
                await window.async_set_frame(iterm2.util.Frame(
                    iterm2.util.Point(int(frame[0]), int(frame[1])),
                    iterm2.util.Size(int(frame[2]), int(frame[3])),
                ))
            except Exception:
                pass
        tab_specs = spec.get("tabs", [])
        tabs = [window.tabs[0]]
        for _ in tab_specs[1:]:
            tabs.append(await window.async_create_tab())
        for tab, tab_spec in zip(tabs, tab_specs):
            leaves = await build_node(tab_spec["tree"], tab.sessions[0])
            for pane, session in leaves:
                if pane.get("cols") and pane.get("rows"):
                    session.preferred_size = iterm2.util.Size(
                        pane["cols"], pane["rows"])
            try:
                await tab.async_update_layout()
            except Exception:
                pass
            all_leaves.extend(leaves)

    # Give every fresh shell a moment to print its prompt before typing.
    await asyncio.sleep(1.0)
    for pane, session in all_leaves:
        name = pane.get("name")
        if name:
            try:
                await session.async_set_name(name)
            except Exception:
                pass
        cwd = pane.get("cwd")
        if cwd:
            await session.async_send_text(" cd %s\n" % shlex.quote(cwd))
        command = pane.get("cmd")
        if command:
            await session.async_send_text(command + "\n")
    print(json.dumps({"windows": window_count, "panes": len(all_leaves)}))


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("snapshot", "restore"):
        print("usage: iterm2-workspace.py snapshot|restore <json-path>",
              file=sys.stderr)
        sys.exit(2)
    mode, path = sys.argv[1], sys.argv[2]

    async def run(connection):
        if mode == "snapshot":
            await snapshot(connection, path)
        else:
            await restore(connection, path)

    try:
        iterm2.run_until_complete(run, retry=True)
    except Exception as error:  # surface a readable one-line failure
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
