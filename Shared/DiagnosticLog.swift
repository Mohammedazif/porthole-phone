import Foundation

/// Short lines about what the iPhone did (file transfers, background work),
/// written into the PC's porthole.log so problems can be seen from there.
/// Porthole sends them over its link to the PC; the Share Sheet keeps them in
/// the app group until Porthole next connects.
enum DiagnosticLog {
    /// Set by Porthole while it's linked to the PC.
    static var sink: ((String) -> Void)?
    private static let lock = NSLock()
    private static let fileName = "porthole-diagnostics.txt"

    static func note(_ text: String) {
        let line = String(text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").prefix(300))
        lock.lock()
        let sink = self.sink
        lock.unlock()
        if let sink {
            sink(line)
            return
        }
        guard let url = PortholeAppGroup.containerURL?.appendingPathComponent(fileName) else { return }
        lock.lock()
        defer { lock.unlock() }
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 48 * 1024 { data = Data() }
        data.append(Data((timestamp() + " " + line + "\n").utf8))
        try? data.write(to: url, options: .atomic)
    }

    static func setSink(_ newSink: ((String) -> Void)?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    /// Lines the Share Sheet kept, oldest first; they're removed once taken.
    static func takeKept() -> [String] {
        guard let url = PortholeAppGroup.containerURL?.appendingPathComponent(fileName) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { "earlier, " + $0 }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
