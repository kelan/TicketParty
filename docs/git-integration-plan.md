# Git Integration V1 Plan: Multi-Workspace Status + Per-File Diffs (Supervisor-Owned)

## Summary
Implement git reporting as a new supervisor RPC (not via Codex sidecar tasks, and not app-direct `Process` for v1).
The app will request git data for a project's `workingDirectory` only when the user manually refreshes from that project's detail screen.
Each response includes repo status, changed-file list, and per-file diffs covering staged, unstaged, and untracked changes.

## Decisions Locked
1. Execution model: `codex-supervisor` owns git command execution.
2. Scope: first-party app-managed project directories (`Project.workingDirectory` values), not nested dependency repos.
3. UI surface: project detail screen only for v1.
4. Refresh: manual refresh only (no polling).
5. Diff content: include per-file diff text in v1.
6. Change buckets: staged + unstaged + untracked.
7. Supervisor unavailable behavior: show per-project error, no fallback path in v1.

## Public API and Interface Changes
1. Add new supervisor request/response contract in `TicketPartyPackage/Sources/codex-supervisor/main.swift`.
2. New request type: `gitSnapshot`.
3. Request fields: `projectID` (UUID string), `workingDirectory` (string).
4. Success response type: `gitSnapshot.ok`.
5. Success payload fields:
   - `projectID`
   - `workingDirectory`
   - `repositoryRoot`
   - `branch`
   - `isDirty`
   - `generatedAtEpochMS`
   - `files` (array of changed-file objects)
   - `truncated` (bool, project-level cap indicator)
6. Changed-file object fields:
   - `path`
   - `stagedStatus` (single-char status or empty)
   - `unstagedStatus` (single-char status or empty)
   - `isUntracked` (bool)
   - `stagedDiff`
   - `unstagedDiff`
   - `untrackedDiff`
   - `isBinary` (bool)
   - `truncated` (bool, file-level cap indicator)
7. Error response remains existing `type: "error"` with message text for invalid dir/not repo/supervisor failures.

## App-Side Type and Method Additions
1. In `TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`, add:
   - Encodable request struct for `gitSnapshot`.
   - Decoding/parsing logic for `gitSnapshot.ok`.
   - Public async method: `fetchGitSnapshot(projectID: UUID, workingDirectory: String?) async throws -> GitProjectSnapshot`.
2. Add new git snapshot models in `TicketPartyPackage/Sources/TicketPartyUI/Support/GitProjectSnapshot.swift`:
   - `GitProjectSnapshot`
   - `GitChangedFileSnapshot`
   - Optional helper enums for status code interpretation.
3. In `CodexViewModel` (same file as above), add state:
   - `gitSnapshots: [UUID: GitProjectSnapshot]`
   - `gitErrors: [UUID: String]`
   - `gitRefreshing: Set<UUID>`
4. In `CodexViewModel`, add method:
   - `refreshGitSnapshot(for project: Project) async`
   - Validates `workingDirectory`, sets loading state, calls manager, stores snapshot/error.

## Supervisor Implementation Details
1. In `TicketPartyPackage/Sources/codex-supervisor/main.swift`, extend `handleRequest` switch with `gitSnapshot`.
2. Implement `handleGitSnapshot(request:fd:)` with:
   - UUID validation.
   - `workingDirectory` normalization and existence validation (reuse existing path resolver style).
   - Repo validation: `git rev-parse --is-inside-work-tree`.
   - Repo root + branch:
     - `git rev-parse --show-toplevel`
     - `git rev-parse --abbrev-ref HEAD`
   - File detection: `git status --porcelain=v1 -z --untracked-files=all`.
   - Parse `-z` entries to robustly handle spaces/renames.
3. Per changed file, collect diffs:
   - Staged diff: `git diff --cached -- <path>`
   - Unstaged diff: `git diff -- <path>`
   - Untracked diff: `git diff --no-index -- /dev/null <path>` (when `??`).
4. Apply deterministic truncation caps:
   - Max changed files per project: `200`
   - Max diff bytes per file (sum of staged/unstaged/untracked): `120_000`
   - Max total diff bytes per project: `1_500_000`
5. Mark truncation flags per file and project if caps are hit.
6. Preserve binary indicators from git output and set `isBinary = true` where detected.

## UI Changes (Project Detail Screen)
1. In `TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift`, add a `Git` section to the right-hand panel so it is visible within project detail.
2. Include:
   - `Refresh Git` button (manual trigger).
   - Loading indicator while `gitRefreshing` contains project.
   - Error text from `gitErrors[project.id]` when present.
   - Summary line: clean/dirty, file count, branch, repo root (truncated display).
   - Changed-file list.
   - Per-file disclosure showing staged/unstaged/untracked diff blocks in monospaced text.
3. If no changes, show clear "Working tree clean" state.
4. If no working directory, show explicit "No working directory configured" message.

## Files to Change
1. `TicketPartyPackage/Sources/codex-supervisor/main.swift`
2. `TicketPartyPackage/Sources/TicketPartyUI/Support/CodexManager.swift`
3. `TicketPartyPackage/Sources/TicketPartyUI/Support/GitProjectSnapshot.swift` (new)
4. `TicketPartyPackage/Sources/TicketPartyUI/Screens/ProjectScreen.swift`
5. `TicketPartyPackage/TicketPartyTests/TicketPartyTests.swift`
6. `docs/git-integration-plan.md` (this implementation spec)

## Test Cases and Scenarios
1. Supervisor request validation:
   - Missing/invalid `projectID`.
   - Missing/invalid `workingDirectory`.
   - Non-git directory.
2. Snapshot correctness:
   - Clean repo returns `isDirty = false`, empty files.
   - Mixed staged + unstaged changes on same file.
   - Untracked file diff generation.
   - Renamed file handling from porcelain parser.
   - Binary file diff handling.
3. Truncation behavior:
   - File-level cap sets file `truncated = true`.
   - Project-level cap sets response `truncated = true`.
4. App manager parsing:
   - `gitSnapshot.ok` parses into `GitProjectSnapshot`.
   - Error response maps to user-facing error string.
5. ViewModel behavior:
   - Refresh sets/clears loading state correctly.
   - Success updates snapshot and clears prior error.
   - Failure sets per-project error without crashing UI.
6. UI rendering:
   - No working directory state.
   - Clean state.
   - Dirty state with multiple files and diff disclosures.
   - Error state when supervisor is down/unreachable.

## Build and Unit-Test Validation (Post-Implementation)
1. `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -configuration Debug build`
2. `xcodebuild -project TicketParty.xcodeproj -scheme TicketParty -destination 'platform=macOS' test -only-testing:TicketPartyTests`

## Assumptions and Defaults
1. `Project.workingDirectory` is the canonical directory for git inspection.
2. One repo per project working directory for v1.
3. Manual refresh is sufficient for initial UX.
4. No app-local git fallback when supervisor is unavailable.
5. No UI tests required for this change set in v1.
6. Diff caps above are fixed constants in v1, not user-configurable.
