# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
