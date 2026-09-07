//
//  DownloadControlIntents.swift
//  ASign
//
//  Live Activity controls for pausing and resuming downloads. This file is
//  compiled into BOTH the app and the widget extension, so it must not
//  reference any app-only types: the intents simply broadcast a notification,
//  and DownloadManager (app side) observes it. The system performs
//  LiveActivityIntents in the app's process.
//

import AppIntents
import Foundation

@available(iOS 17.0, *)
struct PauseDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause Downloads"
    static var description = IntentDescription("Pause all active ASign downloads")

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .init("asign.pauseDownloads"), object: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
struct ResumeDownloadsIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Resume Downloads"
    static var description = IntentDescription("Resume paused ASign downloads")

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .init("asign.resumeDownloads"), object: nil)
        return .result()
    }
}
