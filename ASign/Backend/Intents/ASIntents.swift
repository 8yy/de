//
//  ASIntents.swift
//  ASign
//
//  Shortcuts-app entry points for the automation engine.
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct CheckUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Check for Updates"
    static var description = IntentDescription("Check every configured source for app updates")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UpdateEngine.shared.checkForUpdates(showResults: true)

        // Give the network pass a moment, then report the snapshot.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let count = await UpdateEngine.shared.updates.count

        if count == 0 {
            return .result(dialog: "All apps are up to date")
        }
        return .result(dialog: "\(count) update(s) available")
    }
}

@available(iOS 16.0, *)
struct InstallPendingUpdatesIntent: AppIntent {
    static var title: LocalizedStringResource = "Install Pending Updates"
    static var description = IntentDescription("Download and install every pending app update")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let engine = UpdateEngine.shared
        engine.checkForUpdates(showResults: false)
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let count = await engine.updates.count
        guard count > 0 else {
            return .result(dialog: "All apps are up to date")
        }

        engine.downloadAllPendingUpdates()
        return .result(dialog: "Downloading \(count) update(s)")
    }
}

@available(iOS 16.0, *)
struct SignLatestAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Signing Queue"
    static var description = IntentDescription("Process anything queued in the background signing queue")

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AutoSignQueue.shared.checkRenewals()
        return .result(dialog: "Signing queue processed")
    }
}
