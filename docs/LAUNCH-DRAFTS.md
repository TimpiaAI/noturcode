# Community launch drafts

These drafts are intentionally community-specific. The maintainer should answer questions in each thread before posting elsewhere and update any capability claim that has changed since release.

## r/ClaudeCode

**Title:** I open-sourced the macOS session manager I use when Claude Code agents multiply

I built Noturcode because status alone did not solve my actual problem: I still lost the parent or subagent that needed me, or returned to the wrong iTerm2 split.

Noturcode is a native, local-first macOS companion. It shows active sessions in the notch, returns to the captured iTerm2 pane, and reconstructs the local conversation with tool batches, files, token totals, and separate Claude subagent threads. It does not replace the terminal, upload transcripts, or require an account.

The code is MIT licensed: https://github.com/TimpiaAI/noturcode

Current honest boundary: Claude Code and Codex on local iTerm2 panes are the core; SSH, tmux, and exact navigation in other terminals are roadmap work. I would particularly value reports from people running five or more concurrent sessions: what information must be visible before you trust a one-click return?

## r/codex

**Title:** Open-source macOS mission control for Codex CLI sessions

I wanted one place to see which Codex session is working, finished, or waiting, then return to the exact pane without replacing the CLI. I open-sourced the result as Noturcode.

It reads the local Codex JSONL to render the real conversation, tool batches, files, models, and token totals; messages are submitted back to the captured iTerm2 pane. Everything Noturcode stores stays on the Mac.

Source and capability matrix: https://github.com/TimpiaAI/noturcode

Codex has different event and slash-command behavior from Claude Code, so the README documents the differences instead of calling both integrations identical. What Codex state or event is still missing from the UI you use today?

## r/macapps

**Title:** Noturcode: an open-source native Mac companion for coding-agent sessions

Noturcode is a native Swift app for people running multiple Claude Code or Codex sessions in iTerm2. The compact notch surface shows live state; the desktop workspace opens the local chat, tools, files, and subagents; clicking a session returns to its captured pane.

There is no account, telemetry service, or hosted transcript database. Integration setup is explicit, existing configuration is backed up, and uninstall removes only Noturcode-owned entries.

MIT source: https://github.com/TimpiaAI/noturcode

It is early software and currently source-install only while the signed/notarized release pipeline is prepared. Feedback on multi-display behavior and native accessibility is especially useful.

## Launch checklist

- Use a tagged commit with green Core and Integration CI.
- Replace mockups with sanitized real captures when a clean demo account is ready.
- Publish one community at a time and disclose maintainer affiliation.
- Answer installation and privacy questions before posting to another community.
- Record issue links for every reproducible failure; do not debate reports in comments.
