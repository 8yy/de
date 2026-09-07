//
//  AutomationView.swift
//  ASign
//
//  Settings for the automation engine: update checking, auto-download,
//  background signing, self-heal renewals and self-update.
//

import SwiftUI
import NimbleViews

struct AutomationView: View {
    @AppStorage("asign.autoUpdateInterval") private var _interval: Int = 6
    @AppStorage("asign.autoUpdateWifiOnly") private var _wifiOnly: Bool = true
    @AppStorage("asign.autoDownloadUpdates") private var _autoDownload: Bool = false
    @AppStorage("asign.updateBadge") private var _badge: Bool = true
    @AppStorage("asign.updateNotifications") private var _notifications: Bool = false

    @AppStorage("asign.autoSignEnabled") private var _autoSign: Bool = false
    @AppStorage("asign.autoDeleteOldVersions") private var _deleteOld: Bool = true
    @AppStorage("asign.autoInstallAfterSign") private var _autoInstall: Bool = false
    @AppStorage("asign.installChargingOnly") private var _chargingOnly: Bool = false

    @AppStorage("asign.selfHealEnabled") private var _selfHeal: Bool = true
    @AppStorage("asign.renewThresholdDays") private var _renewDays: Int = 3

    @AppStorage("asign.selfUpdate.enabled") private var _selfUpdate: Bool = true

    private let _intervals: [(Int, String)] = [
        (0, "Off"),
        (1, "Every hour"),
        (3, "Every 3 h"),
        (6, "Every 6 h"),
        (12, "Every 12 h"),
        (24, "Every day"),
    ]

    var body: some View {
        NBList(.localized("Updates & Automation")) {
            NBSection(.localized("Update Checks")) {
                Picker(.localized("Check Interval"), selection: $_interval) {
                    ForEach(_intervals, id: \.0) { interval in
                        Text(.localized(interval.1)).tag(interval.0)
                    }
                }
                Toggle(isOn: $_wifiOnly) {
                    Label(.localized("Wi-Fi Only"), systemImage: "wifi")
                }
                Toggle(isOn: $_autoDownload) {
                    Label(.localized("Download Automatically"), systemImage: "arrow.down.circle")
                }
                Toggle(isOn: $_badge) {
                    Label(.localized("Badge App Icon"), systemImage: "app.badge")
                }
                Toggle(isOn: $_notifications) {
                    Label(.localized("Notify When Updates Found"), systemImage: "bell")
                }
                .onChange(of: _notifications) { enabled in
                    if enabled {
                        UpdateEngine.requestNotificationPermissionIfNeeded()
                    }
                }
            } footer: {
                Text(.localized("ASign compares your library against every configured source and lists anything newer."))
            }

            NBSection(.localized("Background Signing")) {
                Toggle(isOn: $_autoSign) {
                    Label(.localized("Auto Sign After Import"), systemImage: "signature")
                }
                Toggle(isOn: $_deleteOld) {
                    Label(.localized("Replace Old Versions"), systemImage: "arrow.triangle.swap")
                }
                Toggle(isOn: $_autoInstall) {
                    Label(.localized("Install After Signing"), systemImage: "square.and.arrow.down")
                }
                Toggle(isOn: $_chargingOnly) {
                    Label(.localized("Install Only While Charging"), systemImage: "bolt")
                }
            } footer: {
                Text(.localized("Queued signing runs one app at a time in the background, using your selected certificate."))
            }

            NBSection(.localized("Self-Heal")) {
                Toggle(isOn: $_selfHeal) {
                    Label(.localized("Keep Apps Signed"), systemImage: "arrow.triangle.2.circlepath")
                }
                Stepper(
                    "\(String.localized("Renew before expiry")): \(_renewDays) \(String.localized("days"))",
                    value: $_renewDays,
                    in: 1...14
                )
            } footer: {
                Text(.localized("ASign re-signs apps with your healthiest certificate before theirs expires, or when it is revoked."))
            }

            NBSection(.localized("Self Update")) {
                Toggle(isOn: $_selfUpdate) {
                    Label(.localized("Check for ASign Updates"), systemImage: "arrow.up.circle")
                }
                NavigationLink(destination: SelfUpdateView()) {
                    Label(.localized("Check Now"), systemImage: "magnifyingglass")
                }
            }
        }
        .onAppear {
            AutoSignQueue.shared.checkRenewals()
        }
    }
}

// MARK: - Self update sheet

struct SelfUpdateView: View {
    @StateObject private var _manager = SelfUpdateManager.shared

    var body: some View {
        NBList(.localized("Self Update")) {
            NBSection {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(.localized("Current Version"))
                        Text("\(Bundle.main.version) (\(Bundle.main.build))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    _statusView()
                }
                .padding(.vertical, 4)
            } footer: {
                Text(.localized("When a newer release is published, ASign downloads it, imports it and signs it like any other app."))
            }
        }
        .onAppear {
            if case .idle = _manager.phase {
                _manager.checkForUpdate()
            }
        }
    }

    @ViewBuilder
    private func _statusView() -> some View {
        switch _manager.phase {
        case .idle, .upToDate:
            Label(.localized("Up to Date"), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        case .checking:
            ProgressView()
        case .available(let version):
            VStack(alignment: .trailing, spacing: 4) {
                Text(version)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Button(.localized("Update")) {
                    ASHaptic.tap()
                    _manager.downloadAndImport()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .downloading, .importing:
            ProgressView()
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button(.localized("Retry")) {
                    _manager.checkForUpdate()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
    }
}
