//
//  WebManagerServer.swift
//  ASign
//
//  A local-network transfer server: upload apps, tweaks and certificates from
//  any browser, download signed apps, and mount the inbox over WebDAV.
//
//  Uploads use a raw-body API (POST /upload/<name>) rather than multipart so
//  the browser side is a single fetch() call and the server side has zero
//  dependency on multipart parsing edge cases. Authentication is HTTP Basic
//  with a constant-time comparison.
//

import Foundation
import Vapor
import Darwin
import ZIPFoundation

@MainActor
final class WebManagerController: ObservableObject {
    static let shared = WebManagerController()

    @Published private(set) var isRunning = false
    @Published private(set) var port: Int = 8080
    @Published private(set) var lastActivity: Date?

    @AppStorage("asign.webManager.enabled") private var _enabled: Bool = false
    @AppStorage("asign.webManager.username") private var _username: String = "asign"
    @AppStorage("asign.webManager.password") private var _password: String = "asign"
    @AppStorage("asign.webManager.webdav") private var _webdavEnabled: Bool = true

    private var _server: WebManagerServer?

    private init() {
        if _enabled { start() }
    }

    var url: URL? {
        guard isRunning else { return nil }
        return URL(string: "http://\(Self.lanIPAddress()):\(port)/")
    }

    func start() {
        guard !isRunning else { return }
        let server = WebManagerServer(
            username: _username,
            password: _password,
            webdavEnabled: _webdavEnabled
        )
        do {
            try server.start(port: port)
            _server = server
            isRunning = true
            ActivityLog.shared.add(.info, title: String.localized("Web Manager started"), detail: "port \(port)")
        } catch {
            // Port already taken: try a random high port once.
            let fallback = Int.random(in: 18080...29000)
            do {
                try server.start(port: fallback)
                _server = server
                port = fallback
                isRunning = true
            } catch {
                ActivityLog.shared.add(.failed, title: String.localized("Web Manager failed"), detail: error.localizedDescription)
            }
        }
    }

    func stop() {
        _server?.stop()
        _server = nil
        isRunning = false
        ActivityLog.shared.add(.info, title: String.localized("Web Manager stopped"))
    }

    func setEnabled(_ enabled: Bool) {
        _enabled = enabled
        enabled ? start() : stop()
    }

    static func lanIPAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            guard
                let interface = current.pointee.ifa_addr,
                (current.pointee.ifa_flags & UInt32(bitPattern: IFF_UP)) != 0,
                (current.pointee.ifa_flags & UInt32(bitPattern: IFF_LOOPBACK)) == 0
            else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface,
                socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let name = String(cString: hostname)
            if current.pointee.ifa_name.map({ String(cString: $0 }).hasPrefix("en")) == true,
               name.contains(".") {
                return name
            }
            if name.contains(".") {
                address = name
            }
        }
        return address
    }
}

// MARK: - Server

final class WebManagerServer {
    private let _username: String
    private let _password: String
    private let _webdavEnabled: Bool
    private var _app: Application?

    private var _inboxURL: URL {
        URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
    }

    init(username: String, password: String, webdavEnabled: Bool) {
        _username = username
        _password = password
        _webdavEnabled = webdavEnabled
    }

    func start(port: Int) throws {
        var env = Environment(name: "vapor", arguments: ["vapor"])
        try LoggingSystem.bootstrap(from: &env)

        let app = Application(env)
        app.threadPool = .init(numberOfThreads: 2)
        app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
        app.http.server.configuration.port = port
        app.routes.defaultMaxBodySize = "4gb"

        _configure(app)

        try app.boot()
        // Non-blocking start: the run loop is Vapor's own.
        try app.server.start()
        _app = app

        try FileManager.default.createDirectoryIfNeeded(at: _inboxURL)
    }

    func stop() {
        _app?.server.shutdown()
        _app?.shutdown()
        _app = nil
    }

    deinit {
        _app?.server.shutdown()
        _app?.shutdown()
        _app = nil
    }

    // MARK: Routes

