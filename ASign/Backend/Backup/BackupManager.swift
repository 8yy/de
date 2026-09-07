//
//  BackupManager.swift
//  ASign
//
//  Encrypted backup and restore of the signer's configuration: automation
//  preferences, source list, signing options, tweak vault manifests and —
//  optionally — certificates.
//
//  Format: a JSON payload, AES-GCM encrypted with a key derived from the
//  user's password (PBKDF2, 200k iterations, 16-byte random salt) via
//  CryptoKit + CommonCrypto. Files are prefixed with "ASIGNBK1" (encrypted)
//  or "ASIGNBK0" (plain, when no password is given).
//

import Foundation
import CryptoKit

struct BackupPayload: Codable {
    var format = "asign-backup"
    var version = 1
    var createdAt = Date()

    var settings: [String: String] = [:]
    var sources: [String] = []
    var options: Data?
    var tweaks: Data?
    var folders: Data?
    var certificates: [BackupCertificate] = []
}

struct BackupCertificate: Codable {
    var nickname: String?
    var password: String?
    var p12Data: Data?
    var provisionData: Data?
    var expiration: Date?
    var ppQCheck: Bool
}

enum BackupError: LocalizedError {
    case invalidFormat
    case corruptArchive
    case cryptoFailure

    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Not an ASign backup file"
        case .corruptArchive: return "The backup could not be read"
        case .cryptoFailure: return "The backup is damaged or the password is wrong"
        }
    }
}

enum BackupManager {
    // MARK: Keys included in a backup

    static let settingsKeys = [
        "signing_options",
        "asign.autoUpdateInterval",
        "asign.autoUpdateWifiOnly",
        "asign.autoDownloadUpdates",
        "asign.updateBadge",
        "asign.updateNotifications",
        "asign.autoDeleteOldVersions",
        "asign.autoInstallAfterSign",
        "asign.installChargingOnly",
        "asign.renewThresholdDays",
        "asign.selfHealEnabled",
        "asign.appCertificatePins",
        "asign.webManager.username",
        "asign.webManager.password",
        "asign.webManager.webdav",
        "feather.installationMethod",
        "feather.serverMethod",
        "feather.batchGroupSize",
        "feather.compressionLevel",
        "feather.selectedCert",
        "Feather.accentColor",
    ]

    // MARK: Export

    static func create(includeCertificates: Bool, password: String?) throws -> URL {
        var payload = BackupPayload()

        let defaults = UserDefaults.standard
        for key in settingsKeys {
            if let value = defaults.string(forKey: key) {
                payload.settings[key] = value
            }
        }

        payload.sources = Storage.shared.getSources().compactMap { $0.sourceURL?.absoluteString }
        payload.options = defaults.data(forKey: "signing_options")
        payload.tweaks = defaults.data(forKey: "tweak_vault.library")
        payload.folders = defaults.data(forKey: "tweak_vault.folders")

        if includeCertificates {
            let request: NSFetchRequest<CertificatePair> = CertificatePair.fetchRequest()
            let certificates = (try? Storage.shared.context.fetch(request)) ?? []
            payload.certificates = certificates.map { cert in
                BackupCertificate(
                    nickname: cert.nickname,
                    password: cert.password,
                    p12Data: cert.p12Data,
                    provisionData: cert.provisionData,
                    expiration: cert.expiration,
                    ppQCheck: cert.ppQCheck
                )
            }
        }

        let plainData = try JSONEncoder().encode(payload)

        var fileData: Data
        if let password, !password.isEmpty {
            fileData = try Self.encrypt(plainData, password: password)
        } else {
            fileData = "ASIGNBK0".data(using: .utf8)! + plainData
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ASign-Backup-\(formatter.string(from: Date())).asignbackup")
        try fileData.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: Import

    static func restore(from url: URL, password: String?) throws {
        let fileData = try Data(contentsOf: url)

        let plainData: Data
        if fileData.starts(with: Data("ASIGNBK1".utf8)) {
            guard let password, !password.isEmpty else { throw BackupError.cryptoFailure }
            plainData = try decrypt(fileData, password: password)
        } else if fileData.starts(with: Data("ASIGNBK0".utf8)) {
            plainData = fileData.dropFirst(8)
        } else {
            throw BackupError.invalidFormat
        }

        let payload = try JSONDecoder().decode(BackupPayload.self, from: plainData)
        let defaults = UserDefaults.standard

        for (key, value) in payload.settings {
            defaults.set(value, forKey: key)
        }

        if let options = payload.options {
            defaults.set(options, forKey: "signing_options")
            OptionsManager.shared.options = (try? JSONDecoder().decode(Options.self, from: options))
                ?? OptionsManager.shared.options
        }

        // Sources: re-add anything not already present.
        for urlString in payload.sources {
            guard let url = URL(string: urlString) else { continue }
            FR.handleSource(url) { _ in }
        }

        // Certificates.
        for cert in payload.certificates {
            guard let p12Data = cert.p12Data, let provisionData = cert.provisionData else { continue }

            let workDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BackupCert_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectoryIfNeeded(at: workDir)
            let p12URL = workDir.appendingPathComponent("cert.p12")
            let provisionURL = workDir.appendingPathComponent("cert.mobileprovision")
            try p12Data.write(to: p12URL)
            try provisionData.write(to: provisionURL)

            FR.handleCertificateFiles(
                p12URL: p12URL,
                provisionURL: provisionURL,
                p12Password: cert.password ?? "",
                certificateName: cert.nickname ?? "Restored"
            ) { _ in }
        }

        ActivityLog.shared.add(.info, title: String.localized("Backup restored"), detail: nil)
    }

    // MARK: Crypto

    private static let _magic = "ASIGNBK1"

    private static func encrypt(_ data: Data, password: String) throws -> Data {
        let salt = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let key = Self.deriveKey(password: password, salt: salt)
        let keySymmetric = SymmetricKey(data: key)
        let sealed = try AES.GCM.seal(data, using: keySymmetric).combined!
        return Data(_magic.utf8) + Data(salt) + sealed
    }

    private static func decrypt(_ data: Data, password: String) throws -> Data {
        let magicLength = _magic.count
        guard data.count > magicLength + 16 + 28 else { throw BackupError.corruptArchive }

        let salt = data.subdata(in: magicLength..<(magicLength + 16))
        let payload = data.subdata(in: (magicLength + 16)..<data.count)
        let key = Self.deriveKey(password: password, salt: salt)

        guard let box = try? AES.GCM.SealedBox(combined: payload) else { throw BackupError.corruptArchive }
        guard let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else {
            throw BackupError.cryptoFailure
        }
        return opened
    }

    private static func deriveKey(password: String, salt: Data) -> Data {
        var derivedKeyData = Data(repeating: 0, count: 32)
        let result = derivedKeyData.withUnsafeMutableBytes { derivedBytes in
            password.withCString { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes,
                        password.utf8.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        200_000,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        precondition(result == kCCSuccess)
        return derivedKeyData
    }
}
