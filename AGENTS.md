# AGENTS.md

## Planning

- Put docs and plans in `docs/` dir

## Imeplemtnation

- After writing code, make sure to build and run unit tests (see below), but dont' bother with UI tests


## Commit Attribution

- Codex-authored commits must use `git codex-commit` (local alias for distinct author attribution).
- Ensure local alias exists:
  - `git config --local alias.codex-commit 'commit --author="Codex <kelan+codex@kelan.io>"'`
- Codex-authored commits must include this trailer in the commit message:
  - `Agent: Codex`
- Example:
  - `git codex-commit -m "Implement X" -m "Agent: Codex"`


## Build/Test Commands

All commands assume macOS with Xcode installed. The project uses an `.xcodeproj` with a single scheme `TicketParty`.

- Open in Xcode

```bash
open TicketParty.xcodeproj
# or
xed .
```

- Build (Debug)

```bash
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -configuration Debug build
```

- Clean build artifacts

```bash
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty clean
```

- Run all tests (macOS)

```bash
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test
```

- Run only unit tests target

```bash
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' \
  test -only-testing:TicketPartyTests
```

- Run only UI tests target

```bash
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' \
  test -only-testing:TicketPartyUITests
```

- Run a single test (examples)

```bash
# UI test by class/method
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' \
  test -only-testing:TicketPartyUITests/TicketPartyUITests/testExample

# Swift Testing (unit) example — adjust identifiers to the struct/method in TicketPartyTests.swift
xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' \
  test -only-testing:TicketPartyTests/TicketPartyTests/example
```

- Notes on linting

SwiftLint and SwiftFormat are configured via `config/` with root symlinks.
Pre-commit hooks are managed by `prek` using `.pre-commit-config.yaml`.
