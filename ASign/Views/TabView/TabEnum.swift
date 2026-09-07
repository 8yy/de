//
//  TabEnum.swift
//  feather
//
//  Created by samara on 22.03.2025.
//

import SwiftUI
import NimbleViews

enum TabEnum: String, CaseIterable, Hashable {
    case files
        case sources
        case library
        case settings
        case certificates
        case appstore
    case downloader
    case updates
    case tweaks
        var title: String {
                switch self {
        case .files:        return .localized("Files")
                case .sources:          return .localized("Sources")
                case .library:          return .localized("Library")
                case .settings:         return .localized("Settings")
                case .certificates:     return .localized("Certificates")
                case .appstore:         return .localized("App Store")
        case .downloader:   return .localized("Downloads")
        case .updates:      return .localized("Updates")
        case .tweaks:       return .localized("Tweaks")
                }
        }
        
        var icon: String {
                switch self {
        case .files:        return "folder.fill"
                case .sources:          return "globe.desk"
                case .library:          return "square.grid.2x2"
                case .settings:         return "gearshape.2"
                case .certificates: return "person.text.rectangle"
                case .appstore:         return "plus.app.fill"
        case .downloader:    return "square.and.arrow.down.fill"
        case .updates:      return "arrow.triangle.2.circlepath.circle"
        case .tweaks:       return "syringe.fill"
                }
        }
        
        @ViewBuilder
        static func view(for tab: TabEnum) -> some View {
                switch tab {
        case .files: FilesView()
                case .sources: SourcesView()
                case .library: LibraryView()
                case .settings: SettingsView()
                case .certificates: NBNavigationView(.localized("Certificates")) { CertificatesView() }
                case .appstore: AppstoreView()
        case .downloader: DownloaderView()
        case .updates: UpdatesView()
        case .tweaks: TweaksView()
                }
        }
        
        static var defaultTabs: [TabEnum] {
                return [
            .library,
            .appstore,
            .updates,
            .downloader,
                        .settings,
                ]
        }
        
        static var customizableTabs: [TabEnum] {
                return [
            .files,
            .tweaks,
                        .certificates
                ]
        }
}
