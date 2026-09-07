//
//  StorageManager.swift
//  ASign
//
//  Per-category disk usage accounting and bulk cleanup for everything the
//  signer keeps on disk.
//

import Foundation
import CoreData

struct StorageCategory: Identifiable {
    let id: String
    let titleKey: String
    let url: URL?
    let bytes: Int64
}

@MainActor
final class StorageManager: ObservableObject {
    static let shared = StorageManager()

    @Published private(set) var categories: [StorageCategory] = []
    @Published private(set) var totalBytes: Int64 = 0

    private init() {}

    func refresh() {
        let fm = FileManager.default

        let definitions: [(id: String, titleKey: String, url: URL?)] = [
            ("signed", "Signed Apps", urlForDocuments("App/Signed")),
            ("imported", "Imported Apps", urlForDocuments("App/Unsigned")),
            ("archives", "Archives", fm.archives),
            ("downloads", "Downloads", urlForDocuments("Downloads")),
            ("tweaks", "Tweaks", fm.tweaks),
            ("certificates", "Certificates", urlForDocuments("App/Certificates")),
            ("server", "Install Server", urlForDocuments("App/Server")),
            ("temp", "Temporary", fm.temporaryDirectory)
        ]

        var result: [StorageCategory] = []
        var total: Int64 = 0

        for definition in definitions {
            let bytes = definition.url.map { Self.sizeOfDirectory(at: $0) } ?? 0
            total += bytes
            result.append(
                StorageCategory(
                    id: definition.id,
                    titleKey: definition.titleKey,
                    url: definition.url,
                    bytes: bytes
                )
            )
        }

        categories = result.sorted { $0.bytes > $1.bytes }
        totalBytes = total
    }

    private func urlForDocuments(_ relative: String) -> URL? {
        URL.documentsDirectory.appendingPathComponent(relative)
    }

    nonisolated static func sizeOfDirectory(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: Cleanup

    func clearCategory(_ category: StorageCategory) {
        guard let url = category.url else { return }
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return }
        for item in contents {
            try? fm.removeItem(at: item)
        }
        refresh()
    }

    /// Deletes signed copies that share an identifier with a newer signed copy
    /// — the same app signed twice, where only the newest is useful.
    func removeSupersededCopies() -> Int {
        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Signed.date, ascending: false)]
        guard let signed = try? Storage.shared.context.fetch(request) else { return 0 }

        var seenIdentifiers = Set<String>()
        var removed = 0

        for app in signed {
            guard let identifier = app.identifier else { continue }
            if seenIdentifiers.contains(identifier) {
                if let url = Storage.shared.getUuidDirectory(for: app) {
                    try? FileManager.default.removeItem(at: url)
                }
                Storage.shared.context.delete(app)
                removed += 1
            } else {
                seenIdentifiers.insert(identifier)
            }
        }

        if removed > 0 {
            try? Storage.shared.context.save()
        }
        refresh()
        return removed
    }

    /// Removes imported originals whose identifier already exists as a signed
    /// app — the unsigned copy has done its job at that point.
    func removeImportedDuplicates() -> Int {
        let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        let signedIdentifiers = Set(
            ((try? Storage.shared.context.fetch(signedRequest)) ?? []).compactMap { $0.identifier }
        )

        let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
        guard let imported = try? Storage.shared.context.fetch(importedRequest) else { return 0 }

        var removed = 0
        for app in imported {
            guard let identifier = app.identifier, signedIdentifiers.contains(identifier) else { continue }
            if let url = Storage.shared.getUuidDirectory(for: app) {
                try? FileManager.default.removeItem(at: url)
            }
            Storage.shared.context.delete(app)
            removed += 1
        }

        if removed > 0 {
            try? Storage.shared.context.save()
        }
        refresh()
        return removed
    }
}
