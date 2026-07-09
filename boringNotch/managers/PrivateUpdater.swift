//
//  PrivateUpdater.swift
//  boringNotch
//
//  Custom "Check for Updates…" that pulls releases from a PRIVATE GitHub repo
//  via the logged-in `gh` CLI, so no public feed or embedded token is needed.
//

import AppKit
import Foundation

@MainActor
final class PrivateUpdater: ObservableObject {
    static let shared = PrivateUpdater()

    // ponytail: hardcoded — single-user, single-repo. Change here if the repo moves.
    static let repo = "PeshangALO/boring.notch-private"
    static let asset = "boringNotch.dmg"

    private init() {}

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Entry point for the menu item. Checks the latest release and, if newer,
    /// offers to install it. All GitHub work happens off the main thread.
    func checkForUpdates() {
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let (tag, ok) = try await Self.latestRelease()
                let latest = Self.stripV(tag)
                let current = await self.currentVersion
                if Self.isNewer(latest, than: current) {
                    await self.offerInstall(tag: tag, version: latest, hasAsset: ok)
                } else {
                    await Self.alert("You're up to date", "boringNotch \(current) is the latest version.")
                }
            } catch let e as UpdaterError {
                await Self.alert("Update check failed", e.message)
            } catch {
                await Self.alert("Update check failed", error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub (via gh CLI)

    nonisolated private static func latestRelease() async throws -> (tag: String, hasAsset: Bool) {
        let out = try run("gh", ["release", "view", "--repo", repo,
                                 "--json", "tagName,assets"])
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tagName"] as? String else {
            throw UpdaterError("Could not read the latest release. Is `gh` installed and logged in?")
        }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let hasAsset = assets.contains { ($0["name"] as? String) == asset }
        return (tag, hasAsset)
    }

    private func offerInstall(tag: String, version: String, hasAsset: Bool) async {
        guard hasAsset else {
            await Self.alert("Update available, but no download",
                             "Release \(tag) has no \(Self.asset) asset attached.")
            return
        }
        guard Self.isInApplications() else {
            await Self.alert("Update available: \(version)",
                             "This copy isn't running from /Applications (looks like a dev build), so it can't self-update. Pull and rebuild instead.")
            return
        }
        let go = await Self.confirm("Update available: \(version)",
                                    "You have \(currentVersion). Download and install \(version) now? boringNotch will relaunch.")
        guard go else { return }
        await install(tag: tag)
    }

    private func install(tag: String) async {
        do {
            let tmp = try Self.tempDir()
            _ = try Self.run("gh", ["release", "download", tag, "--repo", Self.repo,
                                    "--pattern", Self.asset, "--dir", tmp])
            let dmg = (tmp as NSString).appendingPathComponent(Self.asset)
            try Self.installDMG(atPath: dmg)
            // installDMG relaunches and exits; we never get past it on success.
        } catch let e as UpdaterError {
            await Self.alert("Update failed", e.message)
        } catch {
            await Self.alert("Update failed", error.localizedDescription)
        }
    }

    // MARK: - DMG install (mount, replace, relaunch)

    /// Mounts the dmg, copies the app out, then hands off to a detached script
    /// that swaps the bundle in /Applications once this process exits and relaunches.
    nonisolated private static func installDMG(atPath dmg: String) throws {
        // Mount to a private mountpoint so we control detach.
        let mount = try tempDir()
        _ = try run("/usr/bin/hdiutil", ["attach", dmg, "-nobrowse", "-mountpoint", mount])

        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let srcApp = (mount as NSString).appendingPathComponent("boringNotch.app")
        guard FileManager.default.fileExists(atPath: srcApp) else {
            throw UpdaterError("The downloaded disk image doesn't contain boringNotch.app.")
        }

        // Stage the new app in a temp dir (surviving the detach).
        let stage = try tempDir()
        let stagedApp = (stage as NSString).appendingPathComponent("boringNotch.app")
        _ = try run("/bin/cp", ["-R", srcApp, stagedApp])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", stagedApp])

        let dest = Bundle.main.bundlePath  // e.g. /Applications/boringNotch.app
        let pid = ProcessInfo.processInfo.processIdentifier

        // Detached swapper: wait for us to quit, replace the bundle, relaunch.
        let script = """
        #!/bin/bash
        set -e
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(dest)"
        cp -R "\(stagedApp)" "\(dest)"
        xattr -dr com.apple.quarantine "\(dest)" 2>/dev/null || true
        open "\(dest)"
        rm -rf "\(stage)"
        """
        let scriptPath = (stage as NSString).appendingPathComponent("swap.sh")
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptPath]
        try p.run()  // detached; do not wait

        // Quit so the swapper can replace us.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - Shell helper

    @discardableResult
    nonisolated private static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let p = Process()
        // Resolve bare command names (like "gh") via /usr/bin/env + login PATH.
        if launchPath.hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [launchPath] + args
            // gh is commonly in /opt/homebrew/bin or /usr/local/bin, not the default PATH.
            var env = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin"
            env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
        }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err, encoding: .utf8) ?? "exit \(p.terminationStatus)"
            throw UpdaterError(msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               ? "Command `\(launchPath)` failed (exit \(p.terminationStatus))." : msg)
        }
        return String(data: out, encoding: .utf8) ?? ""
    }

    nonisolated private static func tempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("boringNotch-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func isInApplications() -> Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    // MARK: - Pure logic (testable)

    nonisolated static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// Semver-ish compare on dot-separated integer components. Missing
    /// components count as 0, so "2.7" == "2.7.0".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - UI

    private static func alert(_ title: String, _ msg: String) async {
        await MainActor.run {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = msg
            a.addButton(withTitle: "OK")
            a.runModal()
        }
    }

    private static func confirm(_ title: String, _ msg: String) async -> Bool {
        await MainActor.run {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = msg
            a.addButton(withTitle: "Install")
            a.addButton(withTitle: "Cancel")
            return a.runModal() == .alertFirstButtonReturn
        }
    }
}

struct UpdaterError: Error { let message: String; init(_ m: String) { message = m } }
