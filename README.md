# BranchLens

A small macOS SwiftUI app for inspecting **one branch** of a local git repository.

Open a repo (or several tabs), pick a branch, and review:

- **Commits unique to that branch** since it diverged from a base (`merge-base..branch`)
- **All file changes as one commit** (or per-commit) with Diff / Before / After / Compare
- **Syntax-highlighted** code and color-coded `+` / `−` diffs
- **Folder or flat** changed-file lists, search, resizable columns, and session restore

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode or Command Line Tools with a full SDK)
- Local `git` at `/usr/bin/git`

## Run

```bash
# If xcode-select points at Command Line Tools only:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift run BranchLens
```

## Build a .app

```bash
scripts/make-app.sh          # optional version: scripts/make-app.sh 0.4.1
open dist/BranchLens.app
```

The script produces an ad-hoc signed app in `dist/` (not notarized). On first launch you may need right-click → **Open**.

## How “since the branch was created” works

Git does not store a branch creation time. BranchLens uses the usual equivalent:

1. Detect a **base** branch (`origin/HEAD` → `main` → `master` → `develop`), or let you pick one
2. `git merge-base <base> <branch>`
3. Commits: `git log <merge-base>..<branch>`
4. Files: `git diff <merge-base>...<branch>` (triple-dot = changes introduced on the branch)

## Tests

```bash
swift test
```

## Privacy

BranchLens runs entirely on your machine. It shells out to local `git` and never sends repository contents to a network service. UI state (open tabs, branch selections, column layout) is stored in `UserDefaults` on your Mac.

## License

[MIT](LICENSE)
