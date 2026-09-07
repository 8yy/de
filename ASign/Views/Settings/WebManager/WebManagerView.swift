//
//  WebManagerView.swift
//  ASign
//
//  Settings UI for the Web Manager transfer server.
//

import SwiftUI
import NimbleViews

struct WebManagerView: View {
    @StateObject private var _controller = WebManagerController.shared
    @AppStorage("asign.webManager.username") private var _username: String = "asign"
    @AppStorage("asign.webManager.password") private var _password: String = "asign"
    @AppStorage("asign.webManager.webdav") private var _webdav: Bool = true

    var body: some View {
        NBList(.localized("Web Manager")) {
            Section {
                Toggle(isOn: Binding(
                    get: { _controller.isRunning },
                    set: { _controller.setEnabled($0) }
                )) {
                    Label(.localized("Enable Server"), systemImage: "antenna.radiowaves.left.and.right")
                }
            } footer: {
                Text(.localized("Transfer apps, tweaks and certificates over your local network from any browser. Apps sent here are imported into your library automatically."))
            }

            if _controller.isRunning {
                NBSection(.localized("Connection")) {
                    LabeledContent(.localized("URL"), value: _controller.url?.absoluteString ?? "—")
                        .textSelection(.enabled)
                    LabeledContent(.localized("Port"), value: "\(_controller.port)")

                    Button {
                        UIPasteboard.general.string = _controller.url?.absoluteString
                        ASHaptic.tap()
                    } label: {
                        Label(.localized("Copy URL"), systemImage: "doc.on.doc")
                    }
                }

                NBSection(.localized("WebDAV")) {
                    Toggle(isOn: $_webdav) {
                        Label(.localized("WebDAV Mount"), systemImage: "externaldrive.connected.to.line.below")
                    }
                    if _webdav {
                        LabeledContent(
                            .localized("Address"),
                            value: "http://\(WebManagerController.lanIPAddress()):\(_controller.port)/dav/"
                        )
                        .textSelection(.enabled)
                    }
                } footer: {
                    Text(.localized("Mount the transfer inbox in the Files app or Finder over WebDAV."))
                }
            }

            NBSection(.localized("Authentication")) {
                TextField(.localized("Username"), text: $_username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(.localized("Password"), text: $_password)
            } footer: {
                Text(.localized("Requests are authenticated with HTTP Basic; credentials are compared in constant time."))
            }
        }
        .onChange(of: _webdav) { _ in
            // Restart the server so the routing table picks up WebDAV changes.
            if _controller.isRunning {
                _controller.stop()
                _controller.start()
            }
        }
    }
}
