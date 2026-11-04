# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Open at login** and **Menu bar only** (Settings › General and the welcome guide, both off by default): CleanMate can start in the menu bar when you log in, with no window, and leave the Dock while its window is closed, so the low disk warning and scan reminder work without opening it. It still never cleans unless you click.
- **Overview › Suggestions**: up to 5 places to free space next, largest first — junk the last Smart Scan found per group, the Trash, apps not opened for 3 months, unused Docker data, Time Machine local snapshots and, with Full Disk Access, old downloads and external drives' Trash; each opens the right module (Smart Scan at the group, Uninstaller on unused apps, Maintenance at the snapshots) and nothing is cleaned from the Overview.
- **Smart Scan › Applications**: clean the caches of Zalo, Canva, the new Microsoft Teams and WhatsApp (Teams and WhatsApp need Full Disk Access); messages, received photos and files, designs and sign-in are never touched, and each app is skipped while it runs.
- **Smart Scan › Applications**: also clean the caches and logs of Slack (download and App Store builds), Discord, Signal, Notion, Figma, Postman and Obsidian, each with a "Why is this safe?" note; messages, attachments, vaults, collections and sign-in are never touched, and each app is skipped while it runs.
- **Moved to the Trash**: see everything CleanMate moved to the Trash from any module, also after quitting, and put items back one by one or all at once, filtered by source or search; open it with **View Moved Items…** after a move to the Trash or in Settings › Activity.
- **Uninstaller**: each app shows its source (App Store, Homebrew, Setapp or Downloaded) and the **Show** menu filters the list by source; an open app has **Quit and Uninstall…**, which quits it and uninstalls it in one step.
- **Uninstaller › Reset…** works on an open app: **Quit and Reset** asks it to quit, waits up to 10 seconds, then moves its data to the Trash and keeps the app; if it doesn't quit, nothing is moved.
- CleanMate opens on the module you used last, with its window at the same place and size; a notification or the menu bar's **Scan Now** still opens Smart Scan.
- **Similar Photos**, **Login Items** and **Maintenance** have a search field, and ⌘F goes to the search field in every list; ⌘A / ⇧⌘A tick or untick what **Large & Old Files**, **Similar Photos** and **Uninstaller** show.
- A **Freed 1.2 GB** notification when a Smart Scan clean or a Privacy erase finishes while CleanMate is in the background (only if notifications are already allowed; it never asks).
- **Space Lens**: **Startup Disk** in the Location menu shows the top level of the disk (Applications, Library, System, Users…) with sizes; folders outside your home folder open with the breadcrumb from the disk, and view-only items show a lock saying why (protected by SIP, system library, another user's folder, apps). **View in Space Lens** on the Overview's **System and apps** opens it.
- **Space Lens**: **Show Hidden Files** (⇧⌘.) hides dotfiles from the list while still counting them in the total.
- **Large & Old Files**: the Kind filter has nine kinds with icons — videos, audio, images, documents, code & projects (also unknown files inside a project folder or Git repository), archives, disk images, installers and other — so far fewer files land in **Other**; `cleanmate large --json` reports the same kinds.
- **Large & Old Files**, **Duplicates Only** and **Similar Photos**: **Open** a file with its app (right-click or Return, and double-click in the file list), and preview it with the eye button on each row as well as Space; **Last Used** adds **Over 1 month ago** and **Custom…** for any number of days.
- **Similar Photos**: **Sort By** lists groups by space to free, date or number of photos.
- **Smart Scan** and **Privacy**: every item has a **Why is this safe?** button that explains what it is, where it is, what cleaning does to it (made again, moved to the Trash or deleted for good) and when it is skipped, in English and Vietnamese.
- **Smart Scan** and **Privacy**: **Clean…** / **Erase…** first opens a review of everything ticked, by group, with each item's size and whether it goes to the Trash or is deleted permanently, the total of each, and what will be skipped; untick anything there before cleaning.
- **Smart Scan** and **Privacy**: search the results with ⌘F by item name or file path; ⌘A / ⇧⌘A tick or untick the whole group of the selected row.
- **Large & Old Files › Similar Photos**: groups photos that look alike (bursts, edits, resized or recompressed copies), compared on this Mac with Vision; each group suggests the photo to keep, nothing is ticked for you, and moved photos can be put back with `cleanmate restore`. Photos libraries and apps are never read. Stop ends the search at once, even while photos are being analyzed.
- `cleanmate similar [PATH…] [--json]` lists the same groups of similar photos from the command line, with the photo suggested to keep; move the ones you pick with `cleanmate trash` and put them back with `cleanmate restore`. The Agent Skill uses it too.
- **Overview**: shows the last Smart Scan and what it found or freed, with **Scan Now**, and **Clean … Selected** while Smart Scan has results.
- `cleanmate scan` ends with how long the scan took and its three slowest items; `cleanmate scan --json` adds `durationMs` to the report and to each item.
- **Login Items**: after removing an agent, **Undo** (also ⌘Z) puts it back and loads it again, and **View Moved Items…** shows it.

- **Stop** while a Smart Scan or Privacy clean runs (the rest is left as it is and the done screen says how many items weren’t cleaned), on a running Maintenance task, and while the Uninstaller waits for an app to quit; ⌘. does the same.
### Changed
- The menu bar item shows **Junk found: X (scanned …)**, everything the last Smart Scan found, and opens Smart Scan when clicked.
- **Large & Old Files › Similar Photos** and `cleanmate similar` use about a third less memory on large libraries (20,000 photos: 490 MB → 320 MB at peak), with the same groups.
- **Overview** opens at once: the largest folders in your home show the sizes of the last measure, with when they were measured, while they are measured again in the background.
- Each release also carries `CleanMate.dmg` (+ `.sha256`), so the README download link always points to the latest version.
- **Smart Scan › Developer**: Gradle caches are measured faster (their folders are read in parallel), with the same items and sizes.
- **Smart Scan**: Simulator data and Old temporary files are measured faster, with far less CPU, with the same items and sizes.
- When something can't be cleaned, moved to the Trash, uninstalled or reset, the done screen says how many items stayed and **Show Details…** lists each one with the real reason (not permitted, in use, locked, no Trash on the drive, iCloud file not downloaded, or the tool's exit code and error) and what to do, such as granting Full Disk Access or quitting the app. Settings › Activity shows the reason too.
- **Large & Old Files**: after a move to the Trash the list stays, without the files moved, and nothing is scanned again; a bar above it shows what was moved, with **Undo**.
- **Overview**: measuring your home folder shows which folder is being measured and how much so far, with a **Stop** button; after a clean only the folders it touched are measured again.

