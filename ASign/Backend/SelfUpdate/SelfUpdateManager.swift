//
//  SelfUpdateManager.swift
//  ASign
//
//  In-app self-update: checks a GitHub repository's releases, and when a
//  newer build exists, downloads the IPA, imports it into the library and
//  hands it to the normal sign-and-install flow — the same path any other
//  app update takes.
//
//  The repository is configurable so private distributions can point the
//  manager at their own repo; the default follows this project.
//

import Foundation
import UIKit
import SwiftUI

@MainActor
final class SelfUpdateManager: ObservableObject {
    static let shared = SelfUpdateManager()

    enum Phase: Equatable {
        case idle
        case checking
        case available(version: String)
        case upToDate
        case downloading
        case importing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var ignoreVersion: String?

    @AppStorage("asign.selfUpdate.repo") private var _repo: String = "HighHill"
    @AppStorage("asign.selfUpdate.enabled") private var _enabled: Bool = true

    private let _ignoreKey = "asign.selfUpdate.ignoreVersion"

    private init() {
        ignoreVersion = UserDefaults.standard.string(forKey: _ignoreKey)
    }

    var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(_repo)/releases?per_page=10")!
    }

    func checkForUpdate() {
        guard _enabled, phase != .checking, phase != .downloading else { return }
        phase = .checking

        Task {
            do {
                var request = URLRequest(url: releasesURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

                // Prefer a prerelease tagged "beta" when it is the newest asset
                // carrier, otherwise the highest non-draft release.
                guard
                    let candidate = releases.first(where: { !$0.draft && Self.isNewer($0.tagName) }),
                    let asset = candidate.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") })
                else {
                    phase = .upToDate
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        if self?.phase == .upToDate { self?.phase = .idle }
                    }
                    return
                }

                latestVersion = candidate.tagName
                phase = .available(version: candidate.tagName)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func ignoreCurrentVersion() {
        guard let latestVersion else { return }
        ignoreVersion = latestVersion
        UserDefaults.standard.set(latestVersion, forKey: _ignoreKey)
        phase = .idle
    }

    func downloadAndImport() {
        guard case .available = phase else { return }
        phase = .downloading

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: releasesURL)
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

                guard
                    let candidate = releases.first(where: { !$0.draft && Self.isNewer($0.tagName) }),
                    let asset = candidate.assets.first(where: { $0.name.lowercased().hasSuffix(".ipa") }),
                    let url = URL(string: asset.browserDownloadUrl)
                else {
                    phase = .failed("No IPA asset found")
                    return
                }

                let (fileData, _) = try await URLSession.shared.data(from: url)
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ASign-\(candidate.tagName).ipa")
                try fileData.write(to: staged, options: .atomic)

                phase = .importing
                FR.handlePackageFile(staged) { [weak self] error in
                    Task { @MainActor in
                        if let error {
                            self?.phase = .failed(error.localizedDescription)
                        } else {
                            ActivityLog.shared.add(
                                .downloading,
                                title: String.localized("Self-update downloaded"),
                                detail: candidate.tagName
                            )
                            self?.phase = .idle
                        }
                    }
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private static func isNewer(_ tag: String) -> Bool {
        let clean = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        guard let ignored = UserDefaults.standard.string(forKey: "asign.selfUpdate.ignoreVersion") else {
            return clean != Bundle.main.version
        }
        let ignoredClean = ignored.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        return clean != ignoredClean && UpdateEngine.compareVersions(clean, Bundle.main.version) > 0
    }
}

// MARK: - GitHub models

struct GitHubRelease: Decodable {
    var tagName: String
    var draft: Bool
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case assets
    }

    struct Asset: Decodable {
        var name: String
        var browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
}
