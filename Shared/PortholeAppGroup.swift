import Foundation

enum PortholeAppGroup {
    static var containerURL: URL? {
        #if os(iOS)
        let identifier = Bundle.main.object(forInfoDictionaryKey: "PortholeAppGroup") as? String
            ?? "group.local.porthole.pull"
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        return nil
        #endif
    }
}
