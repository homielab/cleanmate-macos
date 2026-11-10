# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.9] - 2026-11-11

### Added
- **Smart Scan › Developer Junk** lists idle virtual machines of Parallels, VMware Fusion, UTM and VirtualBox, one row each, moved to the Trash. Large & Old Files shows a machine as one line.
- **Smart Scan › AI Tools** lists each model you downloaded in llama.cpp, Jan, GPT4All, Draw Things and ComfyUI, with when you last used it. Nothing is ticked, and **Undo** brings a model back.
- **Overview** suggests AI models you haven't touched in over 90 days.
- **Smart Scan › Applications** finds the regenerable caches of Adobe Camera Raw, Capture One, DaVinci Resolve, Blender, Sketch and Affinity, never touching a catalog or project.
- **Smart Scan › Developer Junk** shows what else hides in `~/.cache`, one folder per row and nothing ticked, plus RubyGems, Bundler, Carthage and Hugging Face caches.
- **Smart Scan** cleans caches and old chats of Amp, Qwen Code, Kiro, Trae, Jan, GPT4All, llama.cpp and ComfyUI, and caches of Warp, Ghostty and Raycast. Models and sign-ins stay put.
- Long lists in **Smart Scan** open fast with **Show More**, and **Rescan Skipped Items** checks again only what was in use.

### Changed
- The Settings window fits short screens: the General tab scrolls instead of being cut.

### Fixed
- Counts read correctly in English and Vietnamese ("1 file", "1 copy"), and a reinstalled app shows its new icon without reopening CleanMate.

## [1.8] - 2026-11-06

### Added
- **Similar Photos** (in Large & Old Files) groups photos that look alike, like bursts and edited copies, and suggests which to keep. Nothing is ticked for you, and it all runs on your Mac.
- **Duplicate Files** is much faster: it searches your whole home folder in seconds, and **Stop** keeps what it found.
- **Moved to the Trash**: see everything CleanMate moved to the Trash from any module, even after quitting, and put items back one by one or all at once.
- **Shortcuts and Spotlight**: scan for junk, check free space or open any module from Shortcuts, Spotlight and Siri. Nothing is cleaned until you confirm in CleanMate.
- **Smart Scan** and **Privacy** open a review before cleaning, with sizes and what goes to the Trash or is deleted. Every item has a **Why is this safe?** button, and ⌘F searches the results.
- **Smart Scan › Applications** cleans caches of Zalo, Canva, Teams, WhatsApp, Slack, Discord, Signal, Notion, Figma, Postman and Obsidian. Your messages, files and sign-ins stay put.
- **Smart Scan › Developer Junk** finds forgotten Colima, Lima, Podman, minikube and Rancher Desktop VMs, often tens of GB.
- **Overview** opens instantly and suggests up to 5 places to free space next, and shows your last Smart Scan with **Scan Now**.
- **Open at login** and **Menu bar only** (both off by default) let CleanMate live in the menu bar, so the low disk warning works without a window.
- **Space Lens** can start from the whole startup disk, and **Show Hidden Files** (⇧⌘.) hides dotfiles from the list.
- **Uninstaller** shows where each app came from and has **Quit and Uninstall…**; **Reset…** works on open apps too.
- **Large & Old Files** sorts files into nine kinds with icons, and you can open or preview any file, in Duplicates and Similar Photos too.
- **Stop** (⌘.) works on cleaning, moving to the Trash and Maintenance tasks, and you get a **Freed 1.2 GB** notification when a clean ends in the background.
- CleanMate reopens on the module you used last, with its window in the same place.
- The `cleanmate` command gets `similar`, `space`, `trash`, `restore`, `uninstall`, `privacy` and `login-items`, so the terminal and AI agents can do the same.

### Changed
- Smart Scan and Overview are noticeably faster, and Similar Photos uses a third less memory on big libraries.
- When a clean fails, the done screen says why for each item and what to do, such as granting Full Disk Access.
- Without Full Disk Access, CleanMate says what it skips instead of "nothing found".
- Each release now also carries `CleanMate.dmg`, so the README download link always points to the latest version.

### Fixed
- Better VoiceOver, Reduce Motion and Increase Contrast support.
- Closing the window no longer loses scan results, and CleanMate no longer stalls with a large Trash.
- Space Lens no longer counts the whole disk twice inside /System or walks network shares.
- Dates and some texts now follow CleanMate's language instead of macOS's.
- A few small fixes in the Uninstaller and Large & Old Files.

## [1.7] - 2026-11-02

### Added
- **Smart Scan** cleans the caches and logs of Steam, Epic Games, Battle.net and GOG Galaxy. Your games and saves stay put.
- **Smart Scan** also tidies Minecraft and Prism Launcher logs and caches; worlds and mods are safe.
- **Large & Old Files**: **Remove Download** frees space taken by iCloud Drive files and keeps them in iCloud.

## [1.6] - 2026-11-02

