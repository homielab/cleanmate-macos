# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
- **Smart Scan**: **Undo** (and ⌘Z) after a clean puts back what it moved to the Trash.
- **Settings › General › Remind me to scan**: an optional weekly or monthly notification (off by default) when CleanMate has gone unused that long; clicking it opens Smart Scan. It is local and uses no network.

### Changed
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
