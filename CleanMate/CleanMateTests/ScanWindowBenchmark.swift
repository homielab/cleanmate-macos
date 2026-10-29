import AppKit
import Darwin
import SwiftUI
import Testing
@testable import CleanMate

/// Smart Scan and Large & Old Files scanned by their models with the main window on screen, as when the user starts
/// them: wall time, CPU of the whole process and of the main thread (where the models and SwiftUI's redraws run).
/// Part of `ScanBenchmark` (`CLEANMATE_BENCH=1`, real home, only scans); one warm-up, then `CLEANMATE_BENCH_RUNS`
/// (default 3) timed runs, each in a new window:
///   TEST_RUNNER_CLEANMATE_BENCH=1 xcodebuild … test -only-testing:'CleanMateTests/ScanBenchmark/smartScanWindow()'
/// Prints `BENCH window <module> run <n> wall …s cpu …s main …s` and the medians.
extension ScanBenchmark {
    struct Usage { var wall, process, main: Double }

    /// User + system seconds of the whole process.
    static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// User + system seconds of the calling thread: the main thread from `@MainActor` code.
    static func threadCPU() -> Double {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        func seconds(_ time: time_value_t) -> Double { Double(time.seconds) + Double(time.microseconds) / 1e6 }
        return seconds(info.user_time) + seconds(info.system_time)
    }

    /// Opens `view(model)` in a window and times `scan(model)`; preferences go to a throwaway defaults domain.
    @MainActor
    func windowed<Model>(_ label: String, model make: (UserDefaults) -> Model, view: (Model) -> ContentView,
                         scan: (Model) async -> Void) async {
        let runs = ProcessInfo.processInfo.environment["CLEANMATE_BENCH_RUNS"].flatMap(Int.init) ?? 3
        let suite = "CleanMateBenchWindow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var usages: [Usage] = []
        for run in 0...runs {
            let model = make(defaults)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 600), styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view(model).defaultAppStorage(defaults))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(500)) // first layout and onAppear
            let (start, process, main) = (ContinuousClock.now, Self.processCPU(), Self.threadCPU())
            await Attention.$isActive.withValue({ true }) { await scan(model) }
            let usage = Usage(wall: (ContinuousClock.now - start) / .seconds(1), process: Self.processCPU() - process,
                              main: Self.threadCPU() - main)
            window.close()
            print("BENCH window \(label) \(run == 0 ? "warm-up" : "run \(run)") " + Self.format(usage))
            if run > 0 { usages.append(usage) }
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print("BENCH window \(label) median " + Self.format(Usage(wall: median(usages.map(\.wall)),
                                                                process: median(usages.map(\.process)),
                                                                main: median(usages.map(\.main)))))
    }

    static func format(_ usage: Usage) -> String {
        String(format: "wall %.2fs cpu %.2fs main %.2fs", usage.wall, usage.process, usage.main)
    }

    /// The Smart Scan catalog as Settings shape it; scan times are not stored (no durations key).
    @MainActor @Test func smartScanWindow() async {
        await windowed("smart-scan", model: { _ in SmartScanModel(module: .smartScan) { CleanerGroup.smartScan } },
                       view: { ContentView(smartScan: $0, selection: .smartScan) }) { await $0.scan() }
    }

    /// The bench root (home by default) at the default 50 MB; entry counts kept across runs like the app does.
    @MainActor @Test func largeFilesWindow() async {
        guard mayRead("large-files window \(root.path)", root) else { return }
        let root = root
        await windowed("large-files", model: { defaults in
            let model = LargeFilesModel()
            model.lastCountDefaults = defaults
            return model
        }, view: { ContentView(largeFiles: $0, selection: .largeFiles) }) { model in
            guard model.setScope(root) else { return }
            while case .scanning = model.phase { try? await Task.sleep(for: .milliseconds(20)) }
        }
    }
}
