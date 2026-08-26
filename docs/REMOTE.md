# Remote VPS setup

Noturcode keeps the interface on the Mac. A VPS receives only a small Python helper.

## Start

Install or repair Noturcode integrations on the Mac. Open a new shell, or load the command in the current shell:

```sh
source ~/.config/noturcode/shell.zsh
nc
```

The interactive command gives five choices:

```text
1. Pair a VPS
2. Open an SSH workspace
3. Resume an existing Codex chat
4. Check setup
5. Exit
```

### Pair once

Choose `Pair a VPS`, then enter a host or alias from `~/.ssh/config`.

Noturcode performs these steps:

1. Copies `noturcode-agent` to `~/.local/bin/noturcode-agent` over SSH.
2. Creates a six-digit code on the Mac. It expires after ten minutes and works once.
3. Opens a temporary SSH Unix-socket reverse forward.
4. Exchanges the code for a durable random token.
5. Stores the token as mode `0600` on the VPS.
6. Stores only the token SHA-256 hash on the Mac.
7. Backs up and merges detected Claude Code, Codex, and Gemini hook files.

No root command runs. No existing hook group is overwritten.

### Work through the paired shell

Run `nc` again and choose `Open an SSH workspace`.

The command opens a normal interactive SSH shell. It also creates a unique Unix-socket forward for that shell and exports the exact local terminal identity. Start Claude, Codex, or Gemini inside it. Use `/nc NAME` inside the coding agent as usual.

### Connect an SSH pane that is already open

Right-click inside the iTerm2 pane. Choose **Connect Session to Noturcode**.
Noturcode uses OpenSSH's live forwarding command on that same connection. It does
not start a second SSH login. You do not run `nc ssh` or a connect command.

The remote helper and hooks are a one-time server install. After that install, the
right-click action can attach each new SSH pane. The one-time pair token is created
through the live tunnel when required.

Noturcode enables `EnableEscapeCommandline yes` in a small included SSH config.
This setting applies when OpenSSH starts. Reconnect panes that were already open
when Noturcode added the setting. Use the action when the agent input is empty.

### Paste a Mac image into remote Codex or Claude Code

Copy an image on the Mac. Focus the agent input in the iTerm2 SSH workspace. Press `Command-V`.
Noturcode writes a private PNG, copies it to `~/.cache/noturcode/attachments/` on the VPS, and
pastes the remote path as an image attachment. It does not press Enter. Write the prompt, then
submit it yourself. Text paste stays native and unchanged.

The `nc ssh` path reuses its OpenSSH control connection. The right-click path uses a
remote image relay through the live Unix-socket forward. Key, SSH-agent, and
password-authenticated SSH panes do not need a second login.
Images are limited to 20 MB. The remote directory uses mode `0700`; each image uses mode `0600`.
Noturcode stops an upload after 30 seconds. It refuses stale or non-Noturcode SSH control sockets.

When the SSH connection closes, the socket forward closes. The remote hook then returns `{}` and exits successfully, so the coding agent continues.

## Direct forms

The interactive menu is the default. These forms are also available:

```sh
nc pair my-vps
nc ssh my-vps
nc doctor
```

Any other `nc` arguments continue to use macOS netcat at `/usr/bin/nc`.

## Requirements

Mac:

- Noturcode.app
- OpenSSH
- zsh

VPS:

- Linux or macOS
- OpenSSH server
- Python 3.9 or newer
- the same SSH account that runs the coding harness

## Current boundary

The paired transport carries lifecycle and tool hook payloads. It does not copy a
full remote JSONL transcript yet. Exact return uses the iTerm2 pane ID captured by
`nc ssh` or by **Connect Session to Noturcode**.
