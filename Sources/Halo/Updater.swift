import AppKit

/// In-app updater. Checks the GitHub Releases API for a newer version and, on
/// the user's confirmation, downloads the prebuilt + signed `Halo.app`, swaps it
/// in place over the running bundle, and relaunches. The old build is moved aside
/// during the swap and deleted on success — replaced, never duplicated.
///
/// Safety:
/// - The replacement must be VALIDLY code-signed AND satisfy the running app's
///   own designated requirement (which pins the bundle id + signing cert leaf),
///   so a tampered release can't swap in a foreign binary — and the shared code
///   identity is exactly what keeps the TCC grants (Accessibility / Screen
///   Recording) alive across the swap.
/// - The swap copies the new build into a fresh sibling path, then uses
///   same-volume renames (never `ditto` into an existing bundle, never an
///   `rm` without a known-good copy in place), so a failed update can't leave the
///   user with a corrupted or missing app.
/// - A failed swap drops a marker that the next launch reads and surfaces, so an
///   update can never fail silently.
@MainActor
final class Updater {
    static let shared = Updater()

    /// `owner/repo` on GitHub.
    private let repo = "arshawnarbabi/Halo"
    /// Preferred release-asset filename (a `ditto` zip of `Halo.app`).
    private let assetName = "Halo.app.zip"

    /// True while a check/download/install is in flight. Drives the menu item's
    /// enabled state (the menu is cached, so the owner rebuilds it on change).
    private(set) var isBusy = false { didSet { onBusyChanged?(isBusy) } }
    var onBusyChanged: ((Bool) -> Void)?

