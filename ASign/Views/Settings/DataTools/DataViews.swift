//
//  DataViews.swift
//  ASign
//
//  Activity timeline, storage manager, backup/restore and certificate health
//  screens.
//

import SwiftUI
import CoreData
import NimbleViews
import NimbleExtensions

// MARK: - Activity timeline

struct ActivityView: View {
    @StateObject private var _log = ActivityLog.shared

    var body: some View {
        NBList(.localized("Activity")) {
            if _log.entries.isEmpty {
                Section {
                    Text(.localized("Nothing has happened yet."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(_log.entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.symbolName)
                                .foregroundStyle(entry.tint)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.callout)
                                if let detail = entry.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            Text(entry.date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        _log.clear()
                    }
                }
            }
        }
        .toolbar {
            NBToolbarButton(.localized("Clear"), style: .text) {
                _log.clear()
            }
        }
    }
}

// MARK: - Storage

struct StorageView: View {
    @StateObject private var _manager = StorageManager.shared
    @State private var _removalNotice: String?

    var body: some View {
        NBList(.localized("Storage")) {
            NBSection(.localized("Usage")) {
                ForEach(_manager.categories) { category in
                    HStack {
                        Text(.localized(category.titleKey))
                        Spacer()
                        Text(category.bytes.formattedByteCount)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack {
                    Text(.localized("Total"))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(_manager.totalBytes.formattedByteCount)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
            } footer: {
                Text(.localized("Every category can be cleared. Signed apps are removed through the Library."))
            }

            NBSection(.localized("Cleanup")) {
                Button {
                    let removed = _manager.removeSupersededCopies()
                    _removalNotice = String(format: String.localized("Removed %d superseded copy(ies)"), removed)
                } label: {
                    Label(.localized("Remove Superseded Copies"), systemImage: "arrow.triangle.swap")
                }
                .tint(.orange)

                Button {
                    let removed = _manager.removeImportedDuplicates()
                    _removalNotice = String(format: String.localized("Removed %d duplicate import(s)"), removed)
                } label: {
                    Label(.localized("Remove Imported Duplicates"), systemImage: "tray.full")
                }
                .tint(.orange)

                Button(role: .destructive) {
                    if let archives = _manager.categories.first(where: { $0.id == "archives" }) {
                        _manager.clearCategory(archives)
                    }
                } label: {
                    Label(.localized("Clear Archives"), systemImage: "archivebox")
                }
            }

            if let notice = _removalNotice {
                Section {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            _manager.refresh()
        }
    }
}

// MARK: - Backup & restore

struct BackupRestoreView: View {
    @State private var _includeCertificates = true
    @State private var _backupPassword = ""
    @State private var _restorePassword = ""
    @State private var _isRestoringPresenting = false
    @State private var _errorText: String?

    var body: some View {
        NBList(.localized("Backup & Restore")) {
            NBSection(.localized("Create Backup")) {
                Toggle(isOn: $_includeCertificates) {
                    Label(.localized("Include Certificates"), systemImage: "signature")
                }
                SecureField(.localized("Password (optional)"), text: $_backupPassword)

                Button {
                    _createBackup()
                } label: {
                    Label(.localized("Create Backup"), systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(.localized("Backs up your settings, sources, signing options, tweak vault and (optionally) certificates. With a password set, the archive is AES-GCM encrypted."))
            }

            NBSection(.localized("Restore")) {
                SecureField(.localized("Password (if encrypted)"), text: $_restorePassword)
                Button {
                    _isRestoringPresenting = true
                } label: {
                    Label(.localized("Choose Backup File"), systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text(.localized("Restoring re-applies settings, re-adds sources and imports backed-up certificates."))
            }

            if let errorText = _errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .fileImporter(
            isPresented: $_isRestoringPresenting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            _restore(from: url)
        }
    }

    private func _createBackup() {
        do {
            let url = try BackupManager.create(
                includeCertificates: _includeCertificates,
                password: _backupPassword.isEmpty ? nil : _backupPassword
            )
            UIActivityViewController.show(activityItems: [url])
            ASHaptic.success()
        } catch {
            _errorText = error.localizedDescription
            ASHaptic.error()
        }
    }

    private func _restore(from url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            // Copy out of the provider first so restore reads a stable file.
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.copyItem(at: url, to: local)

            try BackupManager.restore(
                from: local,
                password: _restorePassword.isEmpty ? nil : _restorePassword
            )
            ASHaptic.success()
            _errorText = nil
        } catch {
            _errorText = error.localizedDescription
            ASHaptic.error()
        }
    }
}

// MARK: - Certificate health

struct CertHealthView: View {
    @FetchRequest(
        entity: CertificatePair.entity(),
        sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
        animation: .snappy
    ) private var _certificates: FetchedResults<CertificatePair>

    @State private var _isRenewing = false

    var body: some View {
        NBList(.localized("Certificate Health")) {
            Section {
                ForEach(Array(_certificates), id: \.objectID) { cert in
                    HStack(spacing: 12) {
                        ExpiryRingView(expiration: cert.expiration)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(cert.nickname ?? String.localized("Unnamed Certificate"))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if cert.revoked {
                                    Label(.localized("Revoked"), systemImage: "xmark.octagon")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                if let expiration = cert.expiration {
                                    Text(expiration.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 3)
                }
            } footer: {
                Text(.localized("The ring fills as the certificate approaches its expiration date."))
            }

            Section {
                Button {
                    _renewAll()
                } label: {
                    Label(.localized("Renew All Apps with Best Certificate"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(_isRenewing)

                Button {
                    _checkRevocation()
                } label: {
                    Label(.localized("Check Revocation Status Now"), systemImage: "questionmark.diamond")
                }
            } footer: {
                Text(.localized("Self-heal re-signs apps automatically before their certificate expires when enabled in Updates & Automation."))
            }
        }
    }

    private func _renewAll() {
        _isRenewing = true
        let queue = AutoSignQueue.shared

        let request: NSFetchRequest<Signed> = Signed.fetchRequest()
        let signed = (try? Storage.shared.context.fetch(request)) ?? []

        for app in signed {
            guard let cert = app.certificate else { continue }
            if !AutoSignQueue.isHealthy(cert) || (cert.expiration ?? .distantFuture) < Date().addingTimeInterval(14 * 86400) {
                queue.enqueue(app: app, reason: .renewal)
            }
        }

        _isRenewing = false
        ASHaptic.tap()
    }

    private func _checkRevocation() {
        for cert in _certificates {
            Storage.shared.revokagedCertificate(for: cert)
        }
        ASHaptic.tap()
    }
}

// MARK: - Expiry ring

struct ExpiryRingView: View {
    let expiration: Date?

    private var _fraction: Double {
        guard let expiration else { return 1 }
        let total: TimeInterval = 30 * 86400
        let remaining = expiration.timeIntervalSinceNow
        return min(1, max(0, remaining / total))
    }

    private var _color: Color {
        switch _fraction {
        case ..<0.2: return .red
        case ..<0.5: return .orange
        default: return .green
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: _fraction)
                .stroke(_color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(AS.spring, value: _fraction)

            Image(systemName: "signature")
                .font(.caption2)
                .foregroundStyle(_color)
        }
    }
}