### Fixed
- Closing the window no longer loses scan results or a scan still running; quitting during a Maintenance task asks first and ends its tool; after a hidden start at login, the update check waits until you open the window.
- CleanMate no longer stalls while checking Full Disk Access with a large Trash: the check reads one entry instead of listing the whole Trash, in the background when CleanMate becomes active.
- **Similar Photos**: when too many photos look nearly alike to compare them all, the results say **Results may be incomplete** instead of leaving photos out silently.
- The menu bar and Overview line **Junk found: … (scanned …)**, dates in notifications and some Settings texts now use CleanMate's language (for example Vietnamese) and its date format even when macOS is set to another language.
- `cleanmate dupes` with a folder it can't search names `cleanmate dupes` in the error, not `cleanmate large`.
- `cleanmate space /` no longer counts the startup disk's data volume a second time inside /System: another volume mounted in a folder is listed as a mounted volume and left out of the total, as in Space Lens.
- **Uninstaller**: an App Store app macOS won't let CleanMate move no longer brings up an unexplained password prompt; CleanMate says to remove it in Launchpad or drag it to the Trash in Finder, with **Reveal in Finder**.
- **Space Lens**: a volume mounted inside a folder is no longer measured with it — /System no longer counts the whole data volume again, and network shares in your home folder are not walked.
- **Space Lens** and **Overview** no longer show a folder macOS won't let CleanMate read as empty: it says **Not Readable** with a way to grant Full Disk Access, and a size that couldn't be measured says **Not measured**.
- **Large & Old Files**: a duplicate search that fails now says so, with **Try Again**, instead of stopping silently; a reset in the **Uninstaller** that fails now always shows its result.

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
