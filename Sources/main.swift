// CraftUpdater: updates Artcraft's macOS apps (WordCraft, PdfCraft, ...) when they open.
//
// Doesn't run in the background: launchd starts it when a Craft app opens (an app whose bundle
// id starts with `ai.storyteller.`), and it exits when done. It asks GitHub for that app's
// latest release. If it's newer, it asks right away: Update or Cancel. On Update it downloads
// the macOS DMG (with a progress window), checks it against the release's SHA256SUMS.txt,
// Apple's notarization check and Artcraft's signing team, then quits, updates and reopens the app.
//
// Flags:
//   --status              print installed vs latest version for each Craft app, then exit
//   --simulate <app>      run the full download/verify/install path against a copy of an
//                         app, treating it as version 0.0.0 (no dialog), then exit

import AppKit
import CryptoKit
import Foundation

let bundlePrefix = "ai.storyteller."
let githubOwner = "storytold"
let artcraftTeamID = "DJ6XS33FX8"

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/CraftUpdater.log")

func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Versions

func parseVersion(_ s: String) -> [Int] {
    let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
    let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
    return core.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
}

func isNewer(_ a: [Int], than b: [Int]) -> Bool {
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - Shell and HTTP helpers

@discardableResult
func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.timeoutIntervalForResource = 30 * 60
    c.httpAdditionalHeaders = ["User-Agent": "CraftUpdater/1.0"]
    return URLSession(configuration: c)
}()

func httpGet(_ url: URL, accept: String) throws -> Data {
    var req = URLRequest(url: url)
    req.setValue(accept, forHTTPHeaderField: "Accept")
    var result: Result<Data, Error> = .failure(UpdateError("no response"))
    let done = DispatchSemaphore(value: 0)
    session.dataTask(with: req) { data, response, error in
        defer { done.signal() }
        if let error { result = .failure(error); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let data else {
            result = .failure(UpdateError("HTTP \(status) for \(url.absoluteString)"))
            return
        }
        result = .success(data)
    }.resume()
    done.wait()
    return try result.get()
}

/// Lets the user stop a download from the progress window.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (() -> Void)?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() {
        lock.lock(); cancelled = true; let f = onCancel; lock.unlock()
        f?()
    }
    func whenCancelled(_ f: @escaping () -> Void) {
        lock.lock(); onCancel = f; let now = cancelled; lock.unlock()
        if now { f() }
    }
}

let cancelledByUser = UpdateError("cancelled")

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let dest: URL
    let progress: (Double?) -> Void
    var failure: Error?
    let done = DispatchSemaphore(value: 0)
    init(dest: URL, progress: @escaping (Double?) -> Void) { self.dest = dest; self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            failure = UpdateError("HTTP \(status) downloading \(dest.lastPathComponent)")
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, failure == nil { failure = error }
        done.signal()
    }
}

func download(_ url: URL, to dest: URL, cancel: CancelFlag, progress: @escaping (Double?) -> Void) throws {
    let delegate = DownloadDelegate(dest: dest, progress: progress)
    let s = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
    defer { s.finishTasksAndInvalidate() }
    let task = s.downloadTask(with: url)
    cancel.whenCancelled { task.cancel() }
    task.resume()
    delegate.done.wait()
    if cancel.isCancelled { throw cancelledByUser }
    if let failure = delegate.failure { throw failure }
}

