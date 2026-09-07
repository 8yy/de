//
//  UpdatesView.swift
//  ASign
//
//  The Updates tab: pending updates across every source with per-update
//  controls, automation status cards, and the held/skipped registry.
//

import SwiftUI
import NimbleViews

struct UpdatesView: View {
    @StateObject private var _engine = UpdateEngine.shared
    @StateObject private var _queue = AutoSignQueue.shared

    var body: some View {
        NBNavigationView(.localized("Updates")) {
            NBList {
                _automationCard()

                if _engine.isChecking {
                    NBSection {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(.localized("Checking sources…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if _engine.updates.isEmpty {
                    NBSection {
                        _emptyState()
                    }
                } else {
                    NBSection(
                        .localized("Available Updates"),
                        secondary: "\(_engine.updates.count)"
                    ) {
                        ForEach(_engine.updates) { update in
                            _updateRow(update)
                        }
                    } footer: {
                        Text(.localized("Updates keep your installed apps on the latest version from their source."))
                    }
                }

                if !_queue.pending.isEmpty {
                    NBSection(.localized("Signing Queue"), secondary: "\(_queue.pending.count)") {
                        ForEach(_queue.pending) { job in
                            HStack {
                                Image(systemName: "signature")
                                    .foregroundStyle(.tint)
                                Text(job.app.name ?? job.app.identifier ?? "Unknown")
                                    .lineLimit(1)
                                Spacer()
                                Text(job.reason.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                _heldSection()
            }
        }
        .refreshable {
            _engine.checkForUpdates(showResults: false)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func _automationCard() -> some View {
        NBSection {
            HStack {
                ASIconTile(symbol: "arrow.triangle.2.circlepath", tint: .indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(.localized("Automatic Updates"))
                        .font(.subheadline.weight(.semibold))
                    Text(_intervalText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _engine.checkForUpdates(showResults: true)
                    ASHaptic.tap()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.asPressable)
            }
            .padding(.vertical, 4)
        }
    }

    private var _intervalText: String {
        let interval = UserDefaults.standard.integer(forKey: "asign.autoUpdateInterval")
        guard interval > 0 else { return String.localized("Automatic checks are off") }
        return String(format: String.localized("Every %d h · %d pending"), interval, _engine.updates.count)
    }

    @ViewBuilder
    private func _emptyState() -> some View {
        if #available(iOS 17, *) {
            ContentUnavailableView {
                Label(.localized("All Apps Up to Date"), systemImage: "checkmark.seal.fill")
            } description: {
                Text(.localized("Nothing to update right now. ASign checks your sources automatically."))
            }
            .frame(minHeight: 220)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text(.localized("All Apps Up to Date"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 42)
        }
    }

    @ViewBuilder
    private func _updateRow(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "app.gift")
                    .font(.title3)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(update.appName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text("\(update.localVersion) → \(update.remoteVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    ASHaptic.tap()
                    _engine.download(update)
                } label: {
                    Text(.localized("Update"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(.accentColor.opacity(0.22)))
                }
                .buttonStyle(.asPressable)
            }

            if let whatsNew = update.whatsNew, !whatsNew.isEmpty {
                Text(whatsNew)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 14) {
                Button(.localized("Skip This Version")) {
                    _engine.skipThisVersion(update)
                }
                Button(.localized("Hold Updates")) {
                    _engine.holdUpdates(for: update)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func _heldSection() -> some View {
        let held = _engine.heldBundleIDs()
        if !held.isEmpty {
            NBSection(.localized("Held Updates")) {
                ForEach(held, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Button(.localized("Resume")) {
                            _engine.resumeUpdates(forBundleID: bundleID)
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
