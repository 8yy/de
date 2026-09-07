//
//  TweakLibrary.swift
//  ASign
//
//  Persistent tweak vault: a JSON-manifest library of injectable files with
//  folders and per-bundle-id auto-inject rules, deliberately kept out of
//  Core Data so the manifests stay inspectable and portable.
//
//  The actual tweak files keep living in the Tweaks folder the signing
//  pipeline already consumes; the vault adds metadata, organization and
//  automation on top of it.
//

import Foundation

// MARK: - Models

struct ManagedTweak: Identifiable, Codable, Hashable {
    var id: String
    /// Filename inside the Tweaks folder.
    var fileName: String
    var kind: String
    var addedAt: Date
    var folderID: String?
    /// When set, the tweak is injected automatically for matching apps.
    var autoInject: AutoInjectRule?
}

struct AutoInjectRule: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable {
        case off
        case all
        case bundleList
    }

    var mode: Mode
    /// Bundle identifiers the rule applies to when `mode == .bundleList`.
    var bundleIDs: [String]
}

struct TweakFolder: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

// MARK: - Library

@MainActor
final class TweakLibrary: ObservableObject {
    static let shared = TweakLibrary()

    @Published private(set) var tweaks: [ManagedTweak] = []
    @Published private(set) var folders: [TweakFolder] = []

    private var _libraryURL: URL {
        FileManager.default.tweaks.appendingPathComponent("library.json")
    }
    private var _foldersURL: URL {
        FileManager.default.tweaks.appendingPathComponent("folders.json")
    }

    private init() {
        load()
    }

    // MARK: Persistence

    func load() {
        let fm = FileManager.default
        try? fm.createDirectoryIfNeeded(at: FileManager.default.tweaks)

        if
            let data = try? Data(contentsOf: _libraryURL),
            let decoded = try? JSONDecoder().decode([ManagedTweak].self, from: data)
        {
            tweaks = decoded
        }
        if
            let data = try? Data(contentsOf: _foldersURL),
            let decoded = try? JSONDecoder().decode([TweakFolder].self, from: data)
        {
            folders = decoded
        }

        _pruneMissingFiles()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(tweaks) {
            try? data.write(to: _libraryURL, options: .atomic)
        }
        if let data = try? encoder.encode(folders) {
            try? data.write(to: _foldersURL, options: .atomic)
        }
    }

    /// Drop vault entries whose backing file vanished (cleaned cache, deleted
    /// through the Files tab, etc.). The metadata is useless without the file.
    private func _pruneMissingFiles() {
        let fm = FileManager.default
        let before = tweaks.count
        tweaks.removeAll { !fm.fileExists(atPath: fileURL(for: $0).path) }
        if tweaks.count != before { save() }
    }

    // MARK: File locations

    func fileURL(for tweak: ManagedTweak) -> URL {
        FileManager.default.tweaks.appendingPathComponent(tweak.fileName)
    }

    // MARK: CRUD

    /// Copies files into the Tweaks folder and registers them in the vault.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [ManagedTweak] {
        let fm = FileManager.default
        let allowedExtensions = Set(["dylib", "deb", "framework", "bundle", "zip", "tipa", "ipa"])
        var imported: [ManagedTweak] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }

            let needsSecurityScope = url.startAccessingSecurityScopedResource()
            defer { if needsSecurityScope { url.stopAccessingSecurityScopedResource() } }

            let destination = FileManager.default.tweaks.appendingPathComponent(url.lastPathComponent)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                if !url.path.hasPrefix(FileManager.default.tweaks.path) {
                    // Already lives in the vault folder (extracted tweak, etc.).
                    try fm.copyItem(at: url, to: destination)
                }

                let tweak = ManagedTweak(
                    id: UUID().uuidString,
                    fileName: url.lastPathComponent,
                    kind: ext,
                    addedAt: Date(),
                    folderID: nil,
                    autoInject: nil
                )
                tweaks.removeAll { $0.fileName == tweak.fileName }
                tweaks.append(tweak)
                imported.append(tweak)
            } catch {
                continue
            }
        }

        if !imported.isEmpty { save() }
        return imported
    }

    func remove(_ tweak: ManagedTweak) {
        try? FileManager.default.removeItem(at: fileURL(for: tweak))
        tweaks.removeAll { $0.id == tweak.id }
        save()
    }

    func rename(_ tweak: ManagedTweak, displayName: String) {
        // Renaming a tweak renames the backing file so the Tweaks folder stays
        // the single source of truth for what gets injected.
        let source = fileURL(for: tweak)
        let sanitized = displayName
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        let ext = tweak.fileName.split(separator: ".").last.map(String.init) ?? tweak.kind
        let newFileName = "\(sanitized).\(ext)"
        let destination = FileManager.default.tweaks.appendingPathComponent(newFileName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        try? FileManager.default.moveItem(at: source, to: destination)
        if let index = tweaks.firstIndex(where: { $0.id == tweak.id }) {
            tweaks[index].fileName = newFileName
        }
        save()
    }

    func setFolder(_ tweak: ManagedTweak, folderID: String?) {
        guard let index = tweaks.firstIndex(where: { $0.id == tweak.id }) else { return }
        tweaks[index].folderID = folderID
        save()
    }

    func setAutoInject(_ tweak: ManagedTweak, rule: AutoInjectRule?) {
        guard let index = tweaks.firstIndex(where: { $0.id == tweak.id }) else { return }
        tweaks[index].autoInject = rule
        save()
    }

    // MARK: Folders

    @discardableResult
    func addFolder(name: String) -> TweakFolder {
        let folder = TweakFolder(id: UUID().uuidString, name: name)
        folders.append(folder)
        save()
        return folder
    }

    func removeFolder(_ folder: TweakFolder) {
        folders.removeAll { $0.id == folder.id }
        for index in tweaks.indices where tweaks[index].folderID == folder.id {
            tweaks[index].folderID = nil
        }
        save()
    }

    // MARK: Auto-inject resolution

    /// Files that must be injected for the given bundle id according to the
    /// vault's auto-inject rules. Called from the signing pipeline.
    func autoInjectFiles(forBundleID bundleID: String?) -> [URL] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let fm = FileManager.default

        return tweaks
            .filter { tweak in
                guard let rule = tweak.autoInject, rule.mode != .off else { return false }
                switch rule.mode {
                case .all:
                    return true
                case .bundleList:
                    return rule.bundleIDs.contains(bundleID)
                case .off:
                    return false
                }
            }
            .map { fileURL(for: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: Session resolution

    /// Called by the signing pipeline for every signing session: folds the
    /// vault's auto-inject rules and the optional FilePickerFix shim into the
    /// session options. The vault's saved defaults are never mutated.
    static func resolvedSessionOptions(
        _ options: Options,
        bundleIdentifier: String?
    ) async -> Options {
        var resolved = options

        let autoInject = TweakLibrary.shared.autoInjectFiles(forBundleID: bundleIdentifier)
        if !autoInject.isEmpty {
            var seen = Set(resolved.injectionFiles.map { $0.lastPathComponent })
            for url in autoInject where seen.insert(url.lastPathComponent).inserted {
                resolved.injectionFiles.append(url)
            }
        }

        if resolved.fixFilePicker == true,
           let fixURL = Bundle.main.url(forResource: "FilePickerFix", withExtension: "dylib"),
           FileManager.default.fileExists(atPath: fixURL.path),
           !resolved.injectionFiles.contains(where: { $0.lastPathComponent == "FilePickerFix.dylib" }) {
            resolved.injectionFiles.append(fixURL)
        }

        return resolved
    }
}