    private func _configure(_ app: Application) {
        // One handler, every method the browser page and the WebDAV verbs need.
        let methods: [Request.Method] = [
            .GET, .POST, .PUT, .DELETE, .MOVE, .COPY,
            .raw("PROPFIND"), .raw("MKCOL"), .raw("HEAD"),
        ]

        for method in methods {
            app.on(method, "*") { [weak self] req -> Response in
                guard let self else { return Response(status: .serviceUnavailable) }
                return self._route(req)
            }
        }
    }

    private func _route(_ req: Request) -> Response {
        guard _authorize(req) else {
            return Response(
                status: .unauthorized,
                headers: ["WWW-Authenticate": "Basic realm=\"ASign\""]
            )
        }

        let path = req.url.path

        if req.method == .GET || req.method == .HEAD {
            if path == "/" || path.hasPrefix("/index") {
                return Response(status: .ok, headers: ["Content-Type": "text/html"], body: .init(string: Self.html))
            }

            if path == "/api/files" {
                let json = _filesJSON()
                return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: json))
            }

            if path.hasPrefix("/api/apps/") {
                let identifier = path.dropFirst("/api/apps/".count)
                return _serveApp(req, identifier: String(identifier))
            }

            if path.hasPrefix("/api/file/") {
                let name = String(path.dropFirst("/api/file/".count)).removingPercentEncoding ?? ""
                return _serveInboxFile(req, name)
            }
        }

        if req.method == .POST {
            if path.hasPrefix("/upload/") {
                let rawName = String(path.dropFirst("/upload/".count)).removingPercentEncoding ?? ""
                return _handleUpload(req, name: rawName)
            }
        }

        if req.method == .DELETE {
            if path.hasPrefix("/api/file/") {
                let name = String(path.dropFirst("/api/file/".count)).removingPercentEncoding ?? ""
                return _deleteInboxFile(name)
            }
        }

        if _webdavEnabled, let davResponse = _handleWebDAV(req) {
            return davResponse
        }

        return Response(status: .notFound)
    }

    // MARK: Auth

    private func _authorize(_ req: Request) -> Bool {
        guard let header = req.headers.first(name: "Authorization") else { return false }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "basic" else { return false }

        guard let decoded = Data(base64Encoded: String(parts[1])), let credentials = String(data: decoded, encoding: .utf8) else {
            return false
        }

        return Self.constantTimeCompare(credentials, "\(_username):\(_password)")
    }

    nonisolated static func constantTimeCompare(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        var mismatch = left.count ^ right.count

        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            mismatch |= Int(l ^ r)
        }
        return mismatch == 0
    }

    // MARK: Routing helpers

    private func _handleUpload(_ req: Request, name rawName: String) -> Response {
        let name = (rawName as NSString).lastPathComponent
        guard !name.isEmpty else { return Response(status: .badRequest) }
        guard let byteBuffer = req.body.data, let data = byteBuffer.getData(at: 0, length: byteBuffer.readableBytes) else {
            return Response(status: .badRequest)
        }

        DispatchQueue.main.async {
            Task { @MainActor in
                WebManagerController.shared.lastActivity = Date()
            }
        }

        let ext = (name as NSString).pathExtension.lowercased()

        // Apps go straight into the library.
        if ext == "ipa" || ext == "tipa" {
            let staged = fm.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: staged, options: .atomic)
            } catch {
                return Response(status: .internalServerError)
            }
            FR.handlePackageFile(staged) { _ in }
            return Response(status: .ok, body: .init(string: "imported"))
        }

        // Certificates: p12 + provision + optional password file.
        if ext == "p12" || ext == "mobileprovision" {
            let certDir = fm.temporaryDirectory.appendingPathComponent("WebCert_\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectoryIfNeeded(at: certDir)
            let fileURL = certDir.appendingPathComponent(name)
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                return Response(status: .internalServerError)
            }
            _tryImportCertificate(from: certDir, name: name)
            return Response(status: .ok, body: .init(string: "certificate staged"))
        }

        // Tweaks and everything else land in the vault or the inbox.
        if ["dylib", "deb", "framework", "bundle", "zip"].contains(ext) {
            let staged = _stagedURL(data: data, name: name)
            // TweakLibrary is main-actor isolated; hop over and return the
            // request immediately — the vault import is a file copy.
            DispatchQueue.main.async {
                _ = TweakLibrary.shared.importFiles([staged])
            }
            return Response(status: .ok, body: .init(string: "tweak"))
        }

        try? FileManager.default.createDirectoryIfNeeded(at: _inboxURL)
        do {
            try data.write(to: _inboxURL.appendingPathComponent(name), options: .atomic)
        } catch {
            return Response(status: .internalServerError)
        }
        return Response(status: .ok, body: .init(string: "inbox"))
    }

    private let fm = FileManager.default

    private func _stagedURL(data: Data, name: String) -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("WebTweak_\(UUID().uuidString)_\(name)")
        try? data.write(to: url, options: .atomic)
        return url
    }

    /// A certificate is complete once both a p12 and a mobileprovision with a
    /// matching base name are staged. Waits for the second file, then imports.
    private func _tryImportCertificate(from directory: URL, name: String) {
        let base = (name as NSString).deletingPathExtension
        let p12 = directory.appendingPathComponent("\(base).p12")
        let provision = directory.appendingPathComponent("\(base).mobileprovision")

        guard FileManager.default.fileExists(atPath: p12.path) else { return }
        guard FileManager.default.fileExists(atPath: provision.path) else { return }

        // Password file is optional; browsers that renamed the upload keep the
        // conventional cert.txt sibling.
        let passwordFile = directory.appendingPathComponent("\(base).txt")
        let password = (try? String(contentsOf: passwordFile, encoding: .utf8)) ?? ""

        FR.handleCertificateFiles(
            p12URL: p12,
            provisionURL: provision,
            p12Password: password,
            certificateName: base
        ) { _ in }
    }

    private func _filesJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        struct RemoteFile: Encodable {
            var name: String
            var size: Int64
            var kind: String
        }

        var files: [RemoteFile] = []

        if let inbox = try? fm.contentsOfDirectory(at: _inboxURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for url in inbox {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                files.append(RemoteFile(name: url.lastPathComponent, size: Int64(size), kind: "inbox"))
            }
        }

        let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        let signed = (try? Storage.shared.context.fetch(signedRequest)) ?? []
        for app in signed {
            files.append(
                RemoteFile(
                    name: "\(app.name ?? app.uuid ?? "App") (\(app.version ?? "?"))",
                    size: 0,
                    kind: "app|signed|\(app.uuid ?? "")"
                )
            )
        }

        let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
        let imported = (try? Storage.shared.context.fetch(importedRequest)) ?? []
        for app in imported {
            files.append(
                RemoteFile(
                    name: "\(app.name ?? app.uuid ?? "App") (\(app.version ?? "?"))",
                    size: 0,
                    kind: "app|imported|\(app.uuid ?? "")"
                )
            )
        }

        guard let data = try? encoder.encode(files), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func _serveApp(_ req: Request, identifier: String) -> Response {
        let signedRequest: NSFetchRequest<Signed> = Signed.fetchRequest()
        signedRequest.predicate = NSPredicate(format: "uuid == %@", identifier)
        var appUrl = ((try? Storage.shared.context.fetch(signedRequest))?.first).flatMap {
            Storage.shared.getAppDirectory(for: $0)
        }

        if appUrl == nil {
            let importedRequest: NSFetchRequest<Imported> = Imported.fetchRequest()
            importedRequest.predicate = NSPredicate(format: "uuid == %@", identifier)
            appUrl = ((try? Storage.shared.context.fetch(importedRequest))?.first).flatMap {
                Storage.shared.getAppDirectory(for: $0)
            }
        }

        guard let appURL = appUrl else {
            return Response(status: .notFound)
        }

        // Zip the bundle on demand, then stream it.
        let archiveURL = fm.temporaryDirectory.appendingPathComponent("WebExport_\(UUID().uuidString).ipa")
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            let bundleName = appURL.lastPathComponent
            let contents = try fm.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil)
            for item in contents {
                let relative = "\(bundleName)/\(item.lastPathComponent)"
                if item.hasDirectoryPath {
                    try _addDirectory(item, relativePrefix: relative, to: archive)
                } else {
                    try archive.addEntry(with: relative, relativeTo: appURL)
                }
            }
        } catch {
            return Response(status: .internalServerError)
        }

        return req.fileio.streamFile(at: archiveURL.path) { [weak self] result in
            if case .success = result {
                try? self?.fm.removeItem(at: archiveURL)
            }
        }
    }

    private func _addDirectory(_ directory: URL, relativePrefix: String, to archive: Archive) throws {
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in contents {
            let relative = "\(relativePrefix)/\(item.lastPathComponent)"
            if item.hasDirectoryPath {
                try _addDirectory(item, relativePrefix: relative, to: archive)
            } else {
                try archive.addEntry(with: relative, relativeTo: directory)
            }
        }
    }

    private func _serveInboxFile(_ req: Request, _ name: String) -> Response {
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else {
            return Response(status: .badRequest)
        }
        let url = _inboxURL.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else {
            return Response(status: .notFound)
        }
        return req.fileio.streamFile(at: url.path)
    }

    private func _deleteInboxFile(_ name: String) -> Response {
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else {
            return Response(status: .badRequest)
        }
        let url = _inboxURL.appendingPathComponent(name)
        guard fm.fileExists(atPath: url.path) else {
            return Response(status: .notFound)
        }
        try? fm.removeItem(at: url)
        return Response(status: .ok)
    }

    // MARK: WebDAV (minimal)

    /// Supports the verbs Finder and Files need to mount the inbox as a
    /// network volume: PROPFIND, GET, PUT, DELETE, MKCOL, MOVE.
    private func _handleWebDAV(_ req: Request) -> Response? {
        let path = req.url.path
        guard path.hasPrefix("/dav") else { return nil }

        let relative = String(path.dropFirst("/dav".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.contains("..") else { return Response(status: .forbidden) }

        let target = relative.isEmpty ? _inboxURL : _inboxURL.appendingPathComponent(relative)

        switch req.method {
        case .GET, .HEAD:
            guard fm.fileExists(atPath: target.path) else { return Response(status: .notFound) }
            if target.hasDirectoryPath { return Response(status: .ok) }
            return req.fileio.streamFile(at: target.path)

        case .PUT:
            guard !target.hasDirectoryPath, let body = req.body.data else { return Response(status: .badRequest) }
            try? FileManager.default.createDirectoryIfNeeded(at: target.deletingLastPathComponent())
            guard let data = body.getData(at: 0, length: body.readableBytes) else { return Response(status: .badRequest) }
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                return Response(status: .internalServerError)
            }
            return Response(status: .created)

        case .MKCOL:
            do {
                try FileManager.default.createDirectoryIfNeeded(at: target)
            } catch {
                return Response(status: .internalServerError)
            }
            return Response(status: .created)

        case .DELETE:
            guard fm.fileExists(atPath: target.path) else { return Response(status: .notFound) }
            try? fm.removeItem(at: target)
            return Response(status: .noContent)

        case .MOVE, .COPY:
            guard let destinationHeader = req.headers.first(name: "Destination") else {
                return Response(status: .badRequest)
            }
            guard let destinationURL = URL(string: destinationHeader) else { return Response(status: .badRequest) }
            let davRelative = destinationURL.path.hasPrefix("/dav")
                ? String(destinationURL.path.dropFirst("/dav".count))
                : destinationURL.path
            let destination = _inboxURL.appendingPathComponent(
                davRelative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )

            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                if req.method == .MOVE {
                    try fm.moveItem(at: target, to: destination)
                } else {
                    try fm.copyItem(at: target, to: destination)
                }
            } catch {
                return Response(status: .internalServerError)
            }
            return Response(status: .created)

        case .PROPFIND:
            let depth = req.headers.first(name: "Depth") ?? "0"
            var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
            xml += _propFindEntry(target, isRoot: relative.isEmpty)

            if depth == "1", target.hasDirectoryPath,
               let contents = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil) {
                for item in contents {
                    xml += _propFindEntry(item, isRoot: false)
                }
            }
            xml += "</D:multistatus>\n"

            return Response(
                status: .multiStatus,
                headers: ["Content-Type": "application/xml; charset=utf-8"],
                body: .init(string: xml)
            )

        default:
            return Response(status: .methodNotAllowed)
        }
    }

    private func _propFindEntry(_ url: URL, isRoot: Bool) -> String {
        let name = isRoot ? "Inbox" : url.lastPathComponent
        let isDirectory = url.hasDirectoryPath

        var size = "0"
        if !isDirectory, let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let bytes = values.fileSize {
            size = String(bytes)
        }

        let resourceType = isDirectory ? "<D:collection/>" : ""
        return """
        <D:response>
          <D:href>/dav/\(name)</D:href>
          <D:propstat>
            <D:prop>
              <D:displayname>\(name)</D:displayname>
              <D:resourcetype>\(resourceType)</D:resourcetype>
              <D:getcontentlength>\(size)</D:getcontentlength>
            </D:prop>
            <D:status>HTTP/1.1 200 OK</D:status>
          </D:propstat>
        </D:response>
        """
    }
}

