# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Overview**: **Space outside your folders** explains space no folder shows: how many Time Machine local snapshots the Mac keeps and from when (macOS deletes them when it needs the space; the row says how to delete them now), purgeable space macOS frees on demand, and how much macOS, apps and other users take outside your home folder. Read-only, no password.
- **Apps**: **Adobe media cache** lists the media cache Premiere Pro, After Effects, Media Encoder and Audition keep in `~/Library/Application Support/Adobe/Common` (often tens of GB); it isn't ticked, because Premiere rebuilds it when a project is opened (that first open is slower), and it is locked while one of these apps runs. A cache folder moved in Premiere's settings is not scanned.
- **Overview**: **System protection** shows whether Gatekeeper, the firewall, System Integrity Protection and FileVault are on, and which XProtect version is installed and when; when one is off, a sentence says what that means and a button opens the right System Settings pane. Read-only: CleanMate changes none of these settings and needs no password.
- **Smart Scan**: **Old downloads** lists the files and folders in Downloads you haven't modified, added or opened for 90 days (a folder only when nothing inside was touched either), one by one with the date it was last touched; none are ticked, they go to the Trash so Undo can put them back, and installers stay under **Old installers** (needs Full Disk Access). Set the age in **Settings › General** (7 to 365 days).
- **Developer Junk**: **conda package archives** (downloaded `.tar.bz2`/`.conda` files and the index cache in conda's `pkgs` folders) and the **Dart and Flutter pub cache** (`~/.pub-cache` downloads) are listed; neither is ticked, and both are locked while conda/mamba or dart/flutter runs.
- **Overview**: **Free space over time** charts the startup disk's free space over the last 30 days, recorded once a day when CleanMate starts and after Smart Scan scans or cleans; hover a day to see its free space, and a sentence says whether the disk is filling up (and when it would be full at that rate), freeing up or stable.
- **Apps**: **Code editors: data of deleted projects** lists what VS Code, Cursor, Windsurf and VSCodium keep for project folders you have since deleted, one by one with the project name, editor and size; none are ticked, they go to the Trash so Undo can put them back, and the row is locked while one of these editors runs.
- **Overview**: CleanMate now opens on an overview of free space on each drive (orange past 90 % used), what it freed in the last 30 days and in total, and the 12 largest folders in your home; click a folder to open it in Space Lens. ⌘1 shows it, the other modules moved to ⌘2–⌘7.
- **Developer Junk › Firebase CLI**: emulators and debug logs moved with `FIREBASE_EMULATORS_PATH` or `FIREBASE_DEBUG_PATH` in your shell profile are listed too.
- **Settings › General**: set how long installers stay in Downloads before **Old installers** lists them (default 30 days, was the 7-day log age).
- **Developer Junk**: **Stale build folders** lists Cargo `target`, Python `.venv`/`venv` and CocoaPods `Pods` folders of projects nobody changed for 90 days, one by one with the project's path; none are ticked, and they go to the Trash so Undo can put them back.
- **AI tools**: **LM Studio models** lists each downloaded LM Studio model with its size and date; tick the ones to delete (none are ticked by default, and the row is locked while LM Studio runs).
- **Settings › General › Language**: choose Same as your Mac, English or Tiếng Việt for CleanMate only, with a Restart button.
- Homebrew cask definition (`packaging/Casks/cleanmate.rb`); the release script keeps its version and checksum current.
- **Uninstaller**: an app's `~/.local/state/<name>` is listed with its other config, and **Leftovers of Removed Apps** also shows
  `~/.config`, `~/.local/share` and `~/.local/state` folders that no installed app or command-line tool is named after (never ticked).
- **Developer Junk**: Docker untagged build images are listed one by one and can be cleaned individually.
- **Large & Old Files**: the Scope menu lists mounted external drives, and **Choose Folder…** accepts folders on them; files found there go to that drive's Trash and can be put back with Undo.
- **Developer Junk**: Docker build cache records not in use are listed one by one; tick the ones to clean (none are ticked by default).
- **Developer Junk**: **Unused Homebrew dependencies** lists the formulae `brew autoremove` would remove, each with its size, and removes them with that command (not ticked by default).
- **Smart Scan**: **Trash on external drives** lists the Trash of each mounted external drive by name and size, so you can empty it from the same place as your own Trash (needs Full Disk Access; none are ticked by default).
- **Menu bar item**: shows free space out of the disk's size, the last Smart Scan with what it found or what cleaning it freed, and a **Scan Now** button that opens Smart Scan and starts a scan (replaces Open Smart Scan).
- **Smart Scan**: **Old installers** lists disk images, packages and zipped apps in Downloads older than the old-logs age, one by one; none are ticked, and they go to the Trash (needs Full Disk Access).
- **Developer Junk**: **Stale node_modules** lists the `node_modules` of each JavaScript project in your usual project folders that nobody changed for 90 days, one by one; none are ticked, and they go to the Trash so Undo can put them back.
- **Smart Scan**: **Undo** (and ⌘Z) after a clean puts back what it moved to the Trash.
- **Space Lens**: on a writable external drive, files and folders can be moved to that drive's Trash and put back with Undo; a folder opened on a drive shows the path from the drive. Read-only, network and Time Machine drives stay view-only.
- **Settings › General › Remind me to scan**: an optional weekly or monthly notification (off by default) when CleanMate has gone unused that long; clicking it opens Smart Scan. It is local and uses no network.

### Changed
- **Smart Scan**: the list of files other apps have open is read once per scan and once per clean, shared by every item that skips open files, instead of once per folder of each item (17 items: 31 reads → 1, scan CPU time 4.8 s → 4.4 s); open files are still never listed or removed.
- **Smart Scan**: stale `node_modules` and build folders remember their sizes between scans and are found in one parallel walk, so a machine full of old projects no longer slows every scan (33 projects, 21 GB: 2.9 s on the first scan, 0.06 s on the next).
- Developer junk: the Firebase emulators row is locked while an emulator is running, so its files are never removed from under it.
- **Uninstaller**: folders your shell profile adds to `PATH` (for example `~/.cargo/bin`, nvm or pnpm) count as installed command-line tools, so their config in `~/.config` is no longer listed as a leftover of a removed app.
- **Developer Junk**: rustup downloads are no longer hidden while `cargo` or `rustc` builds; only a running `rustup` skips them.
- Now runs on macOS 13 or later (was macOS 27). On macOS 13, **Space Lens** shows its contents as a stacked bar
  instead of a donut chart.
- **Smart Scan** and **Privacy**: larger checkboxes; a click anywhere on a row ticks it, and ticked rows are tinted.
- **Large Files** and **Uninstaller**: the same larger checkboxes and tinted ticked rows; in Uninstaller a click anywhere on a row ticks it.
  Each group header has a checkbox (all, none or some ticked) instead of Select All / Deselect All, and locked rows
  show a lock with a larger reason text.
- **Smart Scan** finishes sooner and uses less CPU while it scans; **Large Files** redraws its scan progress at most
  10 times a second.

### Fixed
- **AI tools › Ollama models**: a layer several ticked models share now counts once in the selected size and in the space freed, which were smaller than what the clean really freed; hover a model's size to see what it shares and with which models.
- **Uninstaller**: apps macOS has no last-opened date for are no longer treated as never used: they show an estimate from their settings and cache files, or **Unknown**, and the "Not used for" filter leaves unknown ones out unless you choose **Show**.
- **Uninstaller**: Leftovers of Removed Apps no longer lists a config folder of an installed Homebrew formula or cask as orphaned.
- **Smart Scan** and **Privacy**: "Freed" is now the size of what was removed or moved to the Trash, never the noisy
  change in free disk space (it could show less than was removed). The part moved to the Trash is shown apart, and the
  free space before and after is shown for reference.

## [1.3] - 2026-10-24

### Added
- **Smart Scan**: Firebase CLI debug logs (`~/.cache/firebase/firebase-debug.log`, which `firebase mcp` lets grow
  without limit; kept while still open) and its downloaded emulators (unticked).
- **Smart Scan**: ZCode caches and logs (daily app logs in `~/.zcode/v2/logs` can reach several GB), skipped
  while ZCode runs.
- **Smart Scan**: Kilo Code CLI and MiMoCode caches and logs (models list, downloaded tools), skipped while
  the CLI runs; their sessions and settings are kept.
- **Smart Scan**: ZCode's remote server files (Linux server, Node.js and tools it installs on SSH machines,
  downloaded again on the next connection), unticked and skipped while ZCode runs.

