import Combine
import Foundation
@testable import CleanMate

// Waiting on what the code under test signals, never on the clock: a wait of N seconds fails on a busy Mac and
// slows every run on an idle one. A signal that never comes hangs the test; give such tests a `.timeLimit`.

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
