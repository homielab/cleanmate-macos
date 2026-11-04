---
name: cleanmate
description: Free up disk space on this Mac with CleanMate (`cleanmate`). Use when the user asks to free up disk space, says the disk is full, asks what takes up space, which files are large or duplicated or which photos look alike, or wants to clean caches, logs, the Trash, developer junk (Xcode, simulators, node_modules, Docker) or AI model files on macOS, or to uninstall an app, remove its leftovers, erase browsing traces or remove a login item. Scans first, shows what it found by group, and cleans or moves to the Trash only what the user confirms.
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
5. Items with `"dataLoss": true` (Docker volumes, stopped Docker containers) are deleted for good with whatever is
   inside: databases, files written in a container. Never suggest them and never add them to a clean on your own,
   even when `selectedByDefault` is true (the user ticked them in the app). Clean one only when the user names that
   item after seeing its volumes or containers (`entries`), with its id in `--only`: that removes all of them except
   entries with a `reason`. If the user wants to keep some, send them to the app (Smart Scan › Developer Junk) to tick
   only the ones to remove. A clean without `--only` never takes them: it reports them `locked` with a `reason`.
6. Never pass `--privacy` (browser history, cookies, recent items) unless the user asked for privacy cleaning.
7. Do not offer `locked` items: tell the user the `reason` (`"Google Chrome is running"`), to quit that app and rescan.
8. When unsure, run the same clean with `--dry-run` first. Never delete files by hand instead of using `cleanmate`.
   Move a file `space`, `large`, `dupes` or `similar` found to the Trash only with `cleanmate trash --yes PATH…`, only the exact paths
   the user confirmed (see "Move to the Trash").
9. After cleaning, report `freed`, what is in the Trash (`inTrash`: still on disk until the Trash is emptied) and every
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
`dataLoss` (may hold the user's data, see rule 5), `locked` + `reason`, and its largest `entries` (`path`, `size`,
`name` when the path is not a file: a Docker volume's name). `total` is what the ticked, unlocked items hold.

Show the user the items with `size` > 0 (or `records`), grouped by `group`, sizes human readable (1 GB = 10⁹ bytes, as
Finder counts), marking what goes to the Trash, what may hold data and what is locked and why. Suggest the ticked ones
without `dataLoss` and give their total.

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
`trashed`, `skipped` (`path` + `reason`: in use, changed since the scan…), `dataLoss`, `locked` + `reason`. `log` is the activity
log (`~/Library/Logs/CleanMate/activity.log`), also shown in the app's Settings › Activity.

Deleted junk can't be put back. Items `clean` moved to the Trash can, with `restore` (see "Put back what
CleanMate moved").

Exit codes: 0 OK (also when something was skipped), 1 error, 2 bad arguments (stderr says why), 3 no Full Disk Access
with `--require-fda`, 4 a command that changes something (`clean`, `trash`, `uninstall APP`, `privacy --erase`,
`login-items remove`) without `--yes` and without a terminal, 5 `uninstall`: the app is open.
On failure stderr says why and `--json` prints `"error": {"code", "message"}`: `fullDiskAccess` (exit 3: ask the
user to grant it), `path` (2), `permission`, `cancelled`, `failed` (1). All output is in English, whatever the app's
language.

## What takes space

When the user asks what fills the disk, which files are big, which are duplicates or which photos look alike, measure
with these instead of `du` or `find`: they follow the app's rules (exclusions, hard links counted once, protected
folders never opened without Full Disk Access). All four are read-only.

```bash
cleanmate space --json                       # the home folder's children by size, like Space Lens
cleanmate space ~/Library --json --limit 10  # drill into the biggest folder
cleanmate large --json                       # files of 50 MB or more in the home folder, like Large & Old Files
cleanmate large --json --min-size 1GB --older-than 180 --in ~/Downloads
cleanmate dupes --json                       # duplicate files of 1 MB or more, like Duplicate Files
cleanmate dupes --json --in ~/Pictures --min-size 100KB --limit 10
cleanmate similar --json ~/Pictures ~/Desktop # photos that look alike, like Similar Photos (default: the home folder)
```

