import Foundation

/// `cleanmate uninstall`, `cleanmate privacy` and `cleanmate login-items`: the Uninstaller, Privacy and Login Items
/// modules on the command line, with the app's engine and safety rules (`HeadlessApps`, `HeadlessClean`,
/// `HeadlessLoginItems`).
nonisolated extension CommandLineTool {
    // MARK: - Parsing

    static func parseUninstall(_ arguments: ArraySlice<String>) throws -> Command {
        var rest = arguments
        var json = false, leftovers = false, leftoversOnly = false, quit = false, dryRun = false, yes = false
        var words: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--":
                words += rest
                rest = []
            case "-h", "--help": return .help
            case "--json": json = true
            case "--leftovers": leftovers = true
            case "--leftovers-only": leftoversOnly = true
            case "--quit": quit = true
            case "--dry-run": dryRun = true
            case "--yes", "-y": yes = true
            case _ where !argument.hasPrefix("-"): words.append(argument)
            default: throw UsageError(message: "unknown option `\(split(argument).0)` for uninstall")
            }
        }
        if leftovers {
            guard !leftoversOnly, !quit else { throw UsageError(message: "--leftovers takes no app: it lists or removes the data of removed apps") }
            if words.isEmpty {
                guard !dryRun, !yes else { throw UsageError(message: "uninstall --leftovers needs the PATH of each leftover to move") }
                return .uninstallList(leftoversOnly: true, json: json)
            }
            return .removeLeftovers(paths: words, dryRun: dryRun, yes: yes, json: json)
        }
        if words.isEmpty {
            guard !leftoversOnly, !quit, !dryRun, !yes else {
                throw UsageError(message: "uninstall needs the app: its name, bundle id or path (see `cleanmate uninstall`)")
            }
            return .uninstallList(leftoversOnly: false, json: json)
        }
        // An unquoted name with spaces (`Visual Studio Code`) arrives as several words.
        let options = HeadlessApps.Options(app: words.joined(separator: " "), leftoversOnly: leftoversOnly, quit: quit,
                                           dryRun: dryRun, yes: yes)
        return .uninstall(options, json: json)
    }

    static func parsePrivacy(_ arguments: ArraySlice<String>) throws -> Command {
        var json = false, erase = false, dryRun = false, yes = false
        var ids: [String] = []
        for argument in arguments {
            switch argument {
            case "-h", "--help": return .help
            case "--json": json = true
            case "--erase": erase = true
            case "--dry-run": dryRun = true
            case "--yes", "-y": yes = true
            case _ where !argument.hasPrefix("-"):
                ids += argument.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: throw UsageError(message: "unknown option `\(split(argument).0)` for privacy")
            }
        }
        guard erase else {
            if dryRun || yes { throw UsageError(message: "\(dryRun ? "--dry-run" : "--yes") goes with privacy --erase") }
            if let id = ids.first { throw UsageError(message: "unexpected argument `\(id)`: erase items with privacy --erase ID…") }
            return .privacy(json: json)
        }
        return .privacyErase(ids: ids, dryRun: dryRun, yes: yes, json: json)
    }

    static func parseLoginItems(_ arguments: ArraySlice<String>) throws -> Command {
        var json = false, yes = false
        var words: [String] = []
        var rest = arguments
        while let argument = rest.popFirst() {
            switch argument {
            case "--":
                words += rest
                rest = []
            case "-h", "--help": return .help
            case "--json": json = true
            case "--yes", "-y": yes = true
            case _ where !argument.hasPrefix("-"): words.append(argument)
            default: throw UsageError(message: "unknown option `\(split(argument).0)` for login-items")
            }
        }
        guard let action = words.first else {
            if yes { throw UsageError(message: "--yes goes with login-items remove") }
            return .loginItems(json: json)
        }
        guard ["remove", "restore", "list"].contains(action) else {
            throw UsageError(message: "unknown login-items action `\(action)` (list, remove LABEL, restore LABEL)")
        }
        if action == "list" {
            guard words.count == 1, !yes else { throw UsageError(message: "login-items list takes no LABEL") }
            return .loginItems(json: json)
        }
        guard words.count == 2 else { throw UsageError(message: "login-items \(action) needs one LABEL (see `cleanmate login-items`)") }
        if action == "restore" {
            guard !yes else { throw UsageError(message: "--yes goes with login-items remove") }
            return .loginItemRestore(label: words[1], json: json)
        }
        return .loginItemRemove(label: words[1], yes: yes, json: json)
    }

    // MARK: - Running

    /// Asks on stderr; true only for "y" or "yes".
    static func confirmed(_ question: String, output: Output) -> Bool {
        output.err(question)
        let answer = output.readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    static func emit(_ value: some Encodable, json: Bool, output: Output, text: () -> String) -> Int32? {
        guard let printed = json ? encode(value) : text() else { return Exit.failure.rawValue }
        output.out(printed)
        return nil
    }

    static func uninstallList(leftoversOnly: Bool, json: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Measuring apps…") }
        let report = await HeadlessApps.list(leftoversOnly: leftoversOnly, sources: sources)
        if showsProgress { output.err("\r\u{1B}[K") }
        return emit(report, json: json, output: output) {
            appsText(report, leftoversOnly: leftoversOnly, home: sources.policy().homeURL, color: output.color)
        } ?? Exit.ok.rawValue
    }

    static func uninstall(_ options: HeadlessApps.Options, json: Bool, sources: HeadlessScan.Sources,
                          output: Output) async -> Int32 {
        let started = ContinuousClock.now
        let asks = !options.dryRun && !options.yes
        if asks && !output.interactive {
            output.err("cleanmate: nothing was moved. Without a terminal, uninstall needs --yes: check what goes with "
                       + "`cleanmate uninstall --dry-run \(quoted(options.app))`, then run it with --yes once the user confirmed.\n")
            return Exit.notConfirmed.rawValue
        }
        let policy = sources.policy()
        let apps = await sources.installedApps(policy)
        let app: InstalledApp
        switch HeadlessApps.find(options.app, in: apps, home: policy.homeURL) {
        case .found(let found): app = found
        case .notFound(let similar):
            output.err("cleanmate: no app `\(options.app)` that CleanMate can uninstall"
                       + (similar.isEmpty ? "" : " (did you mean: \(similar.joined(separator: ", "))?)")
                       + ". Run `cleanmate uninstall` for the list; Apple's apps are never listed.\n")
            return Exit.usage.rawValue
        case .ambiguous(let found):
            output.err("cleanmate: `\(options.app)` names \(found.count) apps: "
                       + found.map { "\($0.bundleID) (\(shown($0.url.path, home: policy.homeURL)))" }.joined(separator: ", ")
                       + ". Name one by its bundle id or path.\n")
            return Exit.usage.rawValue
        }
        let isOpen: @Sendable () -> Bool = { sources.runningApps()[app.bundleID] != nil }
        if isOpen() && !options.dryRun {
            guard options.quit else {
                output.err("cleanmate: " + HeadlessApps.runningMessage(app.name) + "\n")
                return Exit.appRunning.rawValue
            }
            if !(await quit(app, isOpen: isOpen, sources: sources)) {
                output.err("cleanmate: \(app.name) did not quit: it may be waiting for you to save a document or answer a "
                           + "question. Switch to it, quit it, then try again. Nothing was moved.\n")
                return Exit.appRunning.rawValue
            }
        }
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Finding \(app.name)’s data…") }
        let plan = await HeadlessApps.plan(app, among: apps, leftoversOnly: options.leftoversOnly, sources: sources)
        if showsProgress { output.err("\r\u{1B}[K") }
        let home = policy.homeURL
        let appPart = options.leftoversOnly ? nil : (url: app.url, size: plan.appSize)
        if asks {
            guard plan.count > 0 else {
                output.err("Nothing of \(app.name) to move.\n")
                return Exit.ok.rawValue
            }
            guard confirmed(uninstallConfirmation(plan, home: home), output: output) else {
                output.err("Nothing was moved.\n")
                return Exit.ok.rawValue
            }
        }
        let moved: CleanReport?
        if options.dryRun {
            moved = nil
        } else {
            do {
                moved = try await HeadlessApps.uninstall(plan, sources: sources)
            } catch {
                let failure = HeadlessApps.failure(error, app: app, running: isOpen())
                output.err("cleanmate: " + failure.message + "\n")
                return failure.isRunning ? Exit.appRunning.rawValue : Exit.failure.rawValue
            }
        }
        let report = HeadlessApps.report(app: appPart, data: plan.data, summary: plan.summary, notTaken: plan.notTaken,
                                         moved: moved, started: started, sources: sources)
        return emit(report, json: json, output: output) { uninstallText(report, home: home, color: output.color) }
            ?? Exit.ok.rawValue
    }

    /// Asks the app to quit, then reads the running apps every 200 ms until it is gone or `quitTimeout` passes.
    static func quit(_ app: InstalledApp, isOpen: @Sendable () -> Bool, sources: HeadlessScan.Sources) async -> Bool {
        sources.quitApp(app.bundleID)
        let deadline = ContinuousClock.now + sources.quitTimeout
        while isOpen() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    static func removeLeftovers(_ paths: [String], dryRun: Bool, yes: Bool, json: Bool, sources: HeadlessScan.Sources,
                                output: Output) async -> Int32 {
        let started = ContinuousClock.now
        let asks = !dryRun && !yes
        if asks && !output.interactive {
            output.err("cleanmate: nothing was moved. Without a terminal, uninstall --leftovers needs --yes: run it only "
                       + "with the paths the user confirmed, as `cleanmate uninstall --leftovers --yes PATH…`.\n")
            return Exit.notConfirmed.rawValue
        }
        let home = sources.policy().homeURL
        let (picked, refused) = await HeadlessApps.pickLeftovers(paths, sources: sources)
        if asks && !picked.isEmpty {
            let total = picked.reduce(Int64(0)) { $0 + $1.size }
            var question = "About to move \(picked.count) leftover\(picked.count == 1 ? "" : "s") (\(size(total))) of removed apps to the Trash:\n"
            for entry in picked { question += "  \(rightAligned(size(entry.size), 10))  \(shown(entry.url.path, home: home))\n" }
            for item in refused { question += "  \(rightAligned("–", 10))  \(item.path)  skipped: \(item.reason ?? "")\n" }
            guard confirmed(question + "Undo afterwards with `cleanmate restore`.\nProceed? [y/N] ", output: output) else {
                output.err("Nothing was moved.\n")
                return Exit.ok.rawValue
            }
        }
        var moved: CleanReport?
        var failure: Failure?
        if !dryRun && !picked.isEmpty {
            do {
                moved = try await Uninstaller.trash(app: nil, data: picked, policy: sources.policy(),
                                                    launchctl: sources.launchctl, moveToTrash: sources.trash)
            } catch {
                moved = CleanReport()
                failure = Failure(code: error == .cancelled ? "cancelled" : "failed",
                                  message: leftoversFailure(error))
            }
        } else if !dryRun {
            moved = CleanReport()
        }
        var report = HeadlessApps.report(app: nil, data: picked, summary: nil, notTaken: [], moved: moved, started: started,
                                         sources: sources)
        if failure == nil, !picked.isEmpty, let moved, moved.trashed.isEmpty, moved.notCleaned > 0 {
            let reasons = Set(report.items.compactMap(\.reason)).sorted().joined(separator: "; ")
            failure = Failure(code: "failed", message: "none of the leftovers could be moved to the Trash (\(reasons))")
        }
        report.items += refused
        report.error = failure
        if let failure { output.err("cleanmate uninstall: \(failure.message). Nothing was moved.\n") }
        return emit(report, json: json, output: output) { uninstallText(report, home: home, color: output.color) }
            ?? (failure == nil ? Exit.ok : Exit.failure).rawValue
    }

    /// Why `Uninstaller.trash` refused the leftovers, as the app tells it.
    static func leftoversFailure(_ error: Uninstaller.AppTrashError) -> String {
        switch error {
        case .locked: "an item is locked in Finder: select it, choose File > Get Info, turn off Locked, then try again"
        case .brewBusy: "a brew command is running now: wait until it finishes, then try again"
        case .appStore: "macOS only lets you remove App Store items yourself: drag them to the Trash in Finder"
        case .cancelled: "the move was cancelled"
        case .notTrashed: "the leftovers couldn’t be moved to the Trash: they may belong to the system or another user"
        }
    }

    /// The question asked on a terminal before `uninstall APP` moves anything.
    static func uninstallConfirmation(_ plan: HeadlessApps.Plan, home: URL) -> String {
        var text = plan.leftoversOnly
            ? "About to move \(plan.app.name)’s data (\(size(plan.size)), \(plan.data.count) item\(plan.data.count == 1 ? "" : "s")) to the Trash; the app stays:\n"
            : "About to uninstall \(plan.app.name) (\(size(plan.size)) with its data) to the Trash:\n"
        if !plan.leftoversOnly { text += "  \(rightAligned(size(plan.appSize), 10))  \(shown(plan.app.url.path, home: home))\n" }
        for entry in plan.data { text += "  \(rightAligned(size(entry.size), 10))  \(shown(entry.url.path, home: home))\n" }
        if !plan.notTaken.isEmpty {
            text += "Left in place (may be another app’s; check them in CleanMate): "
                + plan.notTaken.map { shown($0.url.path, home: home) }.joined(separator: ", ") + "\n"
        }
        return text + "Undo afterwards with `cleanmate restore`.\nProceed? [y/N] "
    }

    static func privacy(json: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Scanning…") }
        let report = await HeadlessPrivacy.list(sources: sources)
        if showsProgress { output.err("\r\u{1B}[K") }
        return emit(report, json: json, output: output) { privacyText(report, color: output.color) } ?? Exit.ok.rawValue
    }

    static func privacyErase(ids: [String], dryRun: Bool, yes: Bool, json: Bool, sources: HeadlessScan.Sources,
                             output: Output) async -> Int32 {
        let started = ContinuousClock.now
        let known = Set(sources.privacy().flatMap(\.items).map(\.id))
        if let unknown = ids.first(where: { !known.contains($0) }) {
            output.err("cleanmate: `\(unknown)` is not a Privacy item (see `cleanmate privacy`)\nRun `cleanmate --help` for usage.\n")
            return Exit.usage.rawValue
        }
        let asks = !dryRun && !yes
        if asks && !output.interactive {
            output.err("cleanmate: nothing was erased. Without a terminal, privacy --erase needs --yes: check the items with "
                       + "`cleanmate privacy`, then run `cleanmate privacy --erase --yes ID…` with the ids the user confirmed.\n")
            return Exit.notConfirmed.rawValue
        }
        let showsProgress = output.progress && !json
        if showsProgress { output.err("Scanning…") }
        let options = HeadlessScan.Options(only: ids.isEmpty ? nil : ids, groups: ["privacy"], privacy: true)
        let plan = await HeadlessClean.plan(options, sources: sources)
        if showsProgress { output.err("\r\u{1B}[K") }
        let signsOut = plan.cleanable.contains { HeadlessPrivacy.signsOut($0.report.id) }
        if asks && !plan.cleanable.isEmpty {
            guard confirmed(privacyConfirmation(plan, signsOut: signsOut), output: output) else {
                output.err("Nothing was erased.\n")
                return Exit.ok.rawValue
            }
        } else if signsOut && !dryRun && !json {
            output.err("Note: \(HeadlessPrivacy.cookieWarning)\n")
        }
        var report = await HeadlessClean.clean(plan, dryRun: dryRun, sources: sources)
        report.durationMs = HeadlessScan.milliseconds(ContinuousClock.now - started)
        return emit(report, json: json, output: output) { cleanText(report, color: output.color) } ?? Exit.ok.rawValue
    }

    /// The question asked on a terminal before `privacy --erase`, with the app's warning about cookies.
    static func privacyConfirmation(_ plan: HeadlessClean.Plan, signsOut: Bool) -> String {
        let count = plan.cleanable.count
        let total = plan.cleanable.reduce(Int64(0)) { $0 + $1.report.size }
        var text = "About to erase \(count) item\(count == 1 ? "" : "s") (\(size(total))), deleted permanently: it can’t be put back.\n"
        for target in plan.cleanable {
            let amount = target.report.size == 0 && target.report.records != nil ? "\(target.report.records!) records"
                : size(target.report.size)
            text += "  \(target.report.id)  \(target.report.name)  \(amount)\n"
        }
        for target in plan.targets where target.report.locked {
            text += "  \(target.report.id)  skipped: \(target.report.reason ?? "locked")\n"
        }
        if signsOut { text += HeadlessPrivacy.cookieWarning + "\n" }
        return text + "Proceed? [y/N] "
    }

    static func loginItems(json: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        let report = await HeadlessLoginItems.list(sources: sources)
        return emit(report, json: json, output: output) { loginItemsText(report, color: output.color) } ?? Exit.ok.rawValue
    }

    static func loginItemRemove(label: String, yes: Bool, json: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        if !yes && !output.interactive {
            output.err("cleanmate: nothing was moved. Without a terminal, login-items remove needs --yes: run it only with "
                       + "the label the user confirmed, as `cleanmate login-items remove --yes \(quoted(label))`.\n")
            return Exit.notConfirmed.rawValue
        }
        let home = sources.policy().homeURL
        let agent: LaunchAgent
        switch await HeadlessLoginItems.find(label, sources: sources) {
        case .found(let found): agent = found
        case .notFound:
            output.err("cleanmate: no login item `\(label)` (see `cleanmate login-items`)\n")
            return Exit.usage.rawValue
        case .notRemovable(let found):
            output.err("cleanmate: `\(found.label)` (\(shown(found.url.path, home: home))) is "
                       + (found.isUser ? "one CleanMate keeps" : "the system’s: changing it needs an administrator")
                       + ". Nothing was moved.\n")
            return Exit.failure.rawValue
        }
        if !yes {
            let question = "About to move the login item \(agent.label) to the Trash and stop it:\n  "
                + shown(agent.url.path, home: home) + (agent.program.map { "\n  runs \($0)" } ?? "")
                + "\nUndo afterwards with `cleanmate login-items restore \(quoted(agent.label))`.\nProceed? [y/N] "
            guard confirmed(question, output: output) else {
                output.err("Nothing was moved.\n")
                return Exit.ok.rawValue
            }
        }
        let report = await HeadlessLoginItems.remove(agent, sources: sources)
        if let code = emit(report, json: json, output: output, text: { loginItemText(report, home: home, color: output.color) }) {
            return code
        }
        return report.skipped ? Exit.failure.rawValue : Exit.ok.rawValue
    }

    static func loginItemRestore(label: String, json: Bool, sources: HeadlessScan.Sources, output: Output) async -> Int32 {
        let home = sources.policy().homeURL
        guard let report = await HeadlessLoginItems.restore(label, sources: sources) else {
            output.err("cleanmate: no login item `\(label)` that CleanMate moved is in the Trash (see `cleanmate restore --list`)\n")
            return Exit.failure.rawValue
        }
        if let code = emit(report, json: json, output: output, text: { loginItemText(report, home: home, color: output.color) }) {
            return code
        }
        return report.skipped ? Exit.failure.rawValue : Exit.ok.rawValue
    }

    // MARK: - Text

    static func appsText(_ report: HeadlessApps.ListReport, leftoversOnly: Bool, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        let when = DateFormatter()
        when.locale = Locale(identifier: "en_US_POSIX")
        when.dateFormat = "yyyy-MM-dd"
        if !leftoversOnly {
            let sources = ["appStore": "App Store", "homebrew": "Homebrew", "setapp": "Setapp", "downloaded": "Downloaded"]
            let width = min(30, report.apps.map(\.name.count).max() ?? 0)
            let idWidth = min(40, report.apps.map(\.bundleId.count).max() ?? 0)
            text += style.bold("Apps (\(report.apps.count))") + "\n"
            text += style.dim("  \(padded("Name", width))  \(padded("Bundle id", idWidth))  \(padded("Source", 10))  "
                              + "\(rightAligned("App", 9))  \(rightAligned("Data", 9))  Last used") + "\n"
            for app in report.apps {
                let used = app.lastUsed.flatMap { try? Date($0, strategy: .iso8601) }.map(when.string).map {
                    app.lastUsedIsEstimate ? "~" + $0 : $0
                } ?? "–"
                text += "  \(padded(app.name, width))  \(padded(app.bundleId, idWidth))  \(padded(sources[app.source] ?? app.source, 10))  "
                    + "\(rightAligned(size(app.size), 9))  \(rightAligned(size(app.dataSize), 9))  \(used)"
                    + (app.running ? "  " + style.yellow("open") : "") + "\n"
            }
            if report.apps.isEmpty { text += "  No apps found.\n" }
            text += "\n"
        }
        text += style.bold("Leftovers of removed apps (\(size(report.leftoversSize)))") + "\n"
        for item in report.leftovers {
            text += "  \(rightAligned(size(item.size), 10))  \(item.path)" + (item.kind == "config" ? style.dim("  (config)") : "") + "\n"
        }
        if report.leftovers.isEmpty { text += "  None.\n" }
        text += "\n" + style.dim(leftoversOnly
            ? "Move them to the Trash: cleanmate uninstall --leftovers PATH… (check each first: a config folder may be a tool's)."
            : "Uninstall: cleanmate uninstall NAME|BUNDLE-ID (--dry-run first). ~ = estimated from the app's data.") + "\n"
        if !report.fullDiskAccess {
            text += style.yellow("Note: no Full Disk Access, so the data in folders macOS protects was not counted "
                                 + "(see `cleanmate --help`).") + "\n"
        }
        return text
    }

    static func uninstallText(_ report: HeadlessApps.UninstallReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        var text = report.dryRun ? style.bold("Dry run: nothing was moved.") + "\n" : ""
        for item in report.items {
            if item.skipped {
                text += "  \(rightAligned("–", 10))  \(item.path)  " + style.yellow("skipped: \(item.reason ?? "")") + "\n"
            } else {
                text += "  \(rightAligned(size(item.size), 10))  \(item.path)"
                    + (item.trashed.map { "  " + style.dim("→ \(shown($0, home: home))") } ?? "") + "\n"
            }
        }
        if !report.notRemoved.isEmpty {
            text += style.dim("Left in place (may be another app’s; check them in CleanMate): "
                              + report.notRemoved.map(\.path).joined(separator: ", ")) + "\n"
        }
        for cask in report.casksLeft {
            text += style.yellow("Homebrew still lists \(cask): run `brew uninstall --cask \(cask)`.") + "\n"
        }
        let verb = report.dryRun ? "Would move" : "Moved"
        text += "\n" + style.bold("\(verb) \(report.count) item\(report.count == 1 ? "" : "s"), \(size(report.size)), to the Trash")
            + (report.dryRun ? "." : " (on disk until you empty the Trash).") + "\n"
        let trashed = report.items.compactMap(\.trashed)
        if let log = report.log, !trashed.isEmpty {
            text += style.dim("Logged in \(log). Undo: cleanmate restore " + trashed.map(quoted).joined(separator: " ")) + "\n"
        }
        return text
    }

    static func privacyText(_ report: HeadlessPrivacy.Report, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        var browser: String?
        let width = min(36, report.items.map(\.id.count).max() ?? 0)
        for item in report.items {
            if item.browser != browser {
                text += (browser == nil ? "" : "\n") + style.bold(item.browser) + "\n"
                browser = item.browser
            }
            let amount = item.size == 0 && item.records != nil ? "\(item.records!) records" : size(item.size)
            let mark = item.skipped ? "[-]" : item.selectedByDefault ? "[x]" : "[ ]"
            text += "  \(mark) \(padded(item.id, width))  \(rightAligned(amount, 12))  \(item.name)"
            if let reason = item.reason, item.skipped { text += "  " + style.yellow("skipped: \(reason)") }
            if item.signsOut { text += "  " + style.dim("(signs you out of websites)") }
            text += "\n"
        }
        if report.items.isEmpty { text += "Nothing found.\n" }
        text += "\n" + style.bold("Ticked by default: \(size(report.total))") + "\n"
        text += style.dim("[x] ticked, [ ] not ticked, [-] skipped. Nothing was erased: cleanmate privacy --erase ID…") + "\n"
        if !report.fullDiskAccess {
            text += style.yellow("Note: no Full Disk Access, so Safari and other protected traces were skipped (see `cleanmate --help`).") + "\n"
        }
        return text
    }

    static func loginItemsText(_ report: HeadlessLoginItems.ListReport, color: Bool) -> String {
        let style = Style(color: color)
        var text = ""
        let titles = ["user": "Your login items (~/Library/LaunchAgents)", "system-agent": "System agents (/Library/LaunchAgents)",
                      "system-daemon": "System daemons (/Library/LaunchDaemons)"]
        var scope: String?
        let width = min(50, report.items.map(\.label.count).max() ?? 0)
        for item in report.items {
            if item.scope != scope {
                text += (scope == nil ? "" : "\n") + style.bold(titles[item.scope] ?? item.scope) + "\n"
                scope = item.scope
            }
            let state = item.pid.map { "running (pid \($0))" } ?? item.state.replacingOccurrences(of: "-", with: " ")
            text += "  \(padded(item.label, width))  \(padded(state, 18))"
            if let program = item.program {
                text += "  " + style.dim(program) + (item.programMissing ? "  " + style.yellow("program missing") : "")
            }
            text += "\n"
        }
        if report.items.isEmpty { text += "No login items found.\n" }
        return text + "\n" + style.dim("Remove one of yours: cleanmate login-items remove LABEL (to the Trash; "
                                       + "cleanmate login-items restore LABEL puts it back).") + "\n"
    }

    static func loginItemText(_ report: HeadlessLoginItems.ActionReport, home: URL, color: Bool) -> String {
        let style = Style(color: color)
        if report.skipped {
            return "  \(report.label)  " + style.yellow("skipped: \(report.reason ?? "")") + "\n"
        }
        if report.action == "restore" {
            return "  \(report.path ?? report.label)  " + style.dim("put back") + "\n\n"
                + style.dim("Logged in \(report.log).") + "\n"
        }
        return "  \(report.path ?? report.label)" + (report.trashed.map { "  " + style.dim("→ \(shown($0, home: home))") } ?? "")
            + "\n\n" + style.bold("Moved \(report.label) to the Trash and stopped it.") + "\n"
            + style.dim("Logged in \(report.log). Undo: cleanmate login-items restore \(quoted(report.label))") + "\n"
    }
}
