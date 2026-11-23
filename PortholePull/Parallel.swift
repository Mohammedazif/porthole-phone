import Foundation

/// Work over the library spread across the phone's cores. A search touches every one of
/// tens of thousands of small copies, and one core alone made a drag wait seconds.
enum Parallel {
    /// The transform reads immutable snapshots. Workers build private chunks and
    /// publish once under the lock, then concurrentPerform joins before return.
    private final class Work<T>: @unchecked Sendable {
        private let count: Int
        private let transform: (Int) -> T
        private let lock = NSLock()
        private var results: [[T]]

        init(count: Int, chunks: Int, transform: @escaping (Int) -> T) {
            self.count = count
            self.transform = transform
            results = Array(repeating: [], count: chunks)
        }

        func run(chunk: Int, of chunks: Int) {
            let lower = chunk * count / chunks
            let upper = (chunk + 1) * count / chunks
            let values = (lower..<upper).map(transform)
            lock.lock()
            results[chunk] = values
            lock.unlock()
        }

        func collect() -> [T] {
            lock.lock()
            defer { lock.unlock() }
            return results.flatMap { $0 }
        }
    }

    /// f(i) for every i in 0..<count, in order. Below serialBelow items it stays on this
    /// thread, where handing work out would cost more than it saves.
    static func map<T>(_ count: Int, serialBelow: Int = 256, _ f: @escaping (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        if count < serialBelow { return (0..<count).map(f) }
        let chunks = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount) * 4)
        let work = Work(count: count, chunks: chunks, transform: f)
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            work.run(chunk: chunk, of: chunks)
        }
        return work.collect()
    }

    /// Milliseconds since start, for the timings sent to the PC's log.
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
