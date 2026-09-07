//
//  ActivityLog.swift
//  ASign
//
//  A compact, JSON-persisted timeline of what the signer did and when:
//  checks, downloads, signing, installs, renewals and failures.
//

import Foundation
import SwiftUI

struct ActivityEntry: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case updateCheck, downloading, signed, installed, renewed, failed, queued, info
    }

    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var detail: String?
    var date: Date = Date()

    var symbolName: String {
        switch kind {
        case .updateCheck: return "magnifyingglass"
        case .downloading: return "arrow.down.circle"
        case .signed: return "signature"
        case .installed: return "square.and.arrow.down"
        case .renewed: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .queued: return "clock"
        case .info: return "info.circle"
        }
    }

    var tint: Color {
        switch kind {
        case .updateCheck: return .blue
        case .downloading: return .cyan
        case .signed: return .green
        case .installed: return .mint
        case .renewed: return .orange
        case .failed: return .red
        case .queued: return .secondary
        case .info: return .gray
        }
    }
}

@MainActor
final class ActivityLog: ObservableObject {
    static let shared = ActivityLog()

    @Published private(set) var entries: [ActivityEntry] = []

    private static let _key = "asign.activityLog"
    private static let _limit = 200

    private init() {
        if
            let data = UserDefaults.standard.data(forKey: Self._key),
            let decoded = try? JSONDecoder().decode([ActivityEntry].self, from: data)
        {
            entries = decoded
        }
    }

    func add(_ kind: ActivityEntry.Kind, title: String, detail: String? = nil) {
        entries.insert(ActivityEntry(kind: kind, title: title, detail: detail), at: 0)
        if entries.count > Self._limit {
            entries.removeLast(entries.count - Self._limit)
        }
        _persist()
    }

    func clear() {
        entries.removeAll()
        _persist()
    }

    private func _persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self._key)
        }
    }
}
