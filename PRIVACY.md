# Privacy

Noturcode is designed as a local companion. It has no account system, telemetry SDK, analytics endpoint, advertising service, or hosted transcript database.

## Data read locally

When a session is explicitly connected, Noturcode may read:

- hook events sent by that Claude Code, Codex, Gemini, or OpenCode process;
- the connected session's local Claude Code or Codex JSONL transcript;
- local file paths referenced in that transcript when you open a preview;
- iTerm2's public session metadata for exact pane navigation;
- selected terminal text only after you invoke **Ask Noturcode**.

## Data stored locally

Noturcode stores disposable metadata under `~/Library/Application Support/Noturcode/`, including connected-session state, token checkpoints, configuration backups, and diagnostic logs. Sensitive state files and the local Unix socket are created for the current user only.

Noturcode does not copy complete transcripts into its own database. Claude Code and Codex remain the owners of their original JSONL files.

## Network behavior

The core app and bridge do not send session data to a Noturcode server. There is no Noturcode server.

**Ask Noturcode is an explicit exception:** after you select terminal text, open the context command, type a question, and press Ask, Noturcode runs your locally installed Claude CLI. That CLI may send the selected excerpt and question to Anthropic according to your Claude configuration and Anthropic's terms. The UI identifies Claude as the destination before submission. Nothing is submitted merely by opening the popup.

## User control

- Connecting and disconnecting a session affects only Noturcode tracking.
- Integration setup is explicit and creates backups before changing supported configuration.
- The uninstall script can preview and remove Noturcode-owned integration entries.
- Local metadata is retained by default so uninstalling integrations cannot accidentally erase user history. It can be removed with an explicit data-deletion option.

Security reports belong in the private channel described in [SECURITY.md](SECURITY.md), not in a public issue containing transcripts or paths.
