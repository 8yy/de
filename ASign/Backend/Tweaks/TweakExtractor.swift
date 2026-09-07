//
//  TweakExtractor.swift
//  ASign
//
//  Pulls injectable tweaks out of an IPA/TIPA/zip so users can harvest tweaks
//  from existing signed packages. Extracted files are registered in the vault
//  by the caller.
//

import Foundation
import ZIPFoundation

enum TweakExtractor {
    /// Extracts .dylib / .deb / .framework / .bundle entries from an archive.
    /// Returns the URLs of everything that landed in the Tweaks folder.
    @discardableResult
    static func extractTweaks(from archiveURL: URL) -> [URL] {
        let fm = FileManager.default
        let tweaksDir = fm.tweaks
        try? fm.createDirectoryIfNeeded(at: tweaksDir)

        let workDir = fm.temporaryDirectory
            .appendingPathComponent("TweakExtract_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }

        guard let archive = try? Archive(url: archiveURL, accessMode: .read) else {
            return []
        }

        var extracted: [URL] = []
        let interestingExtensions = Set(["dylib", "deb", "framework", "bundle"])

        do {
            for entry in archive where entry.type == .file {
                let entryExtension = (entry.path as NSString).pathExtension.lowercased()
                guard interestingExtensions.contains(entryExtension) else { continue }

                // Flatten: keep only the file name so directory noise from the
                // archive (Payload/.../Frameworks/...) never leaks into the vault.
                let fileName = (entry.path as NSString).lastPathComponent
                guard !fileName.isEmpty else { continue }

                let destination = tweaksDir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }

                let entryData = try archive.extract(entry, bufferSize: 1024 * 1024)
                try entryData.write(to: destination, options: .atomic)
                extracted.append(destination)
            }
        } catch {
            return extracted
        }

        return extracted
    }
}
