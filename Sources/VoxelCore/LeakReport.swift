import AppKit
import CoreGraphics
import Foundation

/// One thing that would still give you away after a perfect panic.
public struct Leak {
    public enum Severity: String {
        case critical  // panic will visibly fail or be too slow
        case warning   // panic works, but something still points at the game
        case info      // worth knowing; not currently leaking
    }

    public let severity: Severity
    public let title: String
    public let detail: String
    public let fix: String
}

/// Audits the machine's current state for things a panic press will *not* fix.
///
/// Every check here is permission-free: running-app lists, window geometry,
/// CoreAudio properties, and preference domains. Window *titles* would need
/// Screen Recording, so nothing in this report depends on them.
public enum LeakReport {

    public static func run(profile: Profile) -> [Leak] {
        var leaks: [Leak] = []

        leaks.append(contentsOf: profileChecks(profile))
        leaks.append(contentsOf: audioChecks())
        leaks.append(contentsOf: windowChecks(profile))
        leaks.append(contentsOf: dockChecks())
        leaks.append(contentsOf: displayChecks())
        leaks.append(contentsOf: presenceChecks())
        leaks.append(contentsOf: captureChecks())
        leaks.append(contentsOf: focusChecks())

        let order: [Leak.Severity: Int] = [.critical: 0, .warning: 1, .info: 2]
        return leaks.sorted { (order[$0.severity] ?? 3) < (order[$1.severity] ?? 3) }
    }

    // MARK: - Profile

    private static func profileChecks(_ profile: Profile) -> [Leak] {
        var leaks: [Leak] = []

        if profile.conceal.isEmpty {
            leaks.append(Leak(
                severity: .critical,
                title: "No profile configured",
                detail: "Voxel doesn't know what to hide, so panic would do nothing but mute.",
                fix: "Arrange your setup and run `voxel capture`."))
            return leaks
        }

        let coldDecoys = profile.reveal.filter {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        if !coldDecoys.isEmpty {
            leaks.append(Leak(
                severity: .critical,
                title: "Decoy not running: \(coldDecoys.map(appName).joined(separator: ", "))",
                detail: "Panic would have to cold-launch it. That is seconds, not milliseconds, "
                      + "and a launching app looks nothing like an app you were already using.",
                fix: "Launch your cover story before you start playing and leave it open."))
        }

        let notRunning = profile.conceal.filter {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        }
        if notRunning.count == profile.conceal.count {
            leaks.append(Leak(
                severity: .info,
                title: "Nothing to conceal right now",
                detail: "None of the apps in this profile are running, so this report can't check "
                      + "for fullscreen or window-level leaks.",
                fix: "Re-run this while the game is actually open."))
        }

        return leaks
    }

    // MARK: - Audio

    private static func audioChecks() -> [Leak] {
        guard let device = AudioController.defaultOutputDevice() else {
            return [Leak(severity: .warning,
                         title: "No default output device",
                         detail: "Voxel can't find an output device, so it can't guarantee a mute.",
                         fix: "Check Sound settings.")]
        }

        let name = AudioController.deviceName(device)
        let volume = AudioController.currentVolume(device) ?? 0
        let muted = AudioController.isMuted(device) ?? false
        let percent = Int((volume * 100).rounded())

        if muted || volume < 0.01 {
            return [Leak(severity: .info,
                         title: "Audio already silent",
                         detail: "Output \"\(name)\" is muted.",
                         fix: "")]
        }

        if AudioController.isAudibleToRoom(device) {
            return [Leak(severity: .warning,
                         title: "Audio is on built-in speakers at \(percent)%",
                         detail: "Voxel mutes on panic, but sound travels through a closed door "
                               + "well before anyone reaches it. Speakers cost you the head start.",
                         fix: "Use headphones while playing.")]
        }

        return [Leak(severity: .info,
                     title: "Audio on \"\(name)\" at \(percent)%",
                     detail: "Not built-in speakers. If this is a Bluetooth speaker rather than "
                           + "headphones, treat it as a leak.",
                     fix: "")]
    }

    // MARK: - Windows

    private static func windowChecks(_ profile: Profile) -> [Leak] {
        var leaks: [Leak] = []

        let concealedApps = profile.conceal.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }
        guard !concealedApps.isEmpty else { return leaks }

        let pids = Set(concealedApps.map(\.processIdentifier))
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

        let screenSizes = NSScreen.screens.map(\.frame.size)
        var sawOnscreenWindow = false

        for window in info {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            sawOnscreenWindow = true

            // A native-fullscreen window covers the menu bar, which a merely
            // maximized window never does. That is the tell.
            let coversAScreen = screenSizes.contains {
                bounds.width >= $0.width - 1 && bounds.height >= $0.height - 1
            }
            if coversAScreen {
                let name = concealedApps.first { $0.processIdentifier == pid }?.localizedName ?? "A game"
                leaks.append(Leak(
                    severity: .critical,
                    title: "\(name) is in fullscreen",
                    detail: "A fullscreen app owns its own Space. Leaving it means a Space-switch "
                          + "animation of roughly half a second that macOS will not let us "
                          + "suppress -- the slowest and most obvious possible exit.",
                    fix: "Switch the game to windowed or borderless-windowed mode."))
            }
        }

        // Running, not hidden, but nothing on screen: almost certainly parked on
        // another Space, which has the same exit cost as fullscreen.
        let visibleApps = concealedApps.filter { !$0.isHidden }
        if !visibleApps.isEmpty && !sawOnscreenWindow && leaks.isEmpty {
            let names = visibleApps.compactMap(\.localizedName).joined(separator: ", ")
            leaks.append(Leak(
                severity: .warning,
                title: "\(names) has no window on this Space",
                detail: "It is probably on another desktop Space, which costs a switch animation "
                      + "on the way back.",
                fix: "Keep the game on your main Space."))
        }

        return leaks
    }

