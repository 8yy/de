//
//  TweakAnalyzer.swift
//  ASign
//
//  Mach-O load-command inspection for tweak files: reports the dynamic
//  libraries a binary links against, flags CydiaSubstrate linkage and @rpath
//  usage, and recommends injection settings.
//
//  The parser is deliberately small: it understands thin arm64/arm64e/armv7
//  Mach-O images and falls back to a byte scan for fat binaries. Tweaks that
//  cannot be parsed still get the byte-scan verdict for substrate linkage.
//

import Foundation

struct TweakAnalysis {
    var isMachO = false
    var architecture: String?
    var loadCommands: Int = 0
    /// Everything the binary pulls in via LC_LOAD* commands.
    var dependencies: [String] = []
    var linksSubstrate = false
    var usesRpath = false

    /// Short human-readable warnings, e.g. "substitute framework missing".
    var warnings: [String] = []

    /// The install path prefix dylibs usually want.
    var recommendedInjectPath: Options.InjectPath = .executable_path
    var recommendedInjectFolder: Options.InjectFolder = .frameworks
}

enum TweakAnalyzer {
    private static let magic64: UInt32 = 0xfeed_facf     // MH_MAGIC_64 (little-endian value)
    private static let fatMagic: UInt32 = 0xcafe_babe    // FAT_CIGAM as read little-endian

    static func analyze(url: URL) -> TweakAnalysis {
        var analysis = TweakAnalysis()

        // Bundles and frameworks: analyze their executable.
        var binaryURL = url
        if url.pathExtension.lowercased() == "framework" {
            let bundle = Bundle(url: url)
            if let exec = bundle?.executableURL {
                binaryURL = exec
            }
        }

        guard let data = try? Data(contentsOf: binaryURL, options: .mappedIfSafe), data.count > 64 else {
            analysis.warnings.append("File could not be read")
            return analysis
        }

        let magic = data.readUInt32LE(at: 0)
        if magic == fatMagic {
            // Fat binary: take the first 64-bit slice and parse from there.
            // Reading the host slice properly is overkill for a verdict;
            // substrate detection still works via the byte scan below.
            analysis.architecture = "fat"
            _scanStrings(into: &analysis, data: data)
            return analysis
        }

        guard magic == magic64 else {
            analysis.warnings.append("Not a Mach-O binary")
            _scanStrings(into: &analysis, data: data)
            return analysis
        }

        analysis.isMachO = true
        _parseMachO(into: &analysis, data: data)
        return analysis
    }

    private static func _parseMachO(into analysis: inout TweakAnalysis, data: Data) {
        let cpuType = data.readUInt32LE(at: 4)
        switch cpuType {
        case 0x0100_000C: analysis.architecture = "arm"
        case 0x0100_000C | 0x8000_0000: analysis.architecture = "arm64 (thumb)"
        case 0x0100_000D: analysis.architecture = "arm64"
        case 0x0100_000D | 0x8000_0000: analysis.architecture = "arm64e"
        default: analysis.architecture = String(format: "cpu 0x%08x", cpuType)
        }

        let commandCount = Int(data.readUInt32LE(at: 16))
        analysis.loadCommands = commandCount

        var offset = 32 // mach_header_64 size
        var dependencies: [String] = []

        for _ in 0..<commandCount {
            guard offset + 8 <= data.count else { break }

            let command = data.readUInt32LE(at: offset)
            let commandSize = Int(data.readUInt32LE(at: offset + 4))
            guard commandSize >= 8, offset + commandSize <= data.count else { break }

            // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
            // LC_LOAD_UPWARD_DYLIB — all share the dylib layout.
            let dylibCommands: Set<UInt32> = [0x0c, 0x18, 0x1f, 0x22]
            if dylibCommands.contains(command) {
                // struct dylib { uint32 name_offset; ... } — the offset is
                // relative to the start of the load command.
                let nameOffset = Int(data.readUInt32LE(at: offset + 8))
                if nameOffset > 0, offset + nameOffset < data.count {
                    let string = data.readNullTerminatedString(at: offset + nameOffset)
                    if let string, !string.isEmpty {
                        dependencies.append(string)

                        let fileName = string.split(separator: "/").last.map(String.init) ?? string
                        if fileName.contains("CydiaSubstrate") || fileName.contains("libsubstrate") {
                            analysis.linksSubstrate = true
                        }
                        if string.hasPrefix("@rpath/") {
                            analysis.usesRpath = true
                        }
                    }
                }
            }

            offset += commandSize
        }

        analysis.dependencies = dependencies

        if analysis.linksSubstrate {
            analysis.warnings.append(
                "Links against CydiaSubstrate — enable the ElleKit replacement option or inject a substrate shim"
            )
            analysis.recommendedInjectFolder = .frameworks
        }
        if analysis.usesRpath {
            analysis.recommendedInjectPath = .rpath
        }
    }

    private static func _scanStrings(into analysis: inout TweakAnalysis, data: Data) {
        // Last-resort substrate detection for fat/unknown binaries.
        let prefix = data.prefix(4 * 1024 * 1024)
        let found = prefix.range(of: Data("CydiaSubstrate".utf8)) != nil

        analysis.linksSubstrate = found
        if found {
            analysis.warnings.append("Contains CydiaSubstrate references")
        }
    }
}

// MARK: - Data reader helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        withUnsafeBytes { buffer in
            _ = withUnsafeMutableBytes(of: &value) { destination in
                destination.baseAddress!.copyMemory(
                    from: buffer.baseAddress!.advanced(by: offset),
                    byteCount: 4
                )
            }
        }
        return UInt32(littleEndian: value)
    }

    func readNullTerminatedString(at offset: Int) -> String? {
        guard offset < count else { return nil }
        let start = index(startIndex, offsetBy: offset)
        guard let end = self[start...].firstIndex(of: 0) else { return nil }
        return String(data: subdata(in: start..<end), encoding: .utf8)
    }
}
