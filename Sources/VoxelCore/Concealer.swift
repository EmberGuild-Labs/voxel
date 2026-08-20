import AppKit
import Foundation

/// Per-phase timing for one panic or resume, in milliseconds.
///
/// P0 exists to answer one question -- "is the direct hide/activate path fast
/// enough, or do we need Instant Cover?" -- so every run is instrumented.
public struct TimingReport {
    public struct Phase {
        public let name: String
        public let milliseconds: Double
    }

    public private(set) var phases: [Phase] = []
    private var lastMark = DispatchTime.now()

    public init() {}

    public mutating func mark(_ name: String) {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastMark.uptimeNanoseconds) / 1_000_000
        phases.append(Phase(name: name, milliseconds: elapsed))
        lastMark = now
    }

    /// Elapsed time to the *last mark*, not to now. Reading this after a hold
    /// must not fold the hold into the measurement.
    public var total: Double {
        phases.reduce(0) { $0 + $1.milliseconds }
    }

    public var summary: String {
        let detail = phases.map { String(format: "%@ %.1fms", $0.name, $0.milliseconds) }
            .joined(separator: "  ")
        return String(format: "total %.1fms  [%@]", total, detail)
    }
}

/// What we changed, so resume can put it all back.
public struct ConcealState {
    public var hidden: [String] = []
    public var previousFront: String?
    public var audio: AudioSnapshot?
    public var startedAt = Date()
}

/// The panic sequence and its exact inverse.
public final class Concealer {
    public private(set) var state: ConcealState?
    public var isConcealed: Bool { state != nil }

    public init() {}

    // MARK: - Panic

    @discardableResult
    public func panic(profile: Profile) -> TimingReport {
        var timing = TimingReport()
        guard state == nil else {
            timing.mark("already concealed")
            return timing
        }

        var newState = ConcealState()
        newState.previousFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // 1. Audio first, and synchronously. Sound reaches the hallway before
        //    sight reaches the doorway.
        if profile.mute {
            newState.audio = AudioController.silence()
        }
        timing.mark("mute")

        // 2. Hide the games. `hide()` is animation-free and needs no permission.
        for bundleID in profile.conceal {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            for app in apps where !app.isHidden {
                if app.hide() { newState.hidden.append(bundleID) }
            }
        }
        timing.mark("hide")

        // 3. Bring the cover story forward. Back-to-front so the intended
        //    front app ends up on top.
        for bundleID in profile.reveal.reversed() {
            activate(bundleID: bundleID, launchIfNeeded: bundleID == profile.reveal.first)
        }
        timing.mark("reveal")

        state = newState
        return timing
    }

    // MARK: - Resume

    @discardableResult
    public func resume() -> TimingReport {
        var timing = TimingReport()
        guard let current = state else {
            timing.mark("not concealed")
            return timing
        }

        for bundleID in current.hidden {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.unhide()
            }
        }
        timing.mark("unhide")

        if let front = current.previousFront {
            activate(bundleID: front, launchIfNeeded: false)
        }
        timing.mark("refocus")

        if let audio = current.audio {
            AudioController.restore(audio)
        }
        timing.mark("unmute")

        state = nil
        return timing
    }

    // MARK: - Helpers

    private func activate(bundleID: String, launchIfNeeded: Bool) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let app = running.first {
            app.unhide()
            app.activate()
            return
        }

        // Cold launch is the slow path -- the leak report warns when a decoy
        // app isn't already running for exactly this reason.
        guard launchIfNeeded,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
