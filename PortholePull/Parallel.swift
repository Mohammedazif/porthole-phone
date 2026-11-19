import Foundation

/// Work over the library spread across the phone's cores. A search touches every one of
/// tens of thousands of small copies, and one core alone made a drag wait seconds.
enum Parallel {
    /// f(i) for every i in 0..<count, in order. Below serialBelow items it stays on this
    /// thread, where handing work out would cost more than it saves.
    static func map<T>(_ count: Int, serialBelow: Int = 256, _ f: (Int) -> T) -> [T] {
        guard count > 0 else { return [] }
        if count < serialBelow { return (0..<count).map(f) }
        var out = [T?](repeating: nil, count: count)
        let chunks = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount) * 4)
        out.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                for i in (chunk * count / chunks)..<((chunk + 1) * count / chunks) {
                    base[i] = f(i)
                }
            }
        }
        return out.map { $0! }
    }

    /// Milliseconds since start, for the timings sent to the PC's log.
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
