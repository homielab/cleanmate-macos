---
name: cleanmate
description: Free up disk space on this Mac with CleanMate (`cleanmate`). Use when the user asks to free up disk space, says the disk is full, or wants to clean caches, logs, the Trash, developer junk (Xcode, simulators, node_modules, Docker) or AI model files on macOS. Scans first, shows what it found by group, and cleans only what the user confirms.
---

# CleanMate for macOS

CleanMate is a Mac cleaner app. Its `cleanmate` command runs the app's Smart Scan without a window, with the same
safety rules: junk that apps rebuild is deleted, user files and apps go to the Trash, files in use and items of running
apps are skipped. This skill drives it with `--json`.

## Rules

1. Never install anything yourself. If `cleanmate` is missing, tell the user how to get CleanMate (see below) and stop.
2. Always scan first. Never run a clean you have not shown to the user.
3. Clean only after the user confirms in this conversation, and only the item ids you showed: `--only ID,ID…`.
4. Suggest only items with `"selectedByDefault": true`. Add an unticked item (AI models, `node_modules`, old Xcode
   versions, old downloads…) only when the user names it.
5. Never pass `--privacy` (browser history, cookies, recent items) unless the user asked for privacy cleaning.
6. Do not offer `locked` items: tell the user the `reason` (`"Google Chrome is running"`), to quit that app and rescan.
7. When unsure, run the same clean with `--dry-run` first. Never delete files by hand instead of using `cleanmate`.
8. After cleaning, report `freed`, what is in the Trash (`inTrash`: still on disk until the Trash is emptied) and every
   `skipped` path with its `reason`.

## Find it

```bash
command -v cleanmate || ls /Applications/CleanMate.app/Contents/Helpers/cleanmate
```

Use whichever exists; the second is the full path to run. Neither: the user downloads CleanMate from
https://github.com/homielab/cleanmate-macos/releases/latest (drag it to Applications) or, once the Homebrew tap is
published, runs `brew install --cask homielab/tap/cleanmate`. Then `cleanmate --help` shows everything.

## Scan

```bash
cleanmate scan --json                    # everything Smart Scan covers, no privacy
cleanmate scan --json --group dev,ai     # only some groups
cleanmate scan --json --only user-caches,xcode-derived-data
```

A scan reads the disk and can take a minute. `--json` prints one JSON object on stdout when done; read stdout only
(stderr carries errors, and a "Scanning…" line on a terminal). Groups: `system`, `user` (the Trash), `dev`, `ai`, `apps`,
`privacy`. `cleanmate list --json` lists every item with its description without scanning.

Each item has `id`, `group`, `name`, `size` (bytes), `sizeIsUpperBound` (the size is a maximum), `selectedByDefault`,
`disposal` (`"delete"`: removed for good, apps rebuild it; `"trash"`: moved to the Trash, the user can put it back),
`locked` + `reason`, and its largest `entries` (`path`, `size`). `total` is what the ticked, unlocked items hold.

Show the user the items with `size` > 0 (or `records`), grouped by `group`, sizes human readable (1 GB = 10⁹ bytes, as
Finder counts), marking what goes to the Trash and what is locked and why. Suggest the ticked ones and give the total.

`"fullDiskAccess": false` means folders macOS protects (Desktop, Documents, Downloads, the Trash, Mail…) were skipped.
Full Disk Access belongs to the app running `cleanmate` (Terminal, iTerm, your agent's app), not to CleanMate: System
Settings › Privacy & Security › Full Disk Access, turn that app on, quit and reopen it. Mention it once; the scan is
still useful without it.

## Clean

```bash
cleanmate clean --dry-run --json --only user-caches,xcode-derived-data   # preview, deletes nothing
cleanmate clean --yes --json --only user-caches,xcode-derived-data       # after the user confirmed
```

Always pass `--only` with the confirmed ids. Without a terminal, `clean` needs `--yes`: without it nothing is deleted
and the exit code is 4. `clean` scans again before cleaning, so sizes can differ a little from the scan.

The result has `freed`, `inTrash`, `upTo` (part of `freed` that may stay shared on disk) and, per item, `freed`,
`trashed`, `skipped` (`path` + `reason`: in use, changed since the scan…), `locked` + `reason`. `log` is the activity
log (`~/Library/Logs/CleanMate/activity.log`), also shown in the app's Settings › Activity.

There is no Undo in the command: items moved to the Trash can be put back from the Trash in Finder (Put Back).

Exit codes: 0 OK (also when something was skipped), 1 error, 2 bad arguments (stderr says why), 3 no Full Disk Access
with `--require-fda`, 4 `clean` without `--yes` and without a terminal.

## Beyond Smart Scan

Large & old files, uninstalling apps, Space Lens, login items and maintenance tasks are in the app: `open -a CleanMate`.
Point the user there.

More: [reference.md](reference.md).
