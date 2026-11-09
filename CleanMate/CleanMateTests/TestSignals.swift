import AppKit
import Combine
import Foundation
import Testing
@testable import CleanMate

// Waiting on what the code under test signals, never on the clock: a wait of N seconds fails on a busy Mac and
// slows every run on an idle one. A signal that never comes hangs the test; give such tests a `.timeLimit`.

/// A wait in a test that ran out of time (`eventually`); the issue is already recorded.
struct WaitTimedOut: Error {}

/// Returns once `condition` holds, checked every 5 ms (for state no publisher announces, or a fake's counter). After
/// `timeout` it records an issue naming `what` at the caller's line and throws, so a state that never comes fails the
/// test instead of hanging the whole suite. 30 s, not less: a passing wait returns at once, and with another
/// project's build loading the Mac a model took over 5 s to load and failed the run.
@MainActor func eventually(_ what: String, timeout: Duration = .seconds(30), every interval: Duration = .milliseconds(5),
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Still waiting after \(timeout): \(what)", sourceLocation: sourceLocation)
            throw WaitTimedOut()
        }
        try await pause(interval)
    }
}

/// The same wait for a condition that itself awaits (a cache file read, a process poll): checked now, then
/// every `interval`, with the same timeout and issue as the synchronous `eventually`.
nonisolated func eventually(_ what: String, timeout: Duration = .seconds(30), every interval: Duration = .milliseconds(20),
                            sourceLocation: SourceLocation = #_sourceLocation,
                            _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Still waiting after \(timeout): \(what)", sourceLocation: sourceLocation)
            throw WaitTimedOut()
        }
        try await Task.sleep(for: interval)
    }
}

/// Suspends until the current task is cancelled and throws `CancellationError`: a fake scan or walk that runs until
/// the code under test stops it. `Task.sleep` ends the moment its task is cancelled; after `limit` it returns, so a stop
/// that never comes fails the test's checks instead of hanging the run.
nonisolated func untilCancelled(limit: Duration = .seconds(60)) async throws {
    try await Task.sleep(for: limit)
}

/// Waits `interval` on the main queue's own timer. `Task.sleep` wakes on the shared thread pool before it comes back
/// to the main actor: with the whole suite running, every pool thread is busy and a 5 ms sleep took seconds.
@MainActor private func pause(_ interval: Duration) async throws {
    try Task.checkCancellation()
    let (seconds, attoseconds) = interval.components
    await withCheckedContinuation { continuation in
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + Double(attoseconds) / 1e18) { continuation.resume() }
    }
}

/// Lays out `host` until `value` (a size the test checks) reads the same for 0.1 s and at least 3 polls in a row, at
/// most `timeout`: the view settled, without a fixed delay. Time, not a number of polls: with the whole suite running
/// a poll can wait half a second for the main thread, and 20 polls outlasted the timeout.
@MainActor func settledLayout<Value: Equatable>(_ host: NSView, timeout: Duration = .seconds(30),
                                                sourceLocation: SourceLocation = #_sourceLocation,
                                                _ value: @MainActor () -> Value) async throws {
    var last: Value?, same = 0, since = ContinuousClock.now
    try await eventually("a stable layout", timeout: timeout, sourceLocation: sourceLocation) {
        host.layoutSubtreeIfNeeded()
        let now = value()
        if now == last {
            same += 1
        } else {
            (last, same, since) = (now, 0, .now)
        }
        return same >= 2 && ContinuousClock.now - since >= .milliseconds(100)
    }
}

/// Returns once `condition` holds for `model`: checked now, then after each change the model publishes.
@MainActor func until<Model: ObservableObject>(_ model: Model, _ condition: @escaping @MainActor (Model) -> Bool) async {
    let waiting = Locked(CheckedContinuation<Void, Never>?.none)
    var subscription: AnyCancellable?
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            let done = waiting.withLock { slot in
                if Task.isCancelled || condition(model) { return true }
                slot = continuation
                return false
            }
            guard !done else { return continuation.resume() }
            // `objectWillChange` fires before the property is set: look on the next main-queue turn, once it is.
            subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { _ in
                if condition(model) { waiting.withLock { $0.take() }?.resume() }
            }
        }
    } onCancel: {
        waiting.withLock { $0.take() }?.resume()
    }
    subscription?.cancel()
}

/// A count raised from any thread (a fake running on a GCD thread) that a test awaits.
nonisolated final class SignalCount: Sendable {
    private let state = Locked((count: 0, waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)]()))

    var value: Int { state.withLock { $0.count } }

    func add() {
        let ready = state.withLock { state in
            state.count += 1
            let count = state.count
            defer { state.waiters.removeAll { $0.target <= count } }
            return state.waiters.filter { $0.target <= count }.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once the count is at least `target`.
    func reach(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let reached = state.withLock { state in
                if state.count >= target { return true }
                state.waiters.append((target, continuation))
                return false
            }
            if reached { continuation.resume() }
        }
    }
}

/// Holds fakes (on GCD threads) until the test opens it.
nonisolated final class ThreadGate: Sendable {
    private let opened = Locked(false)
    private let group = DispatchGroup()

    init() { group.enter() }

    var isOpen: Bool { opened.withLock { $0 } }

    func open() {
        let first = opened.withLock { opened in
            defer { opened = true }
            return !opened
        }
        if first { group.leave() }
    }

    /// Blocks the calling thread until `open()`.
    func wait() { group.wait() }
}

/// Returns once process `pid` has exited (kqueue `NOTE_EXIT`, no polling); true at once when it is already gone.
/// False only when the kernel refuses to watch it for another reason.
nonisolated func processExited(_ pid: pid_t) async -> Bool {
    await Task.detached {
        let queue = kqueue()
        guard queue >= 0 else { return false }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        var event = kevent()
        while true {
            let count = kevent(queue, &change, 1, &event, 1, nil)
            if count < 0 {
                if errno == EINTR { continue }
                return errno == ESRCH
            }
            if event.flags & UInt16(EV_ERROR) != 0 { return event.data == Int(ESRCH) }
            return event.fflags & UInt32(NOTE_EXIT) != 0
        }
    }.value
}
