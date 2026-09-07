//
//  InfoPlistEditorView.swift
//  ASign
//
//  Raw Info.plist override editor for a signing session: edits an XML plist
//  whose top-level keys are merged into the signed app's Info.plist, with
//  validation so a malformed document is rejected before it can break a
//  signature.
//

import SwiftUI
import NimbleViews

struct InfoPlistEditorView: View {
    @Binding var overridesXML: String
    @State private var _editorText: String = ""
    @State private var _validationError: String?
    @State private var _isValid = true

    var body: some View {
        NBList(.localized("Info.plist Overrides")) {
            NBSection {
                TextEditor(text: $_editorText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text(.localized("XML plist"))
            } footer: {
                Text(.localized("Top-level keys here are merged over the app's Info.plist after all other options are applied. Values are written as-is, so arrays and dictionaries work too."))
            }

            NBSection {
                Button {
                    _validate()
                } label: {
                    Label(.localized("Validate"), systemImage: "checkmark.seal")
                }

                Button(role: .destructive) {
                    _editorText = ""
                    overridesXML = ""
                    _isValid = true
                    _validationError = nil
                } label: {
                    Label(.localized("Clear Overrides"), systemImage: "trash")
                }
            }

            if let error = _validationError {
                NBSection {
                    Label(error, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .onAppear {
            if _editorText.isEmpty && !overridesXML.isEmpty {
                _editorText = overridesXML
            }
        }
        .toolbar {
            NBToolbarButton(.localized("Apply"), style: .text) {
                _validate()
                guard _isValid else { return }
                overridesXML = _editorText
                ASHaptic.success()
            }
        }
    }

    private func _validate() {
        guard !_editorText.isEmpty else {
            _isValid = true
            _validationError = nil
            return
        }

        guard let data = _editorText.data(using: .utf8) else {
            _isValid = false
            _validationError = String.localized("The document is not valid UTF-8")
            return
        }

        do {
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard plist is [String: Any] else {
                _isValid = false
                _validationError = String.localized("The root element must be a dictionary")
                return
            }
            _isValid = true
            _validationError = nil
        } catch {
            _isValid = false
            _validationError = error.localizedDescription
        }
    }
}
