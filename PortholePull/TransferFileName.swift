import Foundation

enum TransferFileName {
    /// Matches the PC inbox's line protocol: ASCII, no spaces or control lines.
    static func make(_ original: String, index: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let name = (original as NSString).lastPathComponent
        let ext = String((name as NSString).pathExtension.prefix(8).map { allowed.contains($0) ? $0 : "_" })
        var base = String((name as NSString).deletingPathExtension.map { allowed.contains($0) ? $0 : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if base.isEmpty { base = "file-\(index + 1)" }
        let firstComponent = base.uppercased().split(separator: ".").first.map(String.init) ?? ""
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(firstComponent) { base = "_" + base }
        let suffix = ext.isEmpty ? ".dat" : "." + ext
        return String(base.prefix(78 - suffix.count)) + suffix
    }
}