func sha256(of file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: - Releases

struct CraftApp {
    let bundleID: String
    let url: URL
    var name: String { (bundleID.dropFirst(bundlePrefix.count)).lowercased() }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var version: String {
        (Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }
}

struct Release {
    let tag: String
    let dmgName: String
    let dmgURL: URL
    let sumsURL: URL
}

func latestRelease(for app: CraftApp) throws -> Release {
    guard let api = URL(string: "https://api.github.com/repos/\(githubOwner)/\(app.name)/releases/latest") else {
        throw UpdateError("bad repo name \(app.name)")
    }
    let data = try httpGet(api, accept: "application/vnd.github+json")
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = json["tag_name"] as? String,
          let assets = json["assets"] as? [[String: Any]] else {
        throw UpdateError("unexpected release JSON for \(app.name)")
    }
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    let dmgName = "\(app.name)-\(version)-macos-universal.dmg"
    func asset(_ name: String) -> URL? {
        assets.first { ($0["name"] as? String) == name }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
    }
    guard let dmg = asset(dmgName) else { throw UpdateError("release \(tag) has no \(dmgName)") }
    guard let sums = asset("SHA256SUMS.txt") else { throw UpdateError("release \(tag) has no SHA256SUMS.txt") }
    return Release(tag: tag, dmgName: dmgName, dmgURL: dmg, sumsURL: sums)
}

// MARK: - Download, verify, stage, install

/// Downloads and verifies the release, and copies the new app next to the installed one as
/// `.<Name>.app.update` (same volume, so the final swap is a rename). Returns that path.
func stageUpdate(for app: CraftApp, release: Release, cancel: CancelFlag = CancelFlag(),
                 status: @escaping (String, Double?) -> Void = { _, _ in }) throws -> URL {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("CraftUpdater-\(app.name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }

    let dmg = work.appendingPathComponent(release.dmgName)
    log("\(app.displayName): downloading \(release.dmgName)")
    status("Downloading \(app.displayName) \(release.tag)…", 0)
    try download(release.dmgURL, to: dmg, cancel: cancel) { status("Downloading \(app.displayName) \(release.tag)…", $0) }
    status("Checking the download…", nil)

    let sums = String(decoding: try httpGet(release.sumsURL, accept: "text/plain"), as: UTF8.self)
    let expected = sums.split(separator: "\n").compactMap { line -> String? in
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let file = parts[1].hasPrefix("*") ? parts[1].dropFirst() : parts[1]
        return file == release.dmgName ? String(parts[0]).lowercased() : nil
    }.first
    guard let expected else { throw UpdateError("no checksum listed for \(release.dmgName)") }
    let actual = try sha256(of: dmg)
    guard actual == expected else { throw UpdateError("checksum mismatch for \(release.dmgName)") }

    let mount = work.appendingPathComponent("mnt")
    let attach = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                          "-mountpoint", mount.path, dmg.path])
    guard attach.status == 0 else { throw UpdateError("couldn't open the DMG: \(attach.output)") }
    defer { run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

    let candidates = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
    guard let newApp = candidates.first(where: {
        $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == app.bundleID
    }) else { throw UpdateError("DMG has no app with bundle id \(app.bundleID)") }

    // Copy out first: the DMG's copy carries Finder metadata that strict verification rejects.
    // Extended attributes aren't part of the signature, so clearing them is safe, and every
    // check below runs on the exact bytes that get installed.
    let staged = app.url.deletingLastPathComponent()
        .appendingPathComponent(".\(app.url.lastPathComponent).update")
    try? FileManager.default.removeItem(at: staged)
    let copy = run("/usr/bin/ditto", [newApp.path, staged.path])
    guard copy.status == 0 else { throw UpdateError("couldn't copy the new app: \(copy.output)") }
    run("/usr/bin/xattr", ["-cr", staged.path])
    do {
        let verify = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        guard verify.status == 0 else { throw UpdateError("signature invalid: \(verify.output)") }
        let info = run("/usr/bin/codesign", ["-dv", "--verbose=2", staged.path]).output
        guard info.contains("TeamIdentifier=\(artcraftTeamID)") else {
            throw UpdateError("app is not signed by Artcraft's team \(artcraftTeamID)")
        }
        let gatekeeper = run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path])
        guard gatekeeper.status == 0 else { throw UpdateError("Gatekeeper rejected it: \(gatekeeper.output)") }
    } catch {
        try? FileManager.default.removeItem(at: staged)
        throw error
    }
    log("\(app.displayName): \(release.tag) verified and staged")
    return staged
}

/// Swaps the staged app into place. The app must not be running.
func install(staged: URL, over target: URL) throws {
    _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
    log("installed \(target.path) (now \(CraftApp(bundleID: "", url: target).version))")
}

// MARK: - One run
//
// launchd starts CraftUpdater when a Craft app opens (each app rotates its log at launch, and
// launchd watches those log folders). It checks the running Craft apps, asks about any update,
// and exits once there's nothing left to do. Nothing stays running in the background.

/// A small floating window showing download progress, with a Cancel button.
final class ProgressWindow: NSObject {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelFlag: CancelFlag

