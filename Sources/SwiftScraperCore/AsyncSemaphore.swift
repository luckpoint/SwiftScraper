import Foundation

actor AsyncSemaphore {
    private let limit: Int
    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        self.availablePermits = limit
    }

    func withPermit<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        await acquire()
        defer {
            release()
        }

        return await operation()
    }

    private func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume()
            return
        }

        availablePermits = min(availablePermits + 1, limit)
    }
}
