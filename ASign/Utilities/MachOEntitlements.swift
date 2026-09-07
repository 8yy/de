//
//  MachOEntitlements.swift
//  ASign
//
//  Derives keychain-access-groups for a signed app from its provisioning
//  profile, so re-signed apps keep working keychains without reusing the
//  original app's groups (which belong to a different team/identifier).
//

import Foundation

enum MachOEntitlements {
    /// Builds the keychain-access-groups list for an app signed with the given
    /// provision profile:
    ///   - `<teamID>.<newBundleID>` — the group the profile actually grants,
    ///   - `<teamID>.*` when the profile is a wildcard,
    ///   - and the bare new bundle id, which some apps query directly.
    static func keychainGroups(provisionURL: URL?, newBundleID: String) -> [String] {
        var groups: [String] = []
        var teamID: String?

        if
            let provisionURL,
            let data = try? Data(contentsOf: provisionURL),
            let profile = CertificateReader.parseData(data)
        {
            // Team id straight from the profile when available.
            teamID = profile.TeamIdentifier.first

            if let entitlements = profile.Entitlements {
                if
                    case let applicationIdentifier? = entitlements["application-identifier"],
                    let appID = applicationIdentifier.value as? String
                {
                    teamID = teamID ?? appID.split(separator: ".", maxSplits: 1).first.map(String.init)
                }

                if
                    case let existingAnyGroups? = entitlements["keychain-access-groups"],
                    let existingGroups = existingAnyGroups.value as? [String]
                {
                    // Reuse the profile's own groups where they still apply.
                    for group in existingGroups {
                        if group.hasSuffix(".*") || group.hasSuffix(newBundleID) {
                            groups.append(group)
                        }
                    }
                }
            }
        }

        if let teamID {
            groups.append("\(teamID).\(newBundleID)")
            groups.append("\(teamID).*")
        }
        groups.append(newBundleID)

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return groups.filter { seen.insert($0).inserted }
    }

    /// Produces a merged entitlements plist (the user's file, when provided,
    /// plus the derived keychain groups) written to a temporary location.
    static func entitlementsFile(
        customEntitlements: URL?,
        provisionURL: URL?,
        newBundleID: String,
        keychainIsolation: Bool
    ) -> URL? {
        guard keychainIsolation else { return customEntitlements }

        var dictionary: [String: Any] = [:]
        if let customEntitlements {
            dictionary = (NSDictionary(contentsOf: customEntitlements) as? [String: Any]) ?? [:]
        }

        let groups = keychainGroups(provisionURL: provisionURL, newBundleID: newBundleID)
        dictionary["keychain-access-groups"] = groups

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASignEntitlements_\(UUID().uuidString).plist")
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
            try data.write(to: output, options: .atomic)
            return output
        } catch {
            return customEntitlements
        }
    }
}
