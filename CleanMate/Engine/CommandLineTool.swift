import Foundation

/// The `cleanmate` command line tool inside CleanMate.app: `list`, a read-only `scan` and `clean`, the read-only
/// `space`, `large`, `dupes` and `similar` (what takes the disk space), `trash` / `restore` for exactly the paths
/// named, and the Uninstaller, Privacy and Login Items modules (`uninstall`, `privacy`, `login-items`, in
/// `CommandLineModules.swift`), as text or JSON. Stdin only for the confirmation of a command that removes or moves
/// something, on a terminal; no network; colours only on a terminal without `NO_COLOR`.
nonisolated enum CommandLineTool {
    enum Exit: Int32 {
        case ok = 0
        case failure = 1
        case usage = 2
        case noFullDiskAccess = 3
        /// `clean` or `trash` without `--yes` and without a terminal to confirm on: nothing was deleted or moved.
        case notConfirmed = 4
        /// `uninstall` of an app that is open (without `--quit`, or it did not quit): nothing was moved.
        case appRunning = 5
    }

    /// Where the tool writes; tests collect the text.
    struct Output: Sendable {
        var out: @Sendable (String) -> Void
        var err: @Sendable (String) -> Void
        /// ANSI colours in text output.
        var color: Bool
        /// A "Scanning…" line on stderr while a text scan runs.
        var progress: Bool
        /// Stdin is a terminal: `clean` and `trash` without `--yes` ask there.
        var interactive = false
        /// One line typed on stdin; nil at its end.
        var readLine: @Sendable () -> String? = { nil }

        static var standard: Output {
            let environment = ProcessInfo.processInfo.environment
            let plain = environment["NO_COLOR"].map { !$0.isEmpty } == true || environment["TERM"] == "dumb"
            return Output(out: { FileHandle.standardOutput.write(Data($0.utf8)) },
                          err: { FileHandle.standardError.write(Data($0.utf8)) },
                          color: !plain && isatty(STDOUT_FILENO) == 1, progress: isatty(STDERR_FILENO) == 1,
                          interactive: isatty(STDIN_FILENO) == 1, readLine: { Swift.readLine() })
        }
    }

    enum Command: Equatable {
        case help
        case version
        case list(json: Bool, privacy: Bool)
        case scan(HeadlessScan.Options, json: Bool, requireFullDiskAccess: Bool)
        case clean(HeadlessScan.Options, json: Bool, requireFullDiskAccess: Bool, dryRun: Bool, yes: Bool)
        case space(HeadlessFiles.SpaceOptions, json: Bool)
        case large(HeadlessFiles.LargeOptions, json: Bool)
        case dupes(HeadlessFiles.DupesOptions, json: Bool)
        case similar(HeadlessFiles.SimilarOptions, json: Bool)
        case trash(paths: [String], json: Bool, yes: Bool)
        case restore(paths: [String], json: Bool)
        case restoreList(limit: Int, json: Bool)
        case uninstallList(leftoversOnly: Bool, json: Bool)
        case uninstall(HeadlessApps.Options, json: Bool)
        case removeLeftovers(paths: [String], dryRun: Bool, yes: Bool, json: Bool)
        case privacy(json: Bool)
        case privacyErase(ids: [String], dryRun: Bool, yes: Bool, json: Bool)
        case loginItems(json: Bool)
        case loginItemRemove(label: String, yes: Bool, json: Bool)
        case loginItemRestore(label: String, json: Bool)
    }

    struct UsageError: Error, Equatable { let message: String }

    static let usage = """
        Usage:
          cleanmate list [--json] [--privacy]
          cleanmate scan [--only ID,ID…] [--group G,G…] [--privacy] [--json] [--require-fda]
          cleanmate clean [--only ID,ID…] [--group G,G…] [--privacy] [--dry-run] [--yes] [--json] [--require-fda]
          cleanmate space [PATH] [--limit N] [--json]
          cleanmate large [--min-size SIZE] [--older-than DAYS] [--in PATH] [--limit N] [--json]
          cleanmate dupes [--min-size SIZE] [--in PATH] [--limit N] [--json]
          cleanmate similar [PATH…] [--limit N] [--json]
          cleanmate trash [--yes] [--json] [--] PATH…
          cleanmate restore [--json] [--] TRASHED…
          cleanmate restore --list [--limit N] [--json]
          cleanmate uninstall [--leftovers] [--json]
          cleanmate uninstall APP [--leftovers-only] [--quit] [--dry-run] [--yes] [--json]
          cleanmate uninstall --leftovers [--dry-run] [--yes] [--json] [--] PATH…
          cleanmate privacy [--json]
          cleanmate privacy --erase [ID…] [--dry-run] [--yes] [--json]
          cleanmate login-items [--json]
          cleanmate login-items remove LABEL [--yes] [--json]
          cleanmate login-items restore LABEL [--json]
          cleanmate --version
          cleanmate --help

        """

    static let help = """
        cleanmate: CleanMate's Smart Scan, Space Lens, Large & Old Files, Uninstaller, Privacy and Login Items on
        the command line, for scripts and AI agents. list, scan, space, large, dupes and similar are read-only, and
        so are uninstall, privacy and login-items without an app, --erase or an action. clean removes what scan finds
        with the app's safety rules; trash moves exactly the files and folders you name to the Trash, and restore puts
        them back. All of them write the app's activity log. It never connects to the network and never asks for a
        password.

        \(usage)
        Commands:
          list            Every Smart Scan item: id, group, name, what it removes, ticked by default or not,
                          deleted or moved to the Trash, may hold data or not.
          scan            Measures the items like Smart Scan in the app: the same items, safety rules,
                          Settings › Exclusions and Scan Groups. An item whose app or tool is running is
                          locked, with the reason; files in use are skipped.
          clean           Scans again, then cleans like the app: the items named with --only, else the
                          items ticked by default (in the groups named with --group). Privacy items only
                          when named. Junk that apps rebuild is deleted; items marked "moves to Trash" in
                          `cleanmate list` go to the Trash. Locked items and files in use are skipped and
                          reported with the reason. On a terminal it asks before cleaning; anywhere
                          else it needs --yes.
                          Items marked "may hold data" (Docker volumes, stopped containers) are deleted
                          for good with what is inside: clean takes them only when named with --only,
                          never because they are ticked in the app.
          space           What takes the space in a folder (default: your home folder), like Space Lens: its
                          size and its biggest files and folders, sizes as `du -x` counts them (a hard-linked
                          file once). Read-only: to move something to the Trash, use `cleanmate trash`.
          large           Your largest files, like Large & Old Files: in your home folder (not ~/Library or
                          hidden folders; node_modules, Pods and DerivedData skipped) or the folder named with
                          --in, Settings › Exclusions left out. Read-only: to move files to the Trash, use
                          `cleanmate trash`.
          dupes           Duplicate files, like Duplicate Files in Large & Old Files: files of 1 MB or more
                          (--min-size) in the same folders as large (exclusions left out, never inside an
                          app or the Photos library, iCloud files not downloaded never read), same content,
                          a hard-linked file counted once, APFS clones freeing nothing. Groups by space
                          wasted (what moving every copy but the oldest would free). Read-only: to move
                          copies to the Trash, use `cleanmate trash`.
          similar         Similar photos, like Similar Photos in Large & Old Files: bursts, edits, resized
                          or recompressed copies of a photo (JPEG, HEIC, PNG, TIFF or WebP of 20 KB or more),
                          compared with Vision on this Mac, never uploaded. Searches your home folder or the
                          folders named (as large --in does), never inside the Photos library or an app,
                          Settings › Exclusions left out. Each group lists the photo suggested to keep first
                          and what moving the others would free. Read-only and nothing chosen for you: to
                          move the photos you pick to the Trash, use `cleanmate trash`.
          trash           Moves the files and folders named, and only those, to the Trash: no wildcards,
                          nothing deleted. Each must be in your home folder, not in ~/Library, not hidden
                          (like ~/.ssh), not inside an app or package, not a top-level folder of your home
                          (like ~/Documents itself), not excluded in Settings › Exclusions, and not a symlink;
                          anything else is skipped with the reason. On a terminal it asks first; anywhere
                          else it needs --yes. Prints where each item went in the Trash.
          restore         Puts back items CleanMate moved to the Trash (`cleanmate trash`, Smart Scan, Large &
                          Old Files, Space Lens, the Uninstaller; also after CleanMate quit), named by their
                          path in the Trash (as trash or restore --list printed it), to the exact place they
                          came from. Never overwrites: skipped when something is at that place now, or its
                          folder was moved, removed or replaced by a symlink. Deleted junk can't be put back.
                          With --list it only lists those items still in the Trash, newest first: when,
                          size, where each came from and its path in the Trash.
          uninstall       Without APP: the apps the Uninstaller lists (not Apple's), with bundle id, source
                          (App Store, Homebrew, Setapp or Downloaded), size of the app and of its data, last
                          used and whether it is open; then the leftovers of apps already removed.
                          --leftovers lists only those. Read-only.
                          With APP (name, bundle id or path of the .app): moves the app and its own data in
                          ~/Library to the Trash like the app's Uninstall, stops its launch agents and clears
                          a Homebrew cask's record. Folders that only look like its name and config folders
                          in ~ are listed, never taken. --leftovers-only keeps the app and moves only its
                          data, like the app's Reset. An open app is never touched (exit code 5): quit it,
                          or add --quit to ask it to quit first. An App Store app macOS only lets you remove
                          yourself, or an app owned by another user, is left with the reason: no password
                          prompt. --leftovers PATH… moves leftovers of removed apps, only paths that
                          `cleanmate uninstall --leftovers` lists. On a terminal it asks first; anywhere else
                          it needs --yes. Everything goes to the Trash: `cleanmate restore` puts it back.
          privacy         The Privacy items: browsing history, cookies and form data per browser, recent
                          items and shell history, with their size. An item whose browser is running is
                          skipped, with the reason. Read-only.
                          --erase erases the items named by id (default: those ticked in the app), with the
                          app's safety rules, skipping a browser that runs. Erased traces are deleted and
                          can't be put back; erasing cookies signs you out of websites. On a terminal it asks
                          first; anywhere else it needs --yes.
          login-items     Your login items and launch agents (~/Library/LaunchAgents) and the system's
                          (/Library/LaunchAgents and LaunchDaemons): label, state, the program each runs.
                          remove LABEL moves one of yours to the Trash and stops it, like the app's Login
                          Items (the system's need an administrator: only listed). On a terminal it asks
                          first; anywhere else it needs --yes. restore LABEL puts it back from the Trash and
                          loads it again.

        Options:
          --json          Print one JSON object instead of text.
          --only IDS      Only these items (ids from `cleanmate list`), comma-separated.
          --group GROUPS  Only these groups, comma-separated: system, user, dev, ai, apps, privacy.
                          A group turned off in Settings is scanned when named here.
          --privacy       Include the Privacy items (browser history, cookies, recent items).
          --dry-run       clean, uninstall, privacy --erase: report what would be removed; change nothing,
                          log nothing.
          --yes, -y       clean, trash, uninstall APP or --leftovers, privacy --erase, login-items remove:
                          don't ask. Required when not run in a terminal (scripts, AI agents).
          --leftovers     uninstall: list the leftovers of removed apps only, or move the PATHs named.
          --leftovers-only
                          uninstall APP: move only the app's data to the Trash; the app stays.
          --quit          uninstall APP: ask the open app to quit (it may ask to save first) and wait up to
                          10 seconds; still open → nothing moved, exit code 5.
          --erase         privacy: erase the items named by id, or those ticked in the app.
          --require-fda   Exit with code 3 instead of scanning when Full Disk Access is missing.
          --limit N       space, large: list the N biggest (default 20 for space, 50 for large);
                          dupes: the N groups wasting the most space (default 20);
                          similar: the N groups freeing the most space (default 20);
                          restore --list: the N newest (default 200).
          --list          restore: list what can be put back instead of putting anything back.
          --min-size SIZE large, dupes: only files of at least SIZE, like 100MB or 1.5GB (1 MB = 1,000,000 bytes).
                          large: default and minimum 50MB for the home folder; 1MB minimum with --in.
                          dupes: default 1MB, minimum 100KB.
          --older-than DAYS
                          large: only files not opened or changed for DAYS days.
          --in PATH       large, dupes: search this folder (in your home folder or on an external drive) instead.
                          similar: the same as naming PATH.
          --              trash, restore, uninstall: every argument after it is a path, even one starting with -.
          -h, --help      Show this help.
          --version       Show the version.

        Full Disk Access:
          macOS grants it to the app that runs cleanmate (Terminal, iTerm, your AI agent's app), not to
          CleanMate. Without it the scan skips the folders macOS protects (Desktop, Documents, Downloads,
          the Trash, Mail, other apps' data) and reports "fullDiskAccess": false; space, large, dupes and similar list
          them as skipped, and refuse a PATH inside one (exit code 3). To grant it: System
          Settings › Privacy & Security › Full Disk Access, turn on that app, then quit and reopen it.

        Undo:
          Deleted junk and erased Privacy traces can't be put back. Check first with
          `cleanmate clean --dry-run`. What CleanMate moved to the Trash (trash, clean, uninstall,
          login-items remove, and the app's Smart Scan, Large & Old Files, Space Lens, Uninstaller and
          Login Items) is listed by `cleanmate restore --list`, and `cleanmate restore TRASHED…` puts it
          back, until the Trash is emptied. `cleanmate login-items restore LABEL` also loads the item again.

        Exit codes:
          0  OK (also when some items or files were skipped)
          1  Error (also: uninstall left the app, as App Store, locked, owned by another user or brew busy;
             login-items could not remove or restore the item)
          2  Invalid arguments (also a PATH that is missing, not a folder or can't be read; no app, Privacy
             item or login item by that name)
          3  No Full Disk Access with --require-fda, or space, large, dupes or similar asked for a folder macOS
             protects
          4  clean, trash, uninstall, privacy --erase or login-items remove without --yes and without a
             terminal: nothing was deleted or moved
          5  uninstall: the app is open (add --quit) or did not quit: nothing was moved

        """

    /// Runs the tool on `arguments` (without the program name) and returns its exit code.
    static func run(_ arguments: [String], sources: HeadlessScan.Sources = HeadlessScan.Sources(),
                    output: Output = .standard) async -> Int32 {
        let command: Command
        do {
            command = try parse(arguments)
            if case .scan(let options, _, _) = command { try HeadlessScan.validate(options, sources: sources) }
            if case .clean(let options, _, _, _, _) = command { try HeadlessScan.validate(options, sources: sources) }
        } catch let error as UsageError {
            output.err("cleanmate: \(error.message)\nRun `cleanmate --help` for usage.\n")
            return Exit.usage.rawValue
        } catch let error as HeadlessScan.OptionError {
            output.err("cleanmate: \(message(error))\nRun `cleanmate --help` for usage.\n")
            return Exit.usage.rawValue
        } catch {
            output.err("cleanmate: \(error.localizedDescription)\n")
            return Exit.failure.rawValue
        }
        switch command {
        case .help:
            output.out(help)
        case .version:
            output.out("cleanmate \(sources.version())\n")
        case .list(let json, let privacy):
            let report = HeadlessScan.list(privacy: privacy, sources: sources)
            guard let text = json ? encode(report) : listText(report, color: output.color) else { return Exit.failure.rawValue }
            output.out(text)
        case .scan(let options, let json, let requireAccess):
            if requireAccess && !sources.hasFullDiskAccess() { return noFullDiskAccess(output) }
            let showsProgress = output.progress && !json
            if showsProgress { output.err("Scanning…") }
            let report = await HeadlessScan.scan(options, sources: sources)
            if showsProgress { output.err("\r\u{1B}[K") }
            guard let text = json ? encode(report) : scanText(report, color: output.color) else { return Exit.failure.rawValue }
            output.out(text)
        case .clean(let options, let json, let requireAccess, let dryRun, let yes):
            return await clean(options, json: json, requireFullDiskAccess: requireAccess, dryRun: dryRun, yes: yes,
                               sources: sources, output: output)
        case .space(let options, let json):
            let folder: URL
            do { folder = try HeadlessFiles.spaceFolder(options, sources: sources) } catch { return pathError(error, output) }
            let showsProgress = output.progress && !json
            if showsProgress { output.err("Measuring…") }
            let report = await HeadlessFiles.space(folder, limit: options.limit, sources: sources)
            if showsProgress { output.err("\r\u{1B}[K") }
            guard let text = json ? encode(report) : spaceText(report, home: sources.policy().homeURL, color: output.color)
            else { return Exit.failure.rawValue }
            output.out(text)
        case .large(let options, let json):
            let root: URL
            do { root = try HeadlessFiles.largeFolder(options, sources: sources) } catch { return pathError(error, output) }
            let showsProgress = output.progress && !json
            if showsProgress { output.err("Searching…") }
            let found = try? await HeadlessFiles.large(root, options: options, sources: sources)
            if showsProgress { output.err("\r\u{1B}[K") }
            guard let report = found else {
                output.err("cleanmate: could not search \(options.root ?? "~")\n")
                return Exit.failure.rawValue
            }
            guard let text = json ? encode(report) : largeText(report, home: sources.policy().homeURL, color: output.color)
            else { return Exit.failure.rawValue }
            output.out(text)
        case .dupes(let options, let json):
            let root: URL
            do { root = try HeadlessFiles.dupesFolder(options, sources: sources) } catch { return pathError(error, output) }
            let showsProgress = output.progress && !json
            if showsProgress { output.err("Searching…") }
            let found = try? await HeadlessFiles.dupes(root, options: options, sources: sources)
            if showsProgress { output.err("\r\u{1B}[K") }
            guard let report = found else {
                output.err("cleanmate: could not search \(options.root ?? "~")\n")
                return Exit.failure.rawValue
            }
            guard let text = json ? encode(report) : dupesText(report, home: sources.policy().homeURL, color: output.color)
            else { return Exit.failure.rawValue }
            output.out(text)
        case .similar(let options, let json):
            return await similar(options, json: json, sources: sources, output: output)
        case .trash(let paths, let json, let yes):
            return await trash(paths, json: json, yes: yes, sources: sources, output: output)
        case .restore(let paths, let json):
            let report = noteBrokenRecords(sources: sources, output: output) { HeadlessTrash.restore(paths, sources: sources) }
            guard let text = json ? encode(report) : restoreText(report, home: sources.policy().homeURL, color: output.color)
            else { return Exit.failure.rawValue }
            output.out(text)
        case .restoreList(let limit, let json):
            let report = noteBrokenRecords(sources: sources, output: output) { HeadlessTrash.list(limit: limit, sources: sources) }
            guard let text = json ? encode(report) : restoreListText(report, home: sources.policy().homeURL, color: output.color)
            else { return Exit.failure.rawValue }
            output.out(text)
        case .uninstallList(let leftoversOnly, let json):
            return await uninstallList(leftoversOnly: leftoversOnly, json: json, sources: sources, output: output)
        case .uninstall(let options, let json):
            return await uninstall(options, json: json, sources: sources, output: output)
        case .removeLeftovers(let paths, let dryRun, let yes, let json):
            return await removeLeftovers(paths, dryRun: dryRun, yes: yes, json: json, sources: sources, output: output)
        case .privacy(let json):
            return await privacy(json: json, sources: sources, output: output)
        case .privacyErase(let ids, let dryRun, let yes, let json):
            return await privacyErase(ids: ids, dryRun: dryRun, yes: yes, json: json, sources: sources, output: output)
        case .loginItems(let json):
            return await loginItems(json: json, sources: sources, output: output)
        case .loginItemRemove(let label, let yes, let json):
            return await loginItemRemove(label: label, yes: yes, json: json, sources: sources, output: output)
        case .loginItemRestore(let label, let json):
            return await loginItemRestore(label: label, json: json, sources: sources, output: output)
        }
        return Exit.ok.rawValue
    }

    /// Runs `body`; when it found the records file unreadable and set it aside (`TrashRecords.setAside`), says so on
    /// stderr (the JSON on stdout stays as it is).
    private static func noteBrokenRecords<T>(sources: HeadlessScan.Sources, output: Output, _ body: () -> T) -> T {
        let home = sources.policy().homeURL
        let before = Set(TrashRecords.broken(home: home))
        let result = body()
        if let kept = TrashRecords.broken(home: home).first(where: { !before.contains($0) }) {
            output.err("cleanmate: the list of moved items couldn’t be read; it was kept as "
                       + "\(HeadlessScan.displayPath(kept, home: home)) and a new one started. "
                       + "Items moved before that are still in the Trash: put them back in Finder.\n")
        }
        return result
    }

    private static func pathError(_ error: HeadlessFiles.PathError, _ output: Output) -> Int32 {
        if error.needsFullDiskAccess {
            output.err("cleanmate: \(error.message)\n")
            return Exit.noFullDiskAccess.rawValue
        }
        output.err("cleanmate: \(error.message)\nRun `cleanmate --help` for usage.\n")
        return Exit.usage.rawValue
    }

    static func noFullDiskAccess(_ output: Output) -> Int32 {
        output.err("cleanmate: no Full Disk Access. Grant it to the app that runs cleanmate in System Settings › "
                   + "Privacy & Security › Full Disk Access, then reopen that app.\n")
        return Exit.noFullDiskAccess.rawValue
    }

    private static func clean(_ options: HeadlessScan.Options, json: Bool, requireFullDiskAccess: Bool, dryRun: Bool,
                              yes: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        let asks = !dryRun && !yes
        if asks && !output.interactive {
            output.err("cleanmate: nothing was deleted. Without a terminal, clean needs --yes: check the items with "
                       + "`cleanmate scan` (or `cleanmate clean --dry-run`), then run `cleanmate clean --yes` with the same options.\n")
            return Exit.notConfirmed.rawValue
        }
        if requireFullDiskAccess && !sources.hasFullDiskAccess() { return noFullDiskAccess(output) }
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Scanning…") }
        let plan = await HeadlessClean.plan(options, sources: sources)
        if showsProgress { output.err("\r\u{1B}[K") }
        if asks && !plan.cleanable.isEmpty {
            output.err(confirmation(plan))
            let answer = output.readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                output.err("Nothing was deleted.\n")
                return Exit.ok.rawValue
            }
        }
        if showsProgress && !dryRun { output.err("Cleaning…") }
        let report = await HeadlessClean.clean(plan, dryRun: dryRun, sources: sources)
        if showsProgress && !dryRun { output.err("\r\u{1B}[K") }
        guard let text = json ? encode(report) : cleanText(report, color: output.color) else { return Exit.failure.rawValue }
        output.out(text)
        return Exit.ok.rawValue
    }

    private static func similar(_ options: HeadlessFiles.SimilarOptions, json: Bool, sources: HeadlessScan.Sources,
                                output: Output) async -> Int32 {
        let roots: [URL]
        do { roots = try HeadlessFiles.similarFolders(options, sources: sources) } catch { return pathError(error, output) }
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Searching…") }
        // At most ~10 progress lines a second.
        let shown = Locked<ContinuousClock.Instant>(ContinuousClock.now - .seconds(1))
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            let due = shown.withLock { (last: inout ContinuousClock.Instant) -> Bool in
                guard done == total || ContinuousClock.now - last >= .milliseconds(100) else { return false }
                last = .now
                return true
            }
            if due { output.err("\r\u{1B}[KComparing photos… \(done)/\(total)") }
        }
        let found = try? await HeadlessFiles.similar(roots, options: options, sources: sources,
                                                     progress: showsProgress ? progress : nil)
        if showsProgress { output.err("\r\u{1B}[K") }
        guard let report = found else {
            output.err("cleanmate: could not search \(options.roots.isEmpty ? "~" : options.roots.joined(separator: ", "))\n")
            return Exit.failure.rawValue
        }
        guard let text = json ? encode(report) : similarText(report, home: sources.policy().homeURL, color: output.color)
        else { return Exit.failure.rawValue }
        output.out(text)
        return Exit.ok.rawValue
    }

    private static func trash(_ paths: [String], json: Bool, yes: Bool, sources: HeadlessScan.Sources,
                              output: Output) async -> Int32 {
        if !yes && !output.interactive {
            output.err("cleanmate: nothing was moved. Without a terminal, trash needs --yes: run it only with the "
                       + "paths the user confirmed, as `cleanmate trash --yes PATH…`.\n")
            return Exit.notConfirmed.rawValue
        }
        let targets = await HeadlessTrash.targets(paths, sources: sources)
        let home = sources.policy().homeURL
        if !yes && targets.contains(where: \.movable) {
            output.err(trashConfirmation(targets, home: home))
            let answer = output.readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            guard answer == "y" || answer == "yes" else {
                output.err("Nothing was moved.\n")
                return Exit.ok.rawValue
            }
        }
        let report = HeadlessTrash.trash(targets, sources: sources)
        guard let text = json ? encode(report) : trashText(report, home: home, color: output.color) else {
            return Exit.failure.rawValue
        }
        output.out(text)
        return Exit.ok.rawValue
    }

    /// The question asked on a terminal before `trash` moves anything.
    static func trashConfirmation(_ targets: [HeadlessTrash.Target], home: URL) -> String {
        let movable = targets.filter(\.movable)
        let total = movable.reduce(Int64(0)) { $0 + ($1.item.size ?? 0) }
        var text = "About to move \(movable.count) item\(movable.count == 1 ? "" : "s") (\(size(total))) to the Trash:\n"
        for target in targets {
            let path = shown(target.item.path, home: home)
            text += target.movable ? "  \(rightAligned(size(target.item.size ?? 0), 10))  \(path)\n"
                : "  \(rightAligned("–", 10))  \(path)  skipped: \(target.item.reason ?? "")\n"
        }
        return text + "Undo afterwards with `cleanmate restore`.\nProceed? [y/N] "
    }

    /// The question asked on a terminal before cleaning.
    static func confirmation(_ plan: HeadlessClean.Plan) -> String {
        let count = plan.cleanable.count
        var text = "About to clean \(count) item\(count == 1 ? "" : "s"): "
        let parts = [plan.deleteSize > 0 || plan.trashSize == 0 ? "\(size(plan.deleteSize)) deleted (junk apps rebuild)" : nil,
                     plan.trashSize > 0 ? "\(size(plan.trashSize)) moved to the Trash" : nil].compactMap { $0 }
        text += parts.joined(separator: ", ") + ".\n"
        for target in plan.cleanable {
            text += "  \(target.report.name)  \(target.report.sizeIsUpperBound ? "up to " : "")\(size(target.report.size))"
                + (target.report.disposal == "trash" ? " (to Trash)" : "") + "\n"
        }
        if !plan.held.isEmpty {
            text += "Not cleaned, may hold data (name with --only to clean): "
                + plan.held.map(\.report.name).joined(separator: ", ") + "\n"
        }
        return text + "Deleted junk can't be put back; `cleanmate restore` puts back what goes to the Trash.\nProceed? [y/N] "
    }

    static func parse(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { throw UsageError(message: "missing command\n\n" + usage) }
        var rest = arguments.dropFirst()
        switch first {
        case "-h", "--help", "help":
            return .help
        case "--version", "version":
            guard rest.isEmpty else { throw UsageError(message: "unexpected argument `\(rest.first!)`") }
            return .version
        case "list", "scan", "clean":
            var json = false, privacy = false, requireAccess = false, dryRun = false, yes = false
            var options = HeadlessScan.Options()
            while let argument = rest.popFirst() {
                let (name, inline) = split(argument)
                func value() throws -> [String] {
                    guard let text = inline ?? rest.popFirst(), !text.isEmpty, !text.hasPrefix("-") else {
                        throw UsageError(message: "\(name) needs a value")
                    }
                    let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    guard !values.isEmpty else { throw UsageError(message: "\(name) needs a value") }
                    return values
                }
                switch (name, first) {
                case ("-h", _), ("--help", _): return .help
                case ("--json", _) where inline == nil: json = true
                case ("--privacy", _) where inline == nil: privacy = true
                case ("--only", "scan"), ("--only", "clean"): options.only = (options.only ?? []) + (try value())
                case ("--group", "scan"), ("--group", "clean"): options.groups = (options.groups ?? []) + (try value())
                case ("--require-fda", "scan") where inline == nil, ("--require-fda", "clean") where inline == nil:
                    requireAccess = true
                case ("--dry-run", "clean") where inline == nil: dryRun = true
                case ("--yes", "clean") where inline == nil, ("-y", "clean"): yes = true
                default:
                    throw UsageError(message: argument.hasPrefix("-") ? "unknown option `\(name)` for \(first)"
                                                                      : "unexpected argument `\(argument)`")
                }
            }
            options.privacy = privacy
            switch first {
            case "list": return .list(json: json, privacy: privacy)
            case "scan": return .scan(options, json: json, requireFullDiskAccess: requireAccess)
            default: return .clean(options, json: json, requireFullDiskAccess: requireAccess, dryRun: dryRun, yes: yes)
            }
        case "space", "large", "dupes", "similar":
            var json = false
            var space = HeadlessFiles.SpaceOptions(), large = HeadlessFiles.LargeOptions(), dupes = HeadlessFiles.DupesOptions()
            var similar = HeadlessFiles.SimilarOptions()
            while let argument = rest.popFirst() {
                let (name, inline) = split(argument)
                func value() throws -> String {
                    guard let text = inline ?? rest.popFirst(), !text.isEmpty, !text.hasPrefix("-") else {
                        throw UsageError(message: "\(name) needs a value")
                    }
                    return text
                }
                func number(minimum: Int) throws -> Int {
                    let text = try value()
                    guard let number = Int(text), number >= minimum else {
                        throw UsageError(message: "\(name) needs a whole number of at least \(minimum), not `\(text)`")
                    }
                    return number
                }
                switch (name, first) {
                case ("-h", _), ("--help", _): return .help
                case ("--json", _) where inline == nil: json = true
                case ("--limit", _):
                    let limit = try number(minimum: 1)
                    (space.limit, large.limit, dupes.limit, similar.limit) = (limit, limit, limit, limit)
                case ("--min-size", "large"), ("--min-size", "dupes"):
                    let text = try value()
                    guard let size = HeadlessFiles.parseSize(text) else {
                        throw UsageError(message: "--min-size needs a size like 100MB or 1.5GB, not `\(text)`")
                    }
                    (large.minSize, dupes.minSize) = (size, size)
                case ("--older-than", "large"): large.olderThanDays = try number(minimum: 1)
                case ("--in", "large"), ("--in", "dupes"):
                    guard large.root == nil else { throw UsageError(message: "--in takes one folder") }
                    large.root = try value()
                    dupes.root = large.root
                case (_, "space") where !argument.hasPrefix("-") && space.path == nil: space.path = argument
                case ("--in", "similar"): similar.roots.append(try value())
                case (_, "similar") where !argument.hasPrefix("-"): similar.roots.append(argument)
                default:
                    throw UsageError(message: argument.hasPrefix("-") ? "unknown option `\(name)` for \(first)"
                                                                      : "unexpected argument `\(argument)`")
                }
            }
            switch first {
            case "space": return .space(space, json: json)
            case "large": return .large(large, json: json)
            case "similar": return .similar(similar, json: json)
            default: return .dupes(dupes, json: json)
            }
        case "trash", "restore":
            var json = false, yes = false, list = false, limit: Int?, paths: [String] = []
            while let argument = rest.popFirst() {
                switch argument {
                case "--":
                    paths += rest
                    rest = []
                case "-h", "--help": return .help
                case "--json": json = true
                case "--yes" where first == "trash", "-y" where first == "trash": yes = true
                case "--list" where first == "restore": list = true
                case _ where first == "restore" && split(argument).0 == "--limit":
                    let text = split(argument).1 ?? rest.popFirst() ?? ""
                    guard let number = Int(text), number >= 1 else {
                        throw UsageError(message: "--limit needs a whole number of at least 1, not `\(text)`")
                    }
                    limit = number
                case _ where !argument.hasPrefix("-") || argument == "-": paths.append(argument)
                default: throw UsageError(message: "unknown option `\(split(argument).0)` for \(first)")
                }
            }
            if list || limit != nil {
                guard list else { throw UsageError(message: "--limit goes with restore --list") }
                guard paths.isEmpty else { throw UsageError(message: "restore --list takes no TRASHED paths") }
                return .restoreList(limit: limit ?? HeadlessTrash.listLimit, json: json)
            }
            guard !paths.isEmpty else {
                throw UsageError(message: first == "trash" ? "trash needs the PATH of each file or folder to move"
                                                           : "restore needs the TRASHED path of each item, as trash or restore --list printed it")
            }
            return first == "trash" ? .trash(paths: paths, json: json, yes: yes) : .restore(paths: paths, json: json)
        case "uninstall": return try parseUninstall(rest)
        case "privacy": return try parsePrivacy(rest)
        case "login-items": return try parseLoginItems(rest)
        default:
            throw UsageError(message: first.hasPrefix("-") ? "unknown option `\(first)`" : "unknown command `\(first)`")
        }
    }

    /// `--only=a,b` → ("--only", "a,b").
    static func split(_ argument: String) -> (String, String?) {
        guard argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
        return (String(argument[..<equals]), String(argument[argument.index(after: equals)...]))
    }

    static func message(_ error: HeadlessScan.OptionError) -> String {
        switch error {
        case .unknownItem(let id): "unknown item `\(id)` (see `cleanmate list`)"
        case .unknownGroup(let group): "unknown group `\(group)` (groups: \(HeadlessScan.groupNames.joined(separator: ", ")))"
        case .needsPrivacy(let name):
            name == "privacy" ? "the privacy group needs --privacy" : "`\(name)` is a Privacy item: add --privacy"
        }
    }

    // MARK: - Output

    static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) + "\n" }
    }

    static let groupTitles = ["system": "System Junk", "user": "Trash", "dev": "Developer Junk", "ai": "AI Tools",
                              "apps": "Applications", "privacy": "Privacy"]

    struct Style {
        let color: Bool
        func bold(_ text: String) -> String { color ? "\u{1B}[1m\(text)\u{1B}[0m" : text }
        func dim(_ text: String) -> String { color ? "\u{1B}[2m\(text)\u{1B}[0m" : text }
        func yellow(_ text: String) -> String { color ? "\u{1B}[33m\(text)\u{1B}[0m" : text }
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: bytes)
    }

    static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    static func listText(_ report: HeadlessScan.ListReport, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        var group: String?
        let width = min(36, report.items.map(\.id.count).max() ?? 0)
        for item in report.items {
            if item.group != group {
                text += (group == nil ? "" : "\n") + style.bold("\(groupTitles[item.group] ?? item.group) (\(item.group))") + "\n"
                group = item.group
            }
            let flags = [item.disposal == "trash" ? "moves to Trash" : nil, item.dataLoss ? dataLossFlag : nil,
                         item.needsFullDiskAccess ? "needs Full Disk Access" : nil].compactMap { $0 }
            text += "  \(item.selectedByDefault ? "[x]" : "[ ]") \(padded(item.id, width))  \(item.name)"
                + (flags.isEmpty ? "" : style.dim(" (\(flags.joined(separator: ", ")))")) + "\n"
            if !item.description.isEmpty { text += "      " + style.dim(item.description) + "\n" }
        }
        return text + "\n[x] = ticked by default\n"
    }

    /// Text flag of an item that may hold data (`HeadlessScan.dataLossIDs`).
    static let dataLossFlag = "may hold data: cleaned only with --only"

    static func scanText(_ report: HeadlessScan.Report, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        var group: String?
        let width = min(40, report.items.map(\.name.count).max() ?? 0)
        for item in report.items {
            if item.group != group {
                text += (group == nil ? "" : "\n") + style.bold(groupTitles[item.group] ?? item.group) + "\n"
                group = item.group
            }
            let amount = item.size == 0 && item.records != nil ? "\(item.records!) records"
                : (item.sizeIsUpperBound ? "up to " : "") + size(item.size)
            let mark = item.locked ? "[-]" : item.selectedByDefault ? "[x]" : "[ ]"
            text += "  \(mark) \(padded(item.name, width))  \(String(repeating: " ", count: max(0, 12 - amount.count)) + amount)"
            if let reason = item.reason { text += "  " + style.yellow(reason) }
            if item.dataLoss { text += "  " + style.dim("(\(dataLossFlag))") }
            text += "\n"
        }
        if report.items.isEmpty { text += "Nothing found.\n" }
        text += "\n" + style.bold("Ticked by default: \(size(report.total))")
            + (report.totalUpTo > 0 ? " (+ up to \(size(report.totalUpTo)))" : "") + "\n"
        text += style.dim("[x] ticked, [ ] not ticked, [-] locked. Nothing was deleted: clean in CleanMate.") + "\n"
        if let timing = timingText(report) { text += style.dim(timing) + "\n" }
        if !report.fullDiskAccess {
            text += style.yellow("Note: no Full Disk Access, so folders macOS protects were skipped (see `cleanmate --help`).") + "\n"
        }
        return text
    }

    /// "Scanned in 4.2 s; slowest: …" with the three slowest items (`--json`: `durationMs`); nil when not measured.
    static func timingText(_ report: HeadlessScan.Report) -> String? {
        guard let total = report.durationMs else { return nil }
        func seconds(_ ms: Int) -> String { String(format: "%.1f s", Double(ms) / 1000) }
        let slowest = report.items.compactMap { item in item.durationMs.map { (item.name, $0) } }
            .sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) \(seconds($0.1))" }
        return "Scanned in \(seconds(total))" + (slowest.isEmpty ? "." : "; slowest: " + slowest.joined(separator: ", ") + ".")
    }

    static func cleanText(_ report: HeadlessClean.Report, color: Bool) -> String {
        let style = Style(color: color)
        var text = report.dryRun ? style.bold("Dry run: nothing was deleted.") + "\n" : ""
        let width = min(40, report.items.map(\.name.count).max() ?? 0)
        for item in report.items {
            let what: String
            if item.locked {
                what = style.yellow("skipped: \(item.reason ?? "locked")")
            } else if item.freed == 0 && item.skipped.isEmpty {
                what = style.dim("nothing to clean")
            } else {
                let verb = report.dryRun ? (item.trashed > 0 ? "to move to the Trash" : "to delete")
                                         : (item.trashed > 0 ? "moved to the Trash" : "deleted")
                what = "\(size(item.freed)) \(verb)"
            }
            text += "  \(padded(item.name, width))  \(what)\n"
            let shown = item.locked ? [] : item.skipped
            for skipped in shown.prefix(5) { text += style.dim("      kept \(skipped.path): \(skipped.reason)") + "\n" }
            if shown.count > 5 { text += style.dim("      … \(shown.count - 5) more kept") + "\n" }
        }
        if report.items.isEmpty { text += "Nothing to clean.\n" }
        let total = (report.dryRun ? "Would free " : "Freed ") + size(report.freed)
            + (report.upTo > 0 ? " (up to \(size(report.upTo)) of it may stay shared)" : "")
            + (report.inTrash > 0 ? ", \(size(report.inTrash)) of it in the Trash until you empty it" : "") + "."
        text += "\n" + style.bold(total) + "\n"
        if let log = report.log {
            text += style.dim("Logged in \(log)." + (report.inTrash > 0 ? " Undo: `cleanmate restore --list`." : "")) + "\n"
        }
        return text
    }

    /// `~/…` for a path in the home folder, else the full path.
    static func shown(_ path: String, home: URL) -> String {
        HeadlessScan.displayPath(URL(fileURLWithPath: path), home: home)
    }

    static func rightAligned(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    static func spaceText(_ report: HeadlessFiles.SpaceReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = style.bold("\(shown(report.path, home: home))  \(size(report.size))") + "\n"
        for item in report.items {
            let name = item.name + (item.kind == "file" ? "" : "/")
            if item.skipped {
                text += "  \(rightAligned("–", 10))  \(name)  " + style.yellow("skipped: \(item.reason ?? HeadlessScan.needsAccess)") + "\n"
            } else if item.kind == "volume" {
                text += "  \(rightAligned("–", 10))  \(name)  " + style.dim("mounted volume, not counted") + "\n"
            } else {
                text += "  \(rightAligned(size(item.size ?? 0), 10))  \(name)\n"
            }
        }
        if report.items.isEmpty { text += "  Empty.\n" }
        if report.moreItems > 0 {
            text += style.dim("  … \(report.moreItems) more, \(size(report.moreSize))") + "\n"
        }
        text += skippedNote(report.skipped, home: home, style: style)
        return text + style.dim("Nothing was deleted. To move something to the Trash, use `cleanmate trash PATH…`.") + "\n"
    }

    static func largeText(_ report: HeadlessFiles.LargeReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        for file in report.files {
            let modified = (try? Date(file.modified, strategy: .iso8601)) ?? .distantPast
            let used = file.lastUsed.flatMap { try? Date($0, strategy: .iso8601) }.map { max($0, modified) } ?? modified
            text += "  \(rightAligned(size(file.size), 10))  \(shown(file.path, home: home))  "
                + style.dim("last used \(used.formatted(day))") + (file.hardLinked ? "  " + style.yellow("(hard link)") : "")
                + (file.icloud.map { "  " + style.dim($0 == ICloudStatus.uploaded.rawValue ? "(iCloud)" : "(iCloud, \($0))") } ?? "") + "\n"
        }
        if report.files.isEmpty { text += "No files found.\n" }
        if report.moreFiles > 0 { text += style.dim("  … \(report.moreFiles) more") + "\n" }
        let age = report.olderThanDays.map { ", not used for \($0) day\($0 == 1 ? "" : "s")" } ?? ""
        text += "\n" + style.bold("\(report.count) file\(report.count == 1 ? "" : "s"), \(size(report.size))")
            + " (\(size(report.minSize)) or larger\(age)) in \(shown(report.root, home: home))\n"
        if report.files.contains(where: \.hardLinked) {
            text += style.dim("(hard link): another link keeps the file on disk; moving this one frees nothing.") + "\n"
        }
        if report.files.contains(where: { $0.icloud == ICloudStatus.uploaded.rawValue }) {
            text += style.dim("(iCloud): in iCloud Drive; Remove Download in Large & Old Files frees it and keeps it in iCloud.") + "\n"
        }
        text += skippedNote(report.skipped, home: home, style: style)
        return text + style.dim("Nothing was deleted. To move files to the Trash, use `cleanmate trash PATH…`.") + "\n"
    }

    static func dupesText(_ report: HeadlessFiles.DupesReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        let day = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        for group in report.groups {
            text += style.bold("\(rightAligned(size(group.wasted), 10))  wasted: \(group.count) copies of \(size(group.size))") + "\n"
            for file in group.files {
                let modified = ((try? Date(file.modified, strategy: .iso8601)) ?? .distantPast).formatted(day)
                text += "              \(shown(file.path, home: home))  " + style.dim("modified \(modified)")
                    + (file.oldest ? "  " + style.dim("(oldest)") : "")
                    + (!file.oldest && file.freeable == 0 ? "  " + style.yellow("(frees nothing)") : "") + "\n"
            }
        }
        if report.groups.isEmpty { text += "No duplicates found.\n" }
        if report.moreGroups > 0 { text += style.dim("  … \(report.moreGroups) more groups") + "\n" }
        text += "\n" + style.bold("\(report.count) group\(report.count == 1 ? "" : "s"), \(size(report.wasted)) wasted")
            + " (files of \(size(report.minSize)) or larger) in \(shown(report.root, home: home))\n"
        text += skippedNote(report.skipped, home: home, style: style)
        return text + style.dim("Nothing was deleted. To move copies to the Trash, use `cleanmate trash PATH…`.") + "\n"
    }

    static func similarText(_ report: HeadlessFiles.SimilarReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        for group in report.groups {
            text += style.bold("\(rightAligned(size(group.freeable), 10))  to free: \(group.count) similar photos") + "\n"
            for photo in group.photos {
                let pixels = photo.width > 0 && photo.height > 0 ? "\(photo.width)×\(photo.height), " : ""
                text += "              \(shown(photo.path, home: home))  " + style.dim("\(pixels)\(size(photo.size))")
                    + (photo.suggested ? "  " + style.dim("(suggested to keep)") : "") + "\n"
            }
        }
        if report.groups.isEmpty { text += "No similar photos found.\n" }
        if report.moreGroups > 0 { text += style.dim("  … \(report.moreGroups) more groups") + "\n" }
        let roots = report.roots.map { shown($0, home: home) }.joined(separator: ", ")
        text += "\n" + style.bold("\(report.count) group\(report.count == 1 ? "" : "s"), \(size(report.freeable)) to free")
            + " (\(report.photos) photo\(report.photos == 1 ? "" : "s") of \(size(report.minSize)) or larger compared) in \(roots)\n"
        text += skippedNote(report.skipped, home: home, style: style)
        return text + style.dim("Nothing was moved. To move the photos you pick to the Trash, use `cleanmate trash PATH…`; "
                                + "`cleanmate restore` puts them back.") + "\n"
    }

    static func trashText(_ report: HeadlessTrash.TrashReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        for item in report.items {
            let path = shown(item.path, home: home)
            if let reason = item.reason, item.skipped {
                text += "  \(rightAligned("–", 10))  \(path)  " + style.yellow("skipped: \(reason)") + "\n"
            } else {
                text += "  \(rightAligned(size(item.size ?? 0), 10))  \(path)"
                    + (item.trashed.map { "  " + style.dim("→ \(shown($0, home: home))") } ?? "") + "\n"
            }
        }
        text += "\n" + style.bold("Moved \(report.count) item\(report.count == 1 ? "" : "s"), \(size(report.size)), to the Trash")
            + " (on disk until you empty the Trash).\n"
        let trashed = report.items.compactMap(\.trashed)
        if !trashed.isEmpty {
            text += style.dim("Logged in \(report.log). Undo: cleanmate restore " + trashed.map(quoted).joined(separator: " ")) + "\n"
        }
        return text
    }

    static func restoreText(_ report: HeadlessTrash.RestoreReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        for item in report.items {
            let path = shown(item.path ?? item.trashed, home: home)
            if item.skipped {
                text += "  \(shown(item.trashed, home: home))  " + style.yellow("skipped: \(item.reason ?? "")") + "\n"
            } else {
                text += "  \(path)  " + style.dim("put back") + "\n"
            }
        }
        text += "\n" + style.bold("Put back \(report.count) item\(report.count == 1 ? "" : "s").") + "\n"
        if report.count > 0 { text += style.dim("Logged in \(report.log).") + "\n" }
        return text
    }

    static func restoreListText(_ report: HeadlessTrash.ListReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        let when = DateFormatter()
        when.locale = Locale(identifier: "en_US_POSIX")
        when.dateFormat = "yyyy-MM-dd HH:mm"
        for item in report.items {
            let date = item.date.flatMap { try? Date($0, strategy: .iso8601) }.map(when.string)
                ?? "–".padding(toLength: 16, withPad: " ", startingAt: 0)
            text += "  \(date)  \(rightAligned(size(item.size), 10))  \(shown(item.path, home: home))  "
                + style.dim("\(item.source) → \(shown(item.trashed, home: home))") + "\n"
        }
        if report.items.isEmpty { return "Nothing CleanMate moved to the Trash is still there.\n" }
        return text + "\n" + style.dim("Put back: cleanmate restore TRASHED… (the path after →)") + "\n"
    }

    /// `path` quoted for a shell when it needs it.
    static func quoted(_ path: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%~")
        guard path.unicodeScalars.contains(where: { !plain.contains($0) }) || path.isEmpty else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func skippedNote(_ skipped: [HeadlessFiles.Skipped], home: URL, style: Style) -> String {
        guard !skipped.isEmpty else { return "" }
        return style.yellow("Note: no Full Disk Access, so these folders were not read: "
                            + skipped.map { shown($0.path, home: home) }.joined(separator: ", ") + " (see `cleanmate --help`).") + "\n"
    }
}
