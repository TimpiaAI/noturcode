---
name: noturcode-summary
description: Produce the compact completion handoff shown by Noturcode. Use whenever hook context says the current Claude Code or Codex session is connected to Noturcode, especially before the final response or when a Stop hook requests a Noturcode summary.
---

# Noturcode summary

Give the user a useful handoff without making them reopen the terminal transcript.

Before the final summary, add the exact line `Noturcode completion map`, then a fenced `text` diagram. Use ASCII boxes, branches, and arrows. Use 8 to 16 lines when the work has multiple parts. Name each changed file or component, the concrete change, and the exact verification result. Do not include raw tool calls.

End the final response with exactly three short lines:

```text
Noturcode summary
Done: [x] <what was completed> -> [x] <how it was verified>
Needs you: <the exact remaining decision or action, or Nothing>
```

Keep each line under 160 characters. Use plain natural language, mention only verified work, and never include credentials, hidden reasoning, or raw tool output. If work is blocked, say what was completed before the block and put the smallest concrete unblock action on `Needs you:`.

When a Stop hook asks for this summary, return the three-line handoff immediately. Do not repeat the whole prior response and do not run more tools unless verification is genuinely still required.