    enum UpdaterError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Marker the swap helper writes on failure and the next launch surfaces, so
    /// a failed in-place update is never silent. Shared with `AppDelegate`.
    static var failureMarker: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Halo", isDirectory: true)
        return dir.appendingPathComponent("last-update.fail")
    }

    // MARK: - Entry point (menu action)

    /// Check GitHub for a newer release. When `userInitiated` is true, surfaces
    /// "up to date" / errors via an alert and asks before downloading; a silent
    /// background check stays quiet and never installs without confirmation.
    func checkForUpdates(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false }
            do {
                let release = try await self.fetchLatestRelease()
                let latest = Self.normalize(release.tagName)
                let current = Self.currentVersion
                diag("update check: current=\(current) latest=\(latest)")

                guard Self.isNewer(latest, than: current) else {
                    if userInitiated {
                        Self.alert("You're up to date", "Halo \(current) is the latest version.", style: .informational)
                    }
                    return
                }

                guard let asset = self.pickAsset(from: release.assets) else {
                    // A newer version exists but ships no downloadable build — point
                    // the user at the releases page instead of failing silently.
                    if userInitiated {
                        Self.alert("Update available",
                                   "Halo \(latest) is available, but this release has no downloadable build. Opening the releases page.",
                                   style: .informational)
                        if let url = URL(string: release.htmlUrl) { NSWorkspace.shared.open(url) }
                    }
                    return
                }

                guard !userInitiated || Self.confirmUpdate(to: latest) else { return }
                try await self.downloadAndInstall(from: asset.browserDownloadUrl)
            } catch {
                diag("update failed: \(error.localizedDescription)")
                if userInitiated {
                    Self.alert("Update failed", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    /// Prefer the exact `Halo.app.zip`; fall back only to a Halo `*.app.zip`
    /// (never a dSYM or some other archive that would fail signature checks).
    private func pickAsset(from assets: [Release.Asset]) -> Release.Asset? {
        if let exact = assets.first(where: { $0.name == assetName }) { return exact }
        return assets.first {
            let n = $0.name.lowercased()
            return n.hasSuffix(".app.zip") && n.contains("halo") && !n.contains("dsym")
        }
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let tagName: String
        let htmlUrl: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdaterError.message("Bad update URL.")
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Halo-Updater", forHTTPHeaderField: "User-Agent") // GitHub requires a UA
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw UpdaterError.message("No response from GitHub.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw UpdaterError.message("No releases found yet.")
            }
            // Unauthenticated GitHub API is limited to 60 requests/hour; surface a
            // clear message instead of a bare "HTTP 403".
            if (http.statusCode == 403 || http.statusCode == 429),
               http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                var when = "later"
                if let resetStr = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                   let reset = TimeInterval(resetStr) {
                    let df = DateFormatter()
                    df.dateStyle = .none; df.timeStyle = .short
                    when = "after \(df.string(from: Date(timeIntervalSince1970: reset)))"
                }
                throw UpdaterError.message("GitHub rate limit reached. Try again \(when).")
            }
            throw UpdaterError.message("GitHub returned HTTP \(http.statusCode).")
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(Release.self, from: data)
    }

    // MARK: - Version comparison

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Strip a leading `v`/`V` and any SemVer pre-release / build-metadata suffix
    /// so `v1.0.1-beta` / `1.0.1+42` rank as `1.0.1` (not as `1.0.0`).
    static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if let first = t.first, first == "v" || first == "V" { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") { t = String(t[..<plus]) }
        if let dash = t.firstIndex(of: "-") { t = String(t[..<dash]) }
        return t
    }

    /// Component-wise numeric compare so `1.0.10` > `1.0.9` (not a string compare).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Download + install

    private func downloadAndInstall(from urlString: String) async throws {
        guard let url = URL(string: urlString) else { throw UpdaterError.message("Bad download URL.") }
        let dest = Bundle.main.bundleURL
        guard dest.pathExtension == "app" else {
            throw UpdaterError.message("Auto-update requires running the Halo.app bundle (not the raw binary).")
        }
        // Gatekeeper App Translocation runs the app from a random read-only path —
        // the in-place swap can't work there. Detect it and tell the user to move
        // Halo out of quarantine first.
        guard !dest.path.contains("/AppTranslocation/") else {
            throw UpdaterError.message("Halo is running from a temporary read-only location (Gatekeeper translocation). Move Halo to your Applications folder and reopen it, then try updating again.")
        }
        // Fail fast on a non-writable install (e.g. /Applications without admin)
        // BEFORE spending a long download that would only fail at the swap.
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: dest.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: dest.path) else {
            throw UpdaterError.message("Halo is installed in a location you can't modify (for example /Applications without admin rights). Move Halo to your personal Applications folder, then try again.")
        }
        diag("downloading update from \(url.lastPathComponent)")

        var req = URLRequest(url: url)
        req.setValue("Halo-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 180
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdaterError.message("Download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)).")
        }

        // Take ownership of the downloaded file immediately (the async download's
        // temp file isn't guaranteed to survive past this scope otherwise).
        let owned = fm.temporaryDirectory.appendingPathComponent("Halo-dl-\(UUID().uuidString).zip")
        try? fm.removeItem(at: owned)
        try fm.moveItem(at: tmp, to: owned)

        // Unzip + verify + stage the in-place swap off the main thread (ditto and
        // codesign are blocking) — the menu thread stays responsive.
        try await Task.detached(priority: .userInitiated) {
            try Self.performInstall(downloadedZip: owned, dest: dest)
        }.value

        diag("update staged; relaunching")
        NSApp.terminate(nil)
    }

    /// Extract the archive, validate the signature, and launch the detached
    /// swap-and-relaunch helper. Runs off the main actor; touches no actor state.
    nonisolated private static func performInstall(downloadedZip: URL, dest: URL) throws {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("Halo-update-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        // Clean up the staging dir on any failure; on success the detached helper
        // owns its removal (it reads `new` out of `stage` after we've exited).
        var handedOffToHelper = false
        defer { if !handedOffToHelper { try? fm.removeItem(at: stage) } }

        let zip = stage.appendingPathComponent("Halo.app.zip")
        try fm.moveItem(at: downloadedZip, to: zip)

        // `ditto -x -k` preserves bundle symlinks + extended attributes, so the
        // extracted app's code signature stays intact (plain `unzip` can break it).
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path])

        guard let newApp = try findApp(in: stage) else {
            throw UpdaterError.message("The downloaded archive contained no app.")
        }
        try verifySignature(of: newApp, matching: dest)
        try installAndRelaunch(newApp: newApp, dest: dest, stage: stage)
        handedOffToHelper = true
    }

    nonisolated private static func findApp(in dir: URL) throws -> URL? {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return items.first { $0.pathExtension == "app" }
    }

    /// The update must be structurally signed AND satisfy the running app's
    /// designated requirement (bundle id + signing cert leaf). That shared
    /// identity is what preserves the TCC grants across the swap, and it rejects a
    /// binary signed by anyone else. Falls back to a Team-ID + bundle-id match if
    /// the requirement can't be read for some reason.
    nonisolated private static func verifySignature(of newApp: URL, matching dest: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--strict", newApp.path])

        if let requirement = designatedRequirement(of: dest.path), !requirement.isEmpty {
            // NOTE: codesign reads `-R <text>` as a FILE PATH; the inline form is
            // `-R=<text>` as a single argument (verified empirically).
            try run("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", newApp.path])
            diag("update satisfies the running app's designated requirement")
            return
        }

        let newTeam = teamID(of: newApp.path)
        let myTeam = teamID(of: dest.path)
        guard let myTeam, let newTeam, myTeam == newTeam else {
            throw UpdaterError.message("The update is signed by a different developer (Team ID mismatch) — refusing to install it.")
        }
        let newID = Bundle(url: newApp)?.bundleIdentifier
        let myID = Bundle(url: dest)?.bundleIdentifier ?? Bundle.main.bundleIdentifier
        guard let myID, let newID, myID == newID else {
            throw UpdaterError.message("The update has a different bundle identifier — refusing to install it.")
        }
        diag("update matches Team ID \(myTeam) and bundle id \(myID)")
    }

    /// The `designated => …` requirement text from `codesign -d --requirements -`.
    nonisolated private static func designatedRequirement(of path: String) -> String? {
        let out = runCapturing("/usr/bin/codesign", ["-d", "--requirements", "-", path])
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("designated => ") {
            return String(line.dropFirst("designated => ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parse `TeamIdentifier=` out of `codesign -dvvv` (which prints to stderr).
    nonisolated private static func teamID(of path: String) -> String? {
        let out = runCapturing("/usr/bin/codesign", ["-dvvv", path])
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("TeamIdentifier=") {
            let v = line.replacingOccurrences(of: "TeamIdentifier=", with: "")
            return v == "not set" ? nil : v
        }
        return nil
    }

    /// Write and launch a detached `/bin/sh` helper that waits for this process to
    /// exit (escalating to TERM/KILL if it lingers), then swaps the bundle in
    /// place via same-volume renames and relaunches. Any failure restores the old
    /// build, drops a marker for the next launch to surface, and still relaunches
    /// (the old version) so the user is never left with nothing. Paths are passed
    /// as quoted positional args (the repo path can contain `+`/spaces).
    nonisolated private static func installAndRelaunch(newApp: URL, dest: URL, stage: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        # Halo self-update helper — args: <pid> <new.app> <dest.app> <stage-dir>
        pid="$1"; new="$2"; dest="$3"; stage="$4"
        marker_dir="$HOME/Library/Application Support/Halo"
        marker="$marker_dir/last-update.fail"

        fail() {
          /bin/mkdir -p "$marker_dir" 2>/dev/null
          /bin/echo "$1" > "$marker"
        }

        # Wait for the running Halo to quit so the bundle is free to swap; escalate
        # to TERM, then KILL, rather than mutating the bundle out from under it.
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          i=$((i + 1))
          [ "$i" -eq 200 ] && kill -TERM "$pid" 2>/dev/null
          [ "$i" -eq 400 ] && kill -KILL "$pid" 2>/dev/null
          [ "$i" -ge 460 ] && break
          /bin/sleep 0.05
        done

        if kill -0 "$pid" 2>/dev/null; then
          fail "Halo did not quit in time; the update was not applied."
        else
          backup="${dest}.old-$$"
          staged="${dest}.new-$$"
          /bin/rm -rf "$backup" "$staged"
          if /usr/bin/ditto "$new" "$staged"; then     # clean copy into a fresh path (never merges)
            if /bin/mv "$dest" "$backup"; then          # free dest
              if /bin/mv "$staged" "$dest"; then        # same-volume atomic rename into place
                /bin/rm -rf "$backup"                    # success -> discard the old build
                /bin/rm -f "$marker" 2>/dev/null         # clear any stale failure marker
              else
                /bin/mv "$backup" "$dest"               # restore by rename before removing anything
                /bin/rm -rf "$staged"
                fail "Could not move the new build into place; kept the previous version."
              fi
            else
              /bin/rm -rf "$staged"                      # couldn't free dest -> old app untouched
              fail "Could not replace the existing Halo (permissions?); kept the previous version."
            fi
          else
            /bin/rm -rf "$staged"
            fail "Could not unpack the update; kept the previous version."
          fi
        fi

        /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
        /bin/rm -rf "$stage"
        /usr/bin/open "$dest"
        /bin/rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(pid), newApp.path, dest.path, stage.path]
        try p.run() // detached — do NOT wait; it outlives us and relaunches the app
    }

    // MARK: - Process helpers

    @discardableResult
    nonisolated private static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Read to EOF (child closes the pipe on exit) BEFORE waiting, so large
        // output can't deadlock against a full pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let tool = URL(fileURLWithPath: launchPath).lastPathComponent
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdaterError.message("\(tool) failed (exit \(p.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)").")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func runCapturing(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Alerts

    @MainActor
    private static func confirmUpdate(to version: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Update available"
        a.informativeText = "Halo \(version) is available. Download it and relaunch now?"
        a.alertStyle = .informational
        a.addButton(withTitle: "Update & Relaunch")
        a.addButton(withTitle: "Later")
        return a.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func alert(_ title: String, _ message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