## [1.2] - 2026-10-24

### Added
- **Uninstaller**: an app's data in `~/.local/share/<name>` (`~/.local/share/zed`) is listed with its config, not
  ticked, under the same rules as `~/.config/<name>`.
- **Smart Scan**: incomplete Ollama downloads (`-partial` files an interrupted `ollama pull` leaves in the models
  folder) — one unticked row, skipped while Ollama runs.

### Fixed
- **Large & Old Files**: the progress estimate kept a count for every folder ever scanned, without limit; it now
  keeps at most 20 folders inside your home folder and drops older entries from elsewhere on the next scan.

## [1.1] - 2026-10-24

### Added
- **Updates**: CleanMate › Check for Updates… installs new versions from GitHub Releases (signed, verified with
  Sparkle). On the second launch you are asked whether to check automatically; Settings › General › Updates changes
  it. This update check is CleanMate's only network connection and sends no data about you or your Mac.
- **Uninstaller**: an app's config outside ~/Library (`~/.config/zed`, `~/.cursor`…) and folders that only start like
  its name (`BraveSoftware` for Brave Browser, marked "Possibly related") are listed with its data, not ticked.
- **Smart Scan**: Orca and OrbStack caches and logs, and downloaded Ollama models — unticked, each model chosen on
  its own and removed with only the files no other model uses.
- **Smart Scan**: Windsurf code search indexes, browser caches and downloaded browsers (unticked), opencode and
  Cline caches and logs, and old Cursor agent chats stored outside ~/Library.

### Fixed
- **Uninstaller**: finds data in folders named after the app's bundle name or executable or spelled without spaces
  (`Code` for Visual Studio Code, `DiskDrill`, `beekeeper-studio`), and of apps with a three-letter name such as Arc.

## [1.0] - 2026-10-24

First public release: a native macOS cleaner that frees disk space and removes privacy traces,
showing everything first and removing only what you confirm.

### Added
- **Smart Scan**: system junk, developer junk (Xcode, simulators, package caches, Docker, Homebrew…), AI tool data
  and app caches in one scan.
- **Privacy**: browsing history, download history, cookies and autofill per browser, plus recent items, QuickLook
  thumbnails and shell history; nothing is ticked by default.
- **Large & Old Files**: big or unused files in your home folder or a folder you pick, including duplicates.
- **Uninstaller**: remove apps with their data, reset an app, find leftovers, unknown hidden config and extensions.
- **Space Lens**: browse any folder sorted by size, with a donut chart of its contents.
- **Login Items**: disable, enable or remove your launch agents.
- Undo (⌘Z) for what a module just moved to the Trash, and an activity log of every removal with the space freed.
- Optional menu bar item showing free space and the space freed in the last 30 days.
- English and Vietnamese.
- Safety rules checked again right before every removal: running apps and open files are skipped, keys, documents
  and passwords are never touched, user files and apps go to the Trash. No account, no network, no telemetry.
- Open source under the MIT License; you can support development on Ko-fi.