`space` lists `items` biggest first (`size` in bytes, `kind` `folder` or `file`), then `moreItems` / `moreSize` for
the rest beyond `--limit` (20). Start at the home folder and run `space` again on the biggest folder or two until the
answer is clear (a project's `node_modules`, a video folder). `large` lists `files` biggest first with `kind` (video,
audio, image, document, code, archive, diskImage, installer, other), `modified`, `lastUsed` (Spotlight; may be null) and `hardLinked` (moving it to
the Trash frees nothing while other links remain), and `icloud` on iCloud Drive files (`uploaded`: Remove Download in
Large & Old Files frees it and keeps it in iCloud; never `trash` a file inside iCloud Drive); `--older-than DAYS`
keeps files not used for that long, `--in` a folder (then `--min-size` can go down to 1 MB). `dupes` takes the same
`--in` and `--min-size` (default 1 MB, at least 100KB) and lists `groups` of identical files, most `wasted` bytes first (what moving every copy but
the oldest would free); each group has the copies' `size`, `count` and `files` (`path`, `modified`, `freeable`,
`oldest` first). A copy with `freeable` 0 is an APFS clone or has other hard links: removing it frees nothing. Show
sizes human readable and paths with `~`.

`similar` compares photos of 20 KB or more on this Mac (Vision; nothing leaves the Mac) in the folders named, like
Similar Photos: the same shot resized, recompressed or converted, burst shots that barely differ. It never reads a
Photos library or an app. It lists `groups`, most `freeable` bytes first; each has `count` and `photos` (`path`,
`size`, `width`, `height`, `modified`, `suggested`). The `suggested` photo (most pixels, then largest, then newest) is
the one to keep; `freeable` is what moving the others frees. Unlike `dupes` the photos are not identical: show the
user the group and let them choose. `photos` is how many were compared; the first run on many photos takes a while.

All four report `skipped` folders (no Full Disk Access): say they were not measured. A path inside one exits with code 3,
a path that does not exist or is not a folder with code 2.

None of them deletes anything. If it is junk Smart Scan covers (DerivedData, caches, `node_modules`), scan and clean
that item instead.

## Move to the Trash

To remove files or folders that `space`, `large`, `dupes` or `similar` found, move them to the Trash with `cleanmate trash PATH…`.
Never delete or move these files yourself, by hand or with `rm`, `mv` or Finder scripting.

1. Show the user the exact paths and sizes you propose (for duplicates: every copy but the one they keep, by default
   the `oldest`; for similar photos: the others of a group, keeping the `suggested` one unless the user picks another,
   and only after the user looked at that group). Never pick files on your own beyond what you showed.
2. Run `trash` only after the user confirmed in this conversation, and only with the exact paths they confirmed, one
   argument each, quoted. No wildcards, no parent folder instead of the files.
3. Say the items are in the Trash and can be put back with `cleanmate restore TRASHED…`, until the Trash is emptied.

```bash
cleanmate trash --yes --json "/Users/me/Downloads/trip copy.mov" /Users/me/Movies/old-render.mov
cleanmate restore --json "/Users/me/.Trash/trip copy.mov"   # put one back, by the trashed path trash printed
```

Each path must be in the home folder and not in `~/Library`, not hidden (`~/.ssh`), not inside an app or package, not
a top-level home folder itself (`~/Documents`), not excluded in Settings › Exclusions and not a symlink. Anything else
is not moved: its item has `"skipped": true` and a `reason`; tell the user. A path in a folder macOS protects needs
Full Disk Access. The result lists, per path, `path`, `size`, `kind`, `trashed` (where it is now in the Trash: keep it
for `restore`), `skipped` and `reason`; `count` and `size` (bytes) cover what moved. Without a terminal `trash` needs
`--yes`: without it nothing moves and the exit code is 4.

