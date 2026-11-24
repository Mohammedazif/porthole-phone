import Foundation

enum PortholeAppGroup {
    static var containerURL: URL? {
        #if os(iOS)
        let identifier = Bundle.main.object(forInfoDictionaryKey: "PortholeAppGroup") as? String
            ?? "group.local.porthole.pull"
        // iLoader supplies the provisioned App Group in each signed bundle.
        for group in installerGroups where group.hasPrefix("group.") {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        if usesInstallerGroup,
           let bundleID = Bundle.main.bundleIdentifier,
           let group = installerGroup(for: bundleID, configuredGroup: identifier) {
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        #else
        return nil
        #endif
    }

    static var usesInstallerGroup: Bool {
        !installerGroups.isEmpty || Bundle.main.object(forInfoDictionaryKey: "PortholeUseInstallerAppGroup") as? Bool == true
    }

    private static var installerGroups: [String] {
        Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    static func installerGroup(for bundleID: String, configuredGroup: String) -> String? {
        guard configuredGroup.hasPrefix("group.") else { return nil }
        let baseID = configuredGroup.dropFirst("group.".count)
        let prefix = "\(baseID)."
        var containingAppID = bundleID
        for suffix in [".broadcast", ".share", ".widgets"] where containingAppID.hasSuffix(suffix) {
            containingAppID.removeLast(suffix.count)
            break
        }
        guard !baseID.isEmpty, containingAppID.hasPrefix(prefix) else { return nil }
        let teamID = containingAppID.dropFirst(prefix.count).utf8
        guard teamID.count == 10, teamID.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else {
            return nil
        }
        return "group.\(containingAppID)"
    }
}
