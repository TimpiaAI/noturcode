# Contributing to Noturcode

Thanks for helping make coding-agent sessions easier to follow and control on macOS.

## Before you start

- Search existing issues before opening a new one.
- Use a feature request for product ideas and a bug report for reproducible failures.
- For a security vulnerability, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
- Keep changes focused. Separate unrelated fixes into separate pull requests.

## Development requirements

- macOS 15 or newer
- Xcode with the macOS SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.44 or newer

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

## Build and test

Generate the Xcode project from the checked-in specification:

```sh
xcodegen generate
```

Build without requiring a local signing identity:

```sh
xcodebuild \
  -project Noturcode.xcodeproj \
  -scheme Noturcode \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the deterministic Core and Integration suites:

```sh
xcodebuild \
  -project Noturcode.xcodeproj \
  -scheme Noturcode \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:NoturcodeCoreTests \
  -only-testing:NoturcodeIntegrationTests \
  test
```

UI tests manipulate macOS windows and Accessibility state. Run them deliberately on a test account, not alongside valuable terminal sessions:

```sh
xcodebuild \
  -project Noturcode.xcodeproj \
  -scheme Noturcode \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:NoturcodeUITests \
  test
```

## Change guidelines

- Treat `project.yml` as the source of truth for the generated Xcode project.
- Preserve existing Claude Code, Codex, Gemini CLI, terminal, and editor configuration when installing integrations.
- Keep bridges fail-open: an unavailable Noturcode app must not block an agent session.
- Never commit transcripts, prompts, tokens, credentials, signing material, diagnostic exports, or user-specific paths.
- Keep session processing local unless a feature clearly documents and requires network access.
- Add or update tests for behavioral changes.
- Update `CHANGELOG.md` under `Unreleased` for user-visible changes.

## Pull requests

A pull request should explain the user problem, the chosen approach, and how it was verified. Include screenshots or a short recording for visible UI changes. Document any new permission, hook, process, file, socket, or network behavior.

By contributing, you agree that your contribution is licensed under the repository's [MIT License](LICENSE).
