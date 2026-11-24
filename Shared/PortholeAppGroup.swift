import Foundation

enum PortholeAppGroup {
    private static let declaredGroup = Bundle.main.object(forInfoDictionaryKey: "PortholeAppGroup") as? String
        ?? "group.local.porthole.pull"

    static var containerURL: URL? {
        #if os(iOS)
        let signed = profileGroups
        let matching = signed.filter { $0.hasPrefix(declaredGroup + ".") }
        // Provisioning may rename the group without adding installer metadata.
        let compatible = installerGroups + [declaredGroup] + matching
            + (usesInstallerGroup && signed.count == 1 ? signed : [])
        for group in compatible where group.hasPrefix("group.") {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
                return url
            }
        }
        if usesInstallerGroup,
           let bundleID = Bundle.main.bundleIdentifier,
           let group = installerGroup(for: bundleID, configuredGroup: declaredGroup) {
            return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        }
        return nil
        #else
        return nil
        #endif
    }

    static var usesInstallerGroup: Bool {
        !installerGroups.isEmpty || profileGroups.contains(where: { $0.hasPrefix(declaredGroup + ".") })
            || Bundle.main.object(forInfoDictionaryKey: "PortholeUseInstallerAppGroup") as? Bool == true
    }

    private static var installerGroups: [String] {
        Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
    }

    private static let profileGroups: [String] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return [] }
        return appGroups(inProvisioningProfile: data)
    }()

    static func appGroups(inProvisioningProfile data: Data) -> [String] {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let contents = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let profile = contents as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
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
