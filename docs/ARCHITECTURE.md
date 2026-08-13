# Architecture

Noturcode has three small layers.

## 1. Harness integrations

Claude Code, Codex, Gemini CLI, and OpenCode integrations normalize lifecycle events into a shared `BridgeEvent` model. Hook commands must fail open: the harness continues even when the app is not running.

The integration installer merges only Noturcode-owned handlers, preserves unrelated handlers, writes dated backups, and supports removal without stopping an agent session.

## 2. Local bridge and state

`noturcode-bridge` is a universal command-line executable installed under the user's Application Support directory. It validates hook payloads, redacts sensitive command arguments, and sends bounded events over a user-only Unix-domain socket.

The native process keeps disposable session state in a JSON file. It does not proxy model traffic and does not maintain a cloud service.

## 3. Native macOS UI

The SwiftUI/AppKit application renders one display-aware status surface per screen and one cursor-relative completion panel. It reads source-owned transcripts directly and incrementally, reconstructing conversation entries without embedding a live terminal.

iTerm2 navigation and prompt delivery use compiled AppleScript calls addressed to the exact recorded session UUID. A missing UUID is visible to the user; it must never silently focus an arbitrary pane.

## Data flow

```text
agent lifecycle event
        |
        v
hook/plugin -> noturcode-bridge -> Unix socket -> SessionStore
        |                                         |
        | source-owned JSONL                      v
        +-------------------------------> TranscriptReader
                                                  |
                                                  v
                               notch / alert / chat / workflow
                                                  |
                                    explicit user click or send
                                                  |
                                                  v
                                      exact iTerm2 session UUID
```

## Design invariants

- Never replace or close the user's terminal.
- Never guess success when a target cannot be resolved.
- Never overwrite unrelated hook configuration.
- Never require network access for status, transcripts, or navigation.
- Never expose state or IPC to other local users.
- Never describe detected compatibility as verified feature parity.
