import Foundation
import AppKit

public struct RunningAudioApp: Identifiable, Equatable {
    public var id: String { bundleId }
    public let pid: pid_t
    public let name: String
    public let bundleId: String
    public let icon: NSImage?
    public let isProducingAudio: Bool
}

/// Manages per-application audio discovery & routing (native CoreAudio Process Tap first,
/// with optional FineTune fallback) as well as optional Kushview Element VST3/AU host lifecycle.
public final class FineTuneBridge {
    public static let shared = FineTuneBridge()

    public init() {}

    // MARK: - Running Apps Discovery

    public func listRunningApps() -> [RunningAudioApp] {
        let hardExcluded: Set<String> = [
            "com.apple.finder",
            "com.audiomatrix.AudioMatrixHub",
            "com.joshualiu.AudioMatrixHub",
            "net.kushview.Element",
            "com.shure.motivmix"
        ]
        var softExcluded: Set<String> = [
            "com.apple.systempreferences",
            "com.apple.Passwords",
            "com.apple.Notes",
            "com.apple.TextEdit",
            "com.apple.iCal",
            "com.apple.clock",
            "com.apple.Preview",
            "com.apple.ActivityMonitor",
            "com.apple.KeychainAccess",
            "com.apple.Terminal",
            "io.tailscale.ipn.macsys",
            "com.google.antigravity"
        ]
        if let selfBundle = Bundle.main.bundleIdentifier {
            softExcluded.insert(selfBundle)
        }

        let audioProcs = CoreAudioManager.shared.listAudioProcesses()
        let activeAudioBundleIDs = Set(audioProcs.filter { $0.isRunningOutput }.map { $0.bundleID })

        var result: [RunningAudioApp] = []
        var seen = Set<String>()

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier,
                  !hardExcluded.contains(bundleId),
                  !seen.contains(bundleId),
                  let name = app.localizedName else {
                continue
            }
            if let selfBundle = Bundle.main.bundleIdentifier, bundleId == selfBundle {
                continue
            }
            let isAudioActive = activeAudioBundleIDs.contains { active in
                active == bundleId || active.hasPrefix(bundleId + ".")
            }
            if softExcluded.contains(bundleId) && !isAudioActive {
                continue
            }
            seen.insert(bundleId)
            result.append(
                RunningAudioApp(
                    pid: app.processIdentifier,
                    name: name,
                    bundleId: bundleId,
                    icon: app.icon,
                    isProducingAudio: isAudioActive
                )
            )
        }
        return result.sorted {
            if $0.isProducingAudio != $1.isProducingAudio {
                return $0.isProducingAudio && !$1.isProducingAudio
            }
            let m0 = isLikelyMediaOrCommsApp(bundleId: $0.bundleId, name: $0.name)
            let m1 = isLikelyMediaOrCommsApp(bundleId: $1.bundleId, name: $1.name)
            if m0 != m1 {
                return m0 && !m1
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func isLikelyMediaOrCommsApp(bundleId: String, name: String) -> Bool {
        let combined = (bundleId + " " + name).lowercased()
        let keywords = [
            "spotify", "music", "chrome", "safari", "firefox", "arc", "edge", "brave",
            "discord", "qq", "wechat", "xinwechat", "telegram", "slack", "zoom", "wemeet",
            "teams", "steam", "vlc", "iina", "quicktime", "bilibili", "netease", "podcast",
            "tv", "logic", "ableton"
        ]
        return keywords.contains { combined.contains($0) }
    }

    // MARK: - Native CoreAudio Process Tap Routing (with Optional FineTune Fallback)

    @discardableResult
    public func routeApp(bundleId: String, pid: pid_t? = nil, toDeviceUID deviceUID: String, volume: Float = 1.0) -> Bool {
        let resolvedPID = pid
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId })?.processIdentifier
            ?? CoreAudioManager.shared.listAudioProcesses().first(where: { $0.bundleID == bundleId })?.pid

        if let targetPID = resolvedPID,
           NativeAudioPipeline.shared.routeApp(bundleID: bundleId, pid: targetPID, toDeviceUID: deviceUID, volume: volume) {
            return true
        }

        // Optional fallback only if FineTune.app is already running
        if isFineTuneRunning() {
            guard let encodedApp = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let encodedUID = deviceUID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "finetune://set-device?app=\(encodedApp)&device=\(encodedUID)") else {
                return false
            }
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    public func setAppVolume(bundleId: String, volume: Int) {
        let scalar = Float(max(0, min(400, volume))) / 100.0
        NativeAudioPipeline.shared.setAppVolume(bundleID: bundleId, volume: scalar)

        if isFineTuneRunning() {
            let clamped = max(0, min(400, volume))
            if let encodedApp = bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "finetune://set-volumes?app=\(encodedApp)&volume=\(clamped)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    public func removeAppRoute(bundleId: String) {
        NativeAudioPipeline.shared.removeAppRoute(bundleID: bundleId)
    }

    public func resetAllApps() {
        NativeAudioPipeline.shared.stopAllAppRoutes()
        if isFineTuneRunning(), let url = URL(string: "finetune://reset") {
            NSWorkspace.shared.open(url)
        }
    }

    private func isFineTuneRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.lowercased() == "com.finetuneapp.finetune" || $0.localizedName == "FineTune"
        }
    }

    // MARK: - Optional Kushview Element VST3/AU Host Lifecycle

    public func isElementInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/Element.app")
    }

    public func isElementRunning() -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "net.kushview.Element" || $0.localizedName == "Element"
        }
    }

    public func launchElement(sessionPath: String = "") {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "net.kushview.Element" || $0.localizedName == "Element"
        }) {
            running.unhide()
            running.activate(options: [.activateAllWindows])
            return
        }

        let appURL = URL(fileURLWithPath: "/Applications/Element.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else { return }

        let openConfig = NSWorkspace.OpenConfiguration()
        openConfig.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: openConfig) { app, _ in
            DispatchQueue.main.async {
                app?.activate(options: [.activateAllWindows])
            }
        }
    }

    public func reloadElementWithSession(sessionPath: String) {
        for app in NSWorkspace.shared.runningApplications where (app.bundleIdentifier == "net.kushview.Element" || app.localizedName == "Element") {
            app.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.launchElement(sessionPath: sessionPath)
        }
    }
}