    init(app: CraftApp, cancel: CancelFlag) {
        cancelFlag = cancel
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Updating \(app.displayName)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: app.url.path))
        icon.frame = NSRect(x: 20, y: 40, width: 56, height: 56)
        label.frame = NSRect(x: 92, y: 74, width: 328, height: 20)
        bar.frame = NSRect(x: 92, y: 50, width: 328, height: 20)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        button.frame = NSRect(x: 340, y: 12, width: 84, height: 30)
        button.keyEquivalent = "\u{1b}"
        for v in [icon, label, bar, button] as [NSView] { panel.contentView?.addSubview(v) }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func update(_ text: String, _ fraction: Double?) {
        label.stringValue = text
        if let fraction {
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
            bar.doubleValue = fraction
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        }
    }

    @objc private func cancelPressed() { cancelFlag.cancel() }

    func close() { panel.orderOut(nil) }
}

final class Updater: NSObject {
    private let queue = DispatchQueue(label: "craft-updater")
    // All below: main thread only.
    private var busy: Set<String> = []
    private var pendingOnQuit: [String: (staged: URL, target: URL)] = [:]
    private var work = 0

    override init() {
        super.init()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didLaunch(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(didTerminate(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func start() { findRunning(attempt: 0) }

    private func craftApp(_ running: NSRunningApplication) -> CraftApp? {
        guard let id = running.bundleIdentifier, id.hasPrefix(bundlePrefix), let url = running.bundleURL else { return nil }
        return CraftApp(bundleID: id, url: url)
    }

    /// The Craft apps that just started. Apps that were already open aren't asked about again:
    /// each app is asked once, when it starts. launchd can start us a moment before the opening
    /// app is listed as running, so wait up to 5 s.
    private func findRunning(attempt: Int) {
        let apps = NSWorkspace.shared.runningApplications.compactMap { r -> (NSRunningApplication, CraftApp)? in
            guard let launched = r.launchDate, Date().timeIntervalSince(launched) < 60 else { return nil }
            return craftApp(r).map { (r, $0) }
        }
        if apps.isEmpty && attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.findRunning(attempt: attempt + 1) }
            return
        }
        work += 1
        for (running, app) in apps { consider(app, running: running) }
        finishOne()
    }

    private func finishOne() {
        work -= 1
        if work <= 0 { exit(0) }
    }

    private func done(_ app: CraftApp) {
        busy.remove(app.bundleID)
        finishOne()
    }

    @objc func didLaunch(_ note: Notification) {
        guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = craftApp(running) else { return }
        consider(app, running: running)
    }

    @objc func didTerminate(_ note: Notification) {
        guard let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let app = craftApp(running),
              let pending = pendingOnQuit.removeValue(forKey: app.bundleID) else { return }
        queue.async {
            do { try install(staged: pending.staged, over: pending.target) }
            catch { log("\(app.displayName): install on quit failed: \(error)") }
            DispatchQueue.main.async { self.done(app) }
        }
    }

    private func consider(_ app: CraftApp, running: NSRunningApplication) {
        if busy.contains(app.bundleID) { return }
        busy.insert(app.bundleID)
        work += 1
        queue.async {
            let release = self.check(app)
            DispatchQueue.main.async {
                if let release {
                    self.ask(app, running: running, release: release)
                } else {
                    self.done(app)
                }
            }
        }
    }

    /// Runs on `queue`. A quick look at GitHub (no download): the newer release, or nil.
    private func check(_ app: CraftApp) -> Release? {
        do {
            let release = try latestRelease(for: app)
            guard isNewer(parseVersion(release.tag), than: parseVersion(app.version)) else {
                log("\(app.displayName) \(app.version) is up to date")
                return nil
            }
            log("\(app.displayName): \(app.version) -> \(release.tag) available")
            return release
        } catch {
            log("\(app.displayName): update check failed: \(error)")
            return nil
        }
    }

    /// Shown as soon as the app opens.
    private func ask(_ app: CraftApp, running: NSRunningApplication, release: Release) {
        let alert = NSAlert()
        alert.messageText = "An update to \(app.displayName) is available"
        alert.informativeText = "Do you want to install \(app.displayName) \(release.tag)? You have \(app.version).\n\nIf you choose Update, the new version downloads, then \(app.displayName) closes (it asks you to save any changes first), updates, and opens again."
        alert.icon = NSWorkspace.shared.icon(forFile: app.url.path)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else {
            log("\(app.displayName): user cancelled the \(release.tag) update")
            done(app)
            return
        }
        guard FileManager.default.isWritableFile(atPath: app.url.deletingLastPathComponent().path) else {
            fail(app, UpdateError("can't write to \(app.url.deletingLastPathComponent().path)"))
            return
        }

        let cancel = CancelFlag()
        let window = ProgressWindow(app: app, cancel: cancel)
        queue.async {
            do {
                let staged = try stageUpdate(for: app, release: release, cancel: cancel) { text, fraction in
                    DispatchQueue.main.async { window.update(text, fraction) }
                }
                DispatchQueue.main.async {
                    window.update("Restarting \(app.displayName)…", nil)
                    self.quitInstallReopen(app, running: running, staged: staged, window: window)
                }
            } catch {
                DispatchQueue.main.async {
                    window.close()
                    if cancel.isCancelled {
                        log("\(app.displayName): user cancelled the \(release.tag) download")
                        self.done(app)
                    } else {
                        self.fail(app, error)
                    }
                }
            }
        }
    }

    private func fail(_ app: CraftApp, _ error: Error) {
        log("\(app.displayName): update failed: \(error)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(app.displayName) couldn't be updated"
        alert.informativeText = "\(error)\n\nNothing was changed. You'll be asked again later."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        done(app)
    }

    /// Quit normally (the app asks to save), install, reopen. If the user cancels the quit,
    /// we stay until the app quits and install then.
    private func quitInstallReopen(_ app: CraftApp, running: NSRunningApplication, staged: URL, window: ProgressWindow) {
        if running.isTerminated {
            // The user quit the app during the download: install, but don't reopen it.
            window.close()
            queue.async {
                do { try install(staged: staged, over: app.url) }
                catch { log("\(app.displayName): install failed: \(error)") }
                DispatchQueue.main.async { self.done(app) }
            }
            return
        }
        // Hide our window so the app's own save prompt isn't covered.
        window.close()
        running.terminate()
        queue.async {
            let deadline = Date().addingTimeInterval(300)
            while !running.isTerminated && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            guard running.isTerminated else {
                log("\(app.displayName) didn't quit; update installs when it quits")
                DispatchQueue.main.async {
                    if running.isTerminated {
                        self.queue.async {
                            do { try install(staged: staged, over: app.url) }
                            catch { log("\(app.displayName): install failed: \(error)") }
                            DispatchQueue.main.async { self.done(app) }
                        }
                    } else {
                        self.pendingOnQuit[app.bundleID] = (staged, app.url)
                    }
                }
                return
            }
            do {
                try install(staged: staged, over: app.url)
            } catch {
                log("\(app.displayName): install failed: \(error)")
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                    DispatchQueue.main.async { self.done(app) }
                }
            }
        }
    }
}

// MARK: - Entry point

func installedCraftApps() -> [CraftApp] {
    let dirs = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    return dirs.flatMap { dir -> [CraftApp] in
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return items.filter { $0.hasSuffix(".app") }.compactMap { item in
            let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
            guard let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix(bundlePrefix) else { return nil }
            return CraftApp(bundleID: id, url: url)
        }
    }
}

let args = CommandLine.arguments
if args.count >= 2 && args[1] == "--status" {
    for app in installedCraftApps() {
        do {
            let r = try latestRelease(for: app)
            let state = isNewer(parseVersion(r.tag), than: parseVersion(app.version)) ? "update available" : "up to date"
            print("\(app.displayName): installed \(app.version), latest \(r.tag) - \(state)")
        } catch {
            print("\(app.displayName): installed \(app.version), check failed: \(error)")
        }
    }
    exit(0)
} else if args.count >= 3 && args[1] == "--simulate" {
    let url = URL(fileURLWithPath: args[2])
    guard let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix(bundlePrefix) else {
        print("not a Craft app: \(url.path)"); exit(1)
    }
    let app = CraftApp(bundleID: id, url: url)
    do {
        let release = try latestRelease(for: app)
        print("simulating \(app.displayName) 0.0.0 -> \(release.tag)")
        let staged = try stageUpdate(for: app, release: release)
        try install(staged: staged, over: url)
        print("ok: \(url.path) is now \(CraftApp(bundleID: id, url: url).version)")
        exit(0)
    } catch {
        print("failed: \(error)"); exit(1)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let updater = Updater()
updater.start()
application.run()