### Added
- A `cleanmate` command line tool for scripts: scan, clean, and find big files, duplicates and what fills a folder.
- AI agents like Claude Code, Codex and Cursor can scan and clean with CleanMate, only touching what you confirm.
- See everything CleanMate moved to the Trash and put it back, even after you quit the app.
- **Developer Junk** cleans Docker images, volumes and stopped containers one by one, so your database volume can stay.
- **Developer Junk** finds old Xcode (15–30 GB each), Unity Editor, asdf and mise versions and Vagrant boxes you forgot about.
- **Developer Junk** also finds more build folders and Terraform, Haskell and Scala caches.

### Changed
- **Smart Scan** is much faster after the first scan: about half the time on a developer Mac.

### Fixed
- Moving items to the Trash is safer.

## [1.5] - 2026-11-01

### Added
- A **Welcome guide** on first launch explains what CleanMate does, helps you give Full Disk Access and sets the main options.
- **Uninstaller**: **Reset…** an app to a fresh start, uninstall several apps at once, and remove Homebrew apps cleanly.
- **Help › Report a Bug…** fills in your system details and opens a GitHub issue. Nothing is sent until you submit.
- **Maintenance**: update and clean Homebrew, reset the font cache, clear the icon cache and delete Time Machine local snapshots.
- **Privacy** clears download history, each app's recent items, and Terminal and iTerm2 saved state.
- **Smart Scan** finds old macOS installers (12–15 GB each) and downloaded Apple Podcasts episodes.
- **Smart Scan** cleans more app leftovers: Telegram, Spotify, Zoom, Microsoft and downloaded app updates.
- **Developer Junk** finds old Android SDK parts, code editor extensions, Xcode test device clones and more caches.

### Changed
- The **Smart Scan** progress bar tells the truth now, and names the slow items still running.
- **Simulator data** lists each simulator, so you erase only the ones you pick.
- **Overview** shows what CleanMate freed in three cards with a daily chart.
- The first **Smart Scan** is about twice as fast with many JavaScript projects.

### Fixed
- Cleaning is safer.
- Fixed a few small display bugs, including animations ignoring **Reduce motion**.

## [1.4] - 2026-10-31

### Added
- A new **Overview** greets you with free space per drive, a 30-day chart, what CleanMate freed and your largest folders.
- **Overview** also shows whether Gatekeeper, the firewall and FileVault are on.
- **Maintenance** fixes **Open With** menus, blank previews and a stuck Finder or Dock in one click.
- **Smart Scan** lists old downloads, screenshots, unfinished downloads and old installers. Nothing is ticked, and you can Undo.
- A notification when your disk is almost full, and an optional reminder to scan.
- **Undo** (⌘Z) after a **Smart Scan** clean puts back what went to the Trash.
- The menu bar item shows free space and your last scan, with a **Scan Now** button.
- **Large & Old Files** and **Space Lens** work on external drives, with Undo.
- **Settings › General › Language**: English or Tiếng Việt.
- **Apps** cleans Adobe media cache, Final Cut Pro and iMovie render files, and Google Drive, Dropbox and OneDrive caches.
- **AI tools** lists downloaded PyTorch, Whisper, Keras and LM Studio models one by one.
- **Developer Junk** finds old Node, Python, Ruby, Rust and Go versions, stale build folders and Android emulator images.
- **Developer Junk** cleans Docker images and build cache one by one, and unused Homebrew dependencies.

### Changed
- CleanMate now runs on macOS 13 or later.
- Checkboxes are bigger, and a click anywhere on a row ticks it.
- **Smart Scan** is faster, especially with many old projects.

### Fixed
- Sizes now match what cleaning really frees, including `node_modules` and Ollama models.
- Fixed a few **Uninstaller** mistakes with unused apps and leftovers.

## [1.3] - 2026-10-24

### Added
- **Smart Scan** cleans more AI and developer tool caches and logs: Firebase, ZCode, Kilo Code and MiMoCode.

## [1.2] - 2026-10-24

### Added
- **Uninstaller** finds more app data, and **Smart Scan** finds unfinished Ollama downloads.

## [1.1] - 2026-10-24

### Added
- **Check for Updates…** installs new versions of CleanMate. It is the app's only network connection and sends nothing about you.
- **Smart Scan** cleans caches of Orca, OrbStack, Windsurf, Cline and opencode, and downloaded Ollama models.
- **Uninstaller** also lists an app's settings outside Library, not ticked.

### Fixed
- **Uninstaller** finds data of more apps, even ones with short or unusual names.

## [1.0] - 2026-10-24

First public release: a native macOS cleaner that frees disk space and clears privacy traces. It shows everything first and removes only what you confirm.

### Added
- **Smart Scan**: system junk, developer junk, AI tool data and app caches in one scan.
- **Privacy**: browsing history, cookies and autofill per browser, plus recent items and shell history. Nothing is ticked.
- **Large & Old Files**: find big or unused files and duplicates.
- **Uninstaller**: remove apps with their data, reset an app and find leftovers.
- **Space Lens**: browse any folder by size.
- **Login Items**: turn launch agents off, on or remove them.
- **Undo** (⌘Z) for what was just moved to the Trash, and an activity log of every removal.
- An optional menu bar item showing free space.
- English and Vietnamese.
- Running apps and open files are skipped, and your documents and passwords are never touched. No account, no network, no telemetry.
- Open source under the MIT License.
