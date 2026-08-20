import AppKit
import Foundation
import VoxelCore

/// The always-running agent.
///
/// Ships as CoreAudioHelper.app with LSUIElement set: no Dock icon, no menu bar,
/// no windows. Its entire job is to hold two global hotkeys and run the panic
/// sequence when one fires.
final class AgentDelegate: NSObject, NSApplicationDelegate {
    private let concealer = Concealer()
    private var config = ConfigStore.load()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        registerHotkeys()

        CoverLibrary.ensureDirectory()
        concealer.armCover(config.cover)
        if config.cover.enabled {
            log(concealer.armedCoverName.map { "cover armed → \($0)" }
                ?? "cover enabled but no usable image in \(CoverLibrary.directory.path)")
        }

        log("ready — profile \"\(config.profile.name)\": "
            + "\(config.profile.conceal.count) to conceal, \(config.profile.reveal.count) to reveal")
        if !ConfigStore.exists {
            log("no config at \(ConfigStore.url.path) — run `voxel capture` first")
        }
    }

    private func registerHotkeys() {
        let panicOK = HotkeyService.shared.register(.panic, binding: config.panicKey) { [weak self] in
            self?.handlePanic()
        }
        let resumeOK = HotkeyService.shared.register(.resume, binding: config.resumeKey) { [weak self] in
            self?.handleResume()
        }

        log(panicOK
            ? "panic  → \(config.panicKey.displayString)"
            : "panic  → FAILED to register \(config.panicKey.displayString) (already taken?)")
        log(resumeOK
            ? "resume → \(config.resumeKey.displayString)"
            : "resume → FAILED to register \(config.resumeKey.displayString) (already taken?)")
    }

    private func handlePanic() {
        // Re-read the profile on every press so editing config.json doesn't
        // require restarting the agent during the spike.
        config = ConfigStore.load()
        let cover = concealer.armedCoverName
        let timing = concealer.panic(profile: config.profile, cover: config.cover)
        let shown = (config.cover.enabled && cover != nil) ? "  cover=\(cover!)" : ""
        log("PANIC  \(timing.summary)\(shown)")
    }

    private func handleResume() {
        let timing = concealer.resume(cover: config.cover)
        log("RESUME \(timing.summary)")
        if config.cover.enabled, let next = concealer.armedCoverName {
            log("cover armed → \(next)")
        }
    }

    /// If the agent dies while concealed, the machine is left muted and the
    /// game is left hidden. Undo before exiting.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                if self?.concealer.isConcealed == true {
                    self?.concealer.resume(cover: CoverSettings())
                    log("restored state before exit")
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)"
    print(line)
    fflush(stdout)

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Voxel", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("agent.log")
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: file)
    }
}

let delegate = AgentDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
