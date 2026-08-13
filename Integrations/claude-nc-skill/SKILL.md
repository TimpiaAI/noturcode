---
name: nc
description: Connect or disconnect the current Claude Code session from the Noturcode macOS notch tracker.
argument-hint: "<session name|stop>"
disable-model-invocation: true
allowed-tools: []
---

The `UserPromptExpansion` lifecycle hook handles this command deterministically before model invocation.

- `/nc <any name>` connects this exact session to Noturcode.
- `/nc stop` disconnects this exact session immediately.
