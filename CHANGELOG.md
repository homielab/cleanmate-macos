# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
