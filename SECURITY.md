# Security policy

Noturcode integrates with local coding agents, terminal applications, session transcripts, Unix sockets, and macOS Automation and Accessibility APIs. Security reports are taken seriously.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Earlier releases | No |
| Unreleased development branch | Best effort |

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use GitHub's private vulnerability reporting for this repository:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Include affected versions, impact, reproduction steps, and a minimal proof of concept when safe.

If private vulnerability reporting is temporarily unavailable, contact the repository owner privately through their GitHub profile and ask for a secure reporting channel. Do not send secrets or exploit details in a public discussion.

You can expect an acknowledgement within 5 business days. We will coordinate validation, remediation, release timing, and disclosure with the reporter.

## Sensitive data

Reports and diagnostic attachments may contain source code, prompts, transcripts, paths, usernames, terminal output, or credentials. Redact anything not required to reproduce the issue. Never include API keys, access tokens, cookies, signing certificates, private keys, or full private transcripts.

## Security expectations

Changes should preserve these boundaries:

- Local event endpoints must validate the sender and message shape.
- Hook installers must preserve unrelated user configuration and fail open.
- Terminal navigation or prompt submission must target the intended session.
- Update and distribution artifacts must be signed and verified.
- Logs must avoid secrets and private transcript content by default.
- Network communication must be explicit and documented.