    // MARK: - Dock

    private static func dockChecks() -> [Leak] {
        let autohide = UserDefaults(suiteName: "com.apple.dock")?
            .object(forKey: "autohide") as? Bool ?? false
        guard !autohide else { return [] }

        return [Leak(
            severity: .warning,
            title: "Dock is always visible",
            detail: "Hiding an app does not remove its Dock icon or its running indicator. "
                  + "The game's icon stays on screen with a dot under it.",
            fix: "Turn on System Settings > Desktop & Dock > Automatically hide and show the Dock. "
               + "Voxel deliberately does not toggle this for you: doing it live restarts the Dock, "
               + "which is slow and far more noticeable than the icon.")]
    }

    // MARK: - Displays

    private static func displayChecks() -> [Leak] {
        let count = NSScreen.screens.count
        guard count > 1 else { return [] }
        return [Leak(
            severity: .warning,
            title: "\(count) displays connected",
            detail: "Panic hides apps everywhere, but your cover story only fills one screen. "
                  + "The others fall back to whatever is behind them.",
            fix: "Add a decoy window per display, or unplug while playing.")]
    }

    // MARK: - Social presence

    private static let presenceApps: [(id: String, label: String, detail: String)] = [
        ("com.hnc.Discord", "Discord",
         "Rich Presence broadcasts what you're playing to everyone on your friends list, "
         + "including anyone reading it over someone else's shoulder."),
        ("com.valvesoftware.steam", "Steam",
         "Friends see \"In-Game\" with the title next to your name."),
    ]

    private static func presenceChecks() -> [Leak] {
        presenceApps.compactMap { entry in
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: entry.id).isEmpty
            else { return nil }
            return Leak(
                severity: .warning,
                title: "\(entry.label) is broadcasting your status",
                detail: entry.detail,
                fix: "Turn off game activity / set status to invisible while playing.")
        }
    }

    // MARK: - Screen capture

    private static let captureApps: [(id: String, label: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.obsproject.obs-studio", "OBS"),
        ("com.apple.QuickTimePlayerX", "QuickTime Player"),
    ]

    private static func captureChecks() -> [Leak] {
        var seen = Set<String>()
        return captureApps.compactMap { entry in
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: entry.id).isEmpty,
                  seen.insert(entry.label).inserted
            else { return nil }
            return Leak(
                severity: .warning,
                title: "\(entry.label) is running",
                detail: "If it starts sharing your screen, the panic hotkey is not the thing that "
                      + "saves you -- the share is already live.",
                fix: "Quit it while playing. Automatic conceal-on-share is planned, not built.")
        }
    }

    // MARK: - Focus / notifications

    private static func focusChecks() -> [Leak] {
        switch focusIsActive() {
        case .some(true):
            return []
        case .some(false):
            return [Leak(
                severity: .warning,
                title: "Notifications are not suppressed",
                detail: "A Discord message or Steam banner sliding in over your \"homework\" "
                      + "undoes the whole illusion, and it can arrive after you've walked away.",
                fix: "Turn on a Focus mode while playing.")]
        case nil:
            return [Leak(
                severity: .info,
                title: "Focus state unknown",
                detail: "The Focus database is TCC-protected and Voxel deliberately does not ask "
                      + "for Full Disk Access to read it. Reading Focus properly needs "
                      + "INFocusStatusCenter, which prompts -- an opt-in, not a default.",
                fix: "Turn on a Focus mode yourself before playing.")]
        }
    }

    /// Best-effort read of the Focus assertion store. On current macOS this
    /// directory is TCC-protected and the read fails without Full Disk Access,
    /// so failure means "unknown", never "off".
    private static func focusIsActive() -> Bool? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return nil }

        for entry in entries {
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Helpers

    private static func appName(_ bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID
    }
}
