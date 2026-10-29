# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Now runs on macOS 14 or later (was macOS 27).
- **Smart Scan** and **Privacy**: larger checkboxes; a click anywhere on a row ticks it, and ticked rows are tinted.
- **Large Files** and **Uninstaller**: the same larger checkboxes and tinted ticked rows; in Uninstaller a click anywhere on a row ticks it.
  Each group header has a checkbox (all, none or some ticked) instead of Select All / Deselect All, and locked rows
  show a lock with a larger reason text.

### Fixed
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