// MARK: - Browser page

extension WebManagerServer {
    static let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>ASign Web Manager</title>
    <style>
      :root { color-scheme: dark; }
      body { font-family: -apple-system, system-ui, sans-serif; background: #101014; color: #f2f2f7; margin: 0; padding: 24px; }
      h1 { font-size: 22px; margin: 0 0 4px; }
      p.sub { color: #8e8e93; margin: 0 0 24px; font-size: 14px; }
      .card { background: #1c1c22; border: 1px solid #2c2c32; border-radius: 16px; padding: 16px; margin-bottom: 16px; }
      input[type=file] { color: #8e8e93; }
      button { background: #7c6ff0; color: white; border: 0; border-radius: 10px; padding: 10px 16px; font-size: 15px; font-weight: 600; }
      button:disabled { opacity: .5; }
      ul { list-style: none; padding: 0; margin: 8px 0 0; }
      li { display: flex; justify-content: space-between; align-items: center; padding: 8px 0; border-bottom: 1px solid #2c2c32; font-size: 14px; }
      li:last-child { border-bottom: 0; }
      a { color: #a99ef7; text-decoration: none; }
      .muted { color: #8e8e93; }
      .del { background: none; color: #ff6b6b; font-size: 13px; padding: 4px 8px; }
    </style>
    </head>
    <body>
      <h1>ASign Web Manager</h1>
      <p class="sub">Transfer apps, tweaks and certificates over your local network.</p>

      <div class="card">
        <strong>Send to device</strong>
        <p class="muted">.ipa / .tipa are imported into the library. .dylib / .deb / .framework / .zip go to the Tweaks vault. .p12 + .mobileprovision import as a certificate (use matching base names, plus a .txt file for the password).</p>
        <input type="file" id="file" multiple>
        <button id="upload" onclick="upload()">Upload</button>
        <span class="muted" id="status"></span>
      </div>

      <div class="card">
        <strong>On device</strong>
        <ul id="files"></ul>
      </div>

      <script>
      async function refresh() {
        const res = await fetch('/api/files');
        const files = await res.json();
        const list = document.getElementById('files');
        list.innerHTML = '';
        for (const f of files) {
          const li = document.createElement('li');
          if (f.kind.startsWith('app')) {
            const parts = f.kind.split('|');
            li.innerHTML = `<span>${f.name} <span class="muted">(${parts[1]})</span></span>` +
              `<a href="/api/apps/${parts[2]}">Download .ipa</a>`;
          } else {
            li.innerHTML = `<span>${f.name} <span class="muted">${(f.size/1048576).toFixed(1)} MB</span></span>` +
              `<span><a href="/api/file/${encodeURIComponent(f.name)}">Get</a> ` +
              `<button class="del" onclick="del('${encodeURIComponent(f.name)}')">Delete</button></span>`;
          }
          list.appendChild(li);
        }
      }
      async function upload() {
        const input = document.getElementById('file');
        const status = document.getElementById('status');
        const button = document.getElementById('upload');
        if (!input.files.length) { status.textContent = 'No file selected'; return; }
        button.disabled = true;
        for (const file of input.files) {
          status.textContent = `Uploading ${file.name}…`;
          const res = await fetch('/upload/' + encodeURIComponent(file.name), { method: 'POST', body: file });
          if (!res.ok) { status.textContent = `Failed: ${file.name}`; button.disabled = false; return; }
        }
        status.textContent = 'Done';
        button.disabled = false;
        input.value = '';
        refresh();
      }
      async function del(name) {
        await fetch('/api/file/' + name, { method: 'DELETE' });
        refresh();
      }
      refresh();
      </script>
    </body>
    </html>
    """
}