`restore` takes the `trashed` paths (from `trash`, or `restore --list` for earlier moves, also the app's) and puts each
item back at its old place. It never overwrites: an item whose place
is taken again, or whose folder was moved or replaced by a symlink, is `skipped` with a `reason`. Both commands write
the activity log.

## Put back what CleanMate moved

When the user wants back something CleanMate removed (today, yesterday, "the file it moved"), whether the app or
`cleanmate` moved it:

1. Run `cleanmate restore --list --json`: what CleanMate moved to the Trash and is still there, newest first, with
   `date`, `path` (where it was), `size`, `source` (`Smart Scan`, `Large & Old Files`, `Space Lens`, `Uninstaller`,
   `Command Line`) and `trashed`.
2. Show the matching items (date, old path, size, source) and let the user pick. Don't put back anything they didn't
   pick.
3. Run `cleanmate restore --json TRASHED…` with the `trashed` path of each picked item, quoted. Report what was put
   back and each `reason` for what was skipped (something is at the old place now, its folder changed, emptied).

```bash
cleanmate restore --list --json              # what can be put back, newest first
cleanmate restore --list --limit 20 --json   # only the 20 newest
cleanmate restore --json "/Users/me/.Trash/old-app"
```

An empty list means nothing CleanMate moved is still in the Trash. Junk Smart Scan deleted (caches, logs, developer
junk) is never listed: it can't come back, and the apps rebuild it. Items the user moved to the Trash themselves are
put back in Finder (Put Back).

## Uninstall an app

1. Run `cleanmate uninstall --json`: each app with `name`, `bundleId`, `source` (`appStore`, `homebrew`, `setapp`,
   `downloaded`), `size` (the app), `dataSize` (its data in `~/Library`), `lastUsed` and `running`; then `leftovers`,
   data of apps already removed. Read-only.
2. Show the app the user named, its size and data size. Before moving anything, show what goes with
   `cleanmate uninstall --dry-run --json APP` (`items`: the app and each data folder, `notRemoved`: folders that only
   look like its name, never taken).
3. After the user confirmed, run it with `--yes`. APP is the `bundleId` (safest), the name or the `.app` path.

```bash
cleanmate uninstall --json                                   # apps and leftovers, read-only
cleanmate uninstall --dry-run --json com.example.App         # what would go
cleanmate uninstall --yes --json com.example.App             # app + its data to the Trash
cleanmate uninstall --leftovers-only --yes --json com.example.App   # keep the app, reset its data
cleanmate uninstall --leftovers --yes --json /Users/me/Library/Caches/com.old.Tool   # a leftover listed above
```

- An open app is never touched: exit code 5. Ask the user to quit it, or with their OK add `--quit` (the app may ask
  to save first). Never kill it yourself.
- An App Store app macOS only lets the user remove, or an app owned by another user, is left with exit code 1 and the
  reason: tell the user to remove it in Finder or Launchpad. `cleanmate` never asks for a password; never use `sudo`.
- Everything goes to the Trash: each `trashed` path works with `cleanmate restore --json TRASHED…`.
- `--leftovers PATH…` takes only paths `cleanmate uninstall --leftovers --json` lists; anything else is `skipped`.

## Erase privacy traces

Only when the user asks to erase browsing history, cookies, recent items or shell history (rule 6).

1. Run `cleanmate privacy --json`: items with `id`, `browser`, `name`, `size`, `records`, `signsOut` and `skipped`
   with a `reason` (`"Safari is running"`).
2. Show them; say that items with `"signsOut": true` (cookies) sign the user out of websites. Say a `skipped` item
   needs its browser quit first.
3. After the user confirmed, erase only the ids they picked:

```bash
cleanmate privacy --json
cleanmate privacy --erase --yes --json safari-history chrome-history
```

Erased traces are deleted, not moved to the Trash: they can't be put back. The result is the `clean` report: report
`freed` and every `locked` item with its `reason`.

## Login items

```bash
cleanmate login-items --json                                  # label, scope, state, program, removable
cleanmate login-items remove --yes --json com.example.agent   # to the Trash, stopped
cleanmate login-items restore --json com.example.agent        # put back and loaded again
```

Only items with `"removable": true` (the user's own, in `~/Library/LaunchAgents`) can be removed; the system's
(`system-agent`, `system-daemon`) need an administrator: point the user to System Settings › General › Login Items.
An item with `"programMissing": true` belongs to an app that was removed: a good one to suggest. Remove only the
labels the user confirmed.

## When not to use it

Maintenance tasks (flush DNS, reindex Spotlight) and anything needing an administrator are in the app:
`open -a CleanMate`. Never use `rm`, `sudo`, `launchctl` or `osascript` instead of `cleanmate`.

More: [reference.md](reference.md).
