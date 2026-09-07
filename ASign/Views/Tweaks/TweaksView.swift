//
//  TweaksView.swift
//  ASign
//
//  The Tweak Vault browser: a persistent library of injectable files with
//  folders, a Mach-O dependency analyzer, per-app auto-inject rules and
//  extraction of tweaks out of existing IPAs.
//

import SwiftUI
import NimbleViews
import NimbleExtensions

// MARK: - Root

struct TweaksView: View {
    @StateObject private var _library = TweakLibrary.shared
    @State private var _isAddingPresenting = false
    @State private var _isExtractPresenting = false
    @State private var _selectedTweak: ManagedTweak?
    @State private var _selectedFolderID: String?
    @State private var _isAddFolderPresenting = false
    @State private var _newFolderName = ""

    private var _visibleTweaks: [ManagedTweak] {
        _library.tweaks
            .filter { tweak in
                if let folderID = _selectedFolderID {
                    return tweak.folderID == folderID
                }
                return true
            }
            .sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    var body: some View {
        NBList(.localized("Tweaks")) {
            if !_library.folders.isEmpty {
                NBSection(.localized("Folders")) {
                    _folderRow(id: nil, name: .localized("All Tweaks"), count: _library.tweaks.count)
                    ForEach(_library.folders) { folder in
                        _folderRow(
                            id: folder.id,
                            name: folder.name,
                            count: _library.tweaks.filter { $0.folderID == folder.id }.count
                        )
                        .swipeActions {
                            Button(role: .destructive) {
                                _library.removeFolder(folder)
                                if _selectedFolderID == folder.id { _selectedFolderID = nil }
                            } label: {
                                Label(.localized("Delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }

            NBSection(
                .localized("Tweaks"),
                secondary: "\(_visibleTweaks.count)"
            ) {
                ForEach(_visibleTweaks) { tweak in
                    TweaksRowView(tweak: tweak)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            _selectedTweak = tweak
                        }
                }
                .onDelete { indexSet in
                    let visible = _visibleTweaks
                    for index in indexSet {
                        _library.remove(visible[index])
                    }
                }
            } footer: {
                Text(.localized("Tweaks in the vault can be injected into any signed app and can automatically inject for the apps you choose."))
            }

            Section {
                Button {
                    _isExtractPresenting = true
                } label: {
                    Label(.localized("Extract Tweaks from IPA"), systemImage: "shippingbox")
                }
            } footer: {
                Text(.localized("Pull .dylib, .deb and .framework files out of an existing app package."))
            }
        }
        .navigationTitle(.localized("Tweaks"))
        .toolbar {
            NBToolbarMenu {
                Button {
                    _isAddFolderPresenting = true
                } label: {
                    Label(.localized("New Folder"), systemImage: "folder.badge.plus")
                }
                Button {
                    _isAddingPresenting = true
                } label: {
                    Label(.localized("Import Tweaks"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $_isAddingPresenting) {
            FileImporterRepresentableView(
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onDocumentsPicked: { urls in
                    _library.importFiles(urls)
                }
            )
        }
        .sheet(isPresented: $_isExtractPresenting) {
            TweakExtractionView()
        }
        .sheet(item: $_selectedTweak) { tweak in
            TweakDetailView(tweak: tweak)
        }
        .alert(.localized("New Folder"), isPresented: $_isAddFolderPresenting) {
            TextField(.localized("Name"), text: $_newFolderName)
            Button(.localized("Create")) {
                let name = _newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                _library.addFolder(name: name)
                _newFolderName = ""
            }
            Button(.localized("Cancel"), role: .cancel) {
                _newFolderName = ""
            }
        }
    }

    @ViewBuilder
    private func _folderRow(id: String?, name: String, count: Int) -> some View {
        Button {
            _selectedFolderID = id
        } label: {
            HStack {
                Label(name, systemImage: id == nil ? "square.grid.2x2" : "folder.fill")
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                if _selectedFolderID == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Row

struct TweaksRowView: View {
    let tweak: ManagedTweak

    private var _kindSymbol: String {
        switch tweak.kind {
        case "dylib": return "shippingbox"
        case "deb": return "arrow.down.doc"
        case "framework": return "curtains.closed"
        case "bundle": return "gift"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: _kindSymbol)
                .frame(width: 22)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(tweak.fileName)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if tweak.autoInject != nil, tweak.autoInject?.mode != .off {
                        Label(.localized("Auto"), systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(tweak.kind.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct TweakDetailView: View {
    @Environment(\.dismiss) private var _dismiss
    @StateObject private var _library = TweakLibrary.shared
    @ObservedObject var tweakProxy: ManagedTweakProxy
    @State private var _analysis: TweakAnalysis?
    @State private var _isRenaming = false
    @State private var _renameText = ""

    init(tweak: ManagedTweak) {
        _tweakProxy = ObservedObject(wrappedValue: ManagedTweakProxy(tweak: tweak))
    }

    var body: some View {
        NBNavigationView(tweakProxy.tweak.fileName, displayMode: .inline) {
            NBList {
                NBSection(.localized("File")) {
                    LabeledContent(.localized("Name"), value: tweakProxy.tweak.fileName)
                    LabeledContent(.localized("Type"), value: tweakProxy.tweak.kind.uppercased())
                    LabeledContent(
                        .localized("Added"),
                        value: tweakProxy.tweak.addedAt.formatted(date: .abbreviated, time: .shortened)
                    )

                    Button {
                        _renameText = (tweakProxy.tweak.fileName as NSString).deletingPathExtension
                        _isRenaming = true
                    } label: {
                        Label(.localized("Rename"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        _library.remove(tweakProxy.tweak)
                        _dismiss()
                    } label: {
                        Label(.localized("Delete"), systemImage: "trash")
                    }
                }

                _folderSection()

                _autoInjectSection()

                NBSection(.localized("Analysis")) {
                    if let analysis = _analysis {
                        if let architecture = analysis.architecture {
                            LabeledContent(.localized("Architecture"), value: architecture)
                        }
                        LabeledContent(.localized("Load Commands"), value: "\(analysis.loadCommands)")

                        ForEach(analysis.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }

                        if !analysis.dependencies.isEmpty {
                            DisclosureGroup("\(analysis.dependencies.count) \(String.localized("dependencies"))") {
                                ForEach(analysis.dependencies, id: \.self) { dependency in
                                    Text(dependency)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        Text(.localized("Analyzing…"))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(.localized("Analysis reads the Mach-O load commands of the tweak binary."))
                }
            }
        }
        .alert(.localized("Rename"), isPresented: $_isRenaming) {
            TextField(.localized("Name"), text: $_renameText)
            Button(.localized("Rename")) {
                _library.rename(tweakProxy.tweak, displayName: _renameText)
            }
            Button(.localized("Cancel"), role: .cancel) {}
        }
        .task {
            _analysis = await Task.detached(priority: .userInitiated) {
                TweakAnalyzer.analyze(url: TweakLibrary.shared.fileURL(for: tweakProxy.tweak))
            }.value
        }
    }

    @ViewBuilder
    private func _folderSection() -> some View {
        NBSection(.localized("Folder")) {
            Picker(.localized("Folder"), selection: _folderBinding) {
                Text(.localized("None")).tag(String?.none)
                ForEach(_library.folders) { folder in
                    Text(folder.name).tag(String?.some(folder.id))
                }
            }
        }
    }

    private var _folderBinding: Binding<String?> {
        Binding(
            get: { tweakProxy.tweak.folderID },
            set: { _library.setFolder(tweakProxy.tweak, folderID: $0) }
        )
    }

    @ViewBuilder
    private func _autoInjectSection() -> some View {
        let rule = tweakProxy.tweak.autoInject

        NBSection(.localized("Auto Inject")) {
            Picker(.localized("Mode"), selection: _modeBinding) {
                Text(.localized("Off")).tag(AutoInjectRule.Mode.off)
                Text(.localized("For every app")).tag(AutoInjectRule.Mode.all)
                Text(.localized("Selected apps")).tag(AutoInjectRule.Mode.bundleList)
            }

            if rule?.mode == .bundleList {
                BundleListEditor(bundleIDs: rule?.bundleIDs ?? []) { bundleIDs in
                    _library.setAutoInject(
                        tweakProxy.tweak,
                        rule: AutoInjectRule(mode: .bundleList, bundleIDs: bundleIDs)
                    )
                }
            }
        } footer: {
            Text(.localized("Automatically inject this tweak whenever a matching app is signed."))
        }
    }

    private var _modeBinding: Binding<AutoInjectRule.Mode> {
        Binding(
            get: { tweakProxy.tweak.autoInject?.mode ?? .off },
            set: { mode in
                switch mode {
                case .off:
                    _library.setAutoInject(tweakProxy.tweak, rule: nil)
                case .all:
                    _library.setAutoInject(tweakProxy.tweak, rule: AutoInjectRule(mode: .all, bundleIDs: []))
                case .bundleList:
                    _library.setAutoInject(tweakProxy.tweak, rule: AutoInjectRule(mode: .bundleList, bundleIDs: []))
                }
            }
        )
    }
}

/// A tiny observable wrapper so the detail sheet reflects vault mutations
/// (rename, folder changes) live.
@MainActor
final class ManagedTweakProxy: ObservableObject {
    @Published var tweak: ManagedTweak

    init(tweak: ManagedTweak) {
        self.tweak = tweak
    }
}

// MARK: - Bundle list editor

struct BundleListEditor: View {
    let bundleIDs: [String]
    let onChange: ([String]) -> Void

    @State private var _newBundleID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        onChange(bundleIDs.filter { $0 != bundleID })
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("com.example.app", text: $_newBundleID)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button {
                    let trimmed = _newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onChange(bundleIDs + [trimmed])
                    _newBundleID = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(_newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Extraction

struct TweakExtractionView: View {
    @Environment(\.dismiss) private var _dismiss
    @StateObject private var _library = TweakLibrary.shared
    @State private var _isPicking = false
    @State private var _extractedCount = 0
    @State private var _isWorking = false

    var body: some View {
        NBNavigationView(.localized("Extract Tweaks"), displayMode: .inline) {
            NBList {
                Section {
                    Button {
                        _isPicking = true
                    } label: {
                        Label(.localized("Choose an IPA or ZIP"), systemImage: "shippingbox")
                    }
                    .disabled(_isWorking)

                    if _isWorking {
                        HStack {
                            ProgressView()
                            Text(.localized("Extracting…"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if _extractedCount > 0 {
                        Label(
                            String(format: String.localized("%d tweak(s) added to the vault"), _extractedCount),
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.green)
                    }
                } footer: {
                    Text(.localized("Injectable files found inside the archive are copied into the Tweaks folder."))
                }
            }
            .toolbar {
                NBToolbarButton(role: .dismiss)
            }
        }
        .sheet(isPresented: $_isPicking) {
            FileImporterRepresentableView(
                allowedContentTypes: [.archive],
                allowsMultipleSelection: false,
                onDocumentsPicked: { urls in
                    guard let url = urls.first else { return }
                    _isWorking = true
                    Task.detached(priority: .userInitiated) {
                        let extracted = TweakExtractor.extractTweaks(from: url)
                        await MainActor.run {
                            _ = _library.importFiles(extracted)
                            _extractedCount = extracted.count
                            _isWorking = false
                        }
                    }
                }
            )
        }
    }
}
