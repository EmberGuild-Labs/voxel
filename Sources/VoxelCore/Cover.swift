import AppKit
import CoreGraphics
import Foundation

/// How Voxel picks which cover image to show when several are available.
public enum CoverSelection: String, Codable {
    /// Always the one named in `active`.
    case fixed
    /// Advance to the next image on every panic, wrapping at the end.
    case cycle
    /// Pick one at random, never the same one twice in a row.
    case random
}

public struct CoverSettings: Codable {
    public var enabled: Bool
    public var selection: CoverSelection
    /// Filename within the covers directory. Only consulted for `.fixed`.
    public var active: String?
    /// Milliseconds to hold the image before tearing it down and leaving the
    /// real cover-story apps on screen. `nil` holds until you press resume.
    public var dismissAfterMilliseconds: Int?

    public init(enabled: Bool = false,
                selection: CoverSelection = .fixed,
                active: String? = nil,
                dismissAfterMilliseconds: Int? = nil) {
        self.enabled = enabled
        self.selection = selection
        self.active = active
        self.dismissAfterMilliseconds = dismissAfterMilliseconds
    }
}

/// The images on disk, and the rule for choosing between them.
///
/// Images are supplied by you -- screenshot your own cover story with
/// ⌘⇧4 and drop the files in. That is the whole reason this feature costs no
/// permissions: Voxel never captures the screen, it only draws pictures you
/// already took.
public final class CoverLibrary {
    public static var directory: URL {
        ConfigStore.directory.appendingPathComponent("covers", isDirectory: true)
    }

    private static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

    private var lastChosen: URL?

    public init() {}

    public static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Every usable image, sorted by name so `cycle` has a stable order.
    public static func available() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Resolves which image the *next* panic should show.
    ///
    /// Called ahead of time, not during the panic itself, so that decoding the
    /// image never lands in the latency budget.
    public func resolveNext(_ settings: CoverSettings) -> URL? {
        guard settings.enabled else { return nil }
        let images = Self.available()
        guard !images.isEmpty else { return nil }

        let chosen: URL
        switch settings.selection {
        case .fixed:
            chosen = images.first { $0.lastPathComponent == settings.active } ?? images[0]

        case .cycle:
            if let last = lastChosen, let index = images.firstIndex(of: last) {
                chosen = images[(index + 1) % images.count]
            } else {
                chosen = images[0]
            }

        case .random:
            // Never the same image twice running: repeating yourself is the one
            // thing a static cover can obviously get wrong.
            let candidates = images.count > 1 ? images.filter { $0 != lastChosen } : images
            chosen = candidates.randomElement() ?? images[0]
        }

        lastChosen = chosen
        return chosen
    }
}

/// Draws a cover image at aspect-fill, so a screenshot from a differently-shaped
/// display still covers the screen edge to edge instead of letterboxing.
private final class CoverView: NSView {
    var image: NSImage?

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let scaled = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = NSPoint(x: (bounds.width - scaled.width) / 2,
                             y: (bounds.height - scaled.height) / 2)
        image.draw(in: NSRect(origin: origin, size: scaled))
    }
}

/// Puts a prepared image over every display, instantly.
///
/// Windows are built and the image decoded *before* the panic, so pressing the
/// hotkey is a single `orderFrontRegardless()` -- under a millisecond, and it
/// happens in one frame regardless of how slow the app-juggling behind it is.
///
/// The window sits at `.screenSaver` level, which is above the Dock and the menu
/// bar. That incidentally solves the Dock leak the report warns about: the
/// game's Dock icon is covered rather than hidden.
public final class CoverPresenter {
    private var windows: [NSWindow] = []
    private var dismissTimer: Timer?

    public private(set) var preparedImageName: String?
    public var isPrepared: Bool { !windows.isEmpty }
    public private(set) var isShowing = false

    /// How many cover windows the *window server* has on screen.
    ///
    /// Asks CGWindowList rather than `NSWindow.occlusionState`: occlusion is only
    /// tracked for a fully-activated app, so it reads as "not visible" from a CLI
    /// process even when the window is plainly on screen. The window server's own
    /// on-screen list has no such caveat.
    public var visibleWindowCount: Int {
        guard !windows.isEmpty else { return 0 }
        let mine = ProcessInfo.processInfo.processIdentifier
        let numbers = Set(windows.map { CGWindowID($0.windowNumber) })
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return listed.filter { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == mine,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID
            else { return false }
            return numbers.contains(number)
        }.count
    }

    public init() {}

    /// Builds one window per display with the image already decoded and drawn.
    public func prepare(imageURL: URL?) {
        teardown()
        guard let imageURL, let image = NSImage(contentsOf: imageURL) else {
            preparedImageName = nil
            return
        }

        // Force decode now rather than on first draw.
        _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: .borderless,
                                  backing: .buffered,
                                  defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            // Must NOT be click-through: a stray click falling through to the
            // game underneath would be worse than no cover at all.
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: false)

            let view = CoverView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.image = image
            view.autoresizingMask = [.width, .height]
            window.contentView = view

            windows.append(window)
        }

        preparedImageName = imageURL.lastPathComponent
    }

    public func show(dismissAfterMilliseconds: Int?) {
        guard !windows.isEmpty else { return }
        for window in windows {
            window.orderFrontRegardless()
        }
        isShowing = true

        dismissTimer?.invalidate()
        dismissTimer = nil
        if let milliseconds = dismissAfterMilliseconds, milliseconds > 0 {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: Double(milliseconds) / 1000,
                                                repeats: false) { [weak self] _ in
                self?.hide()
            }
        }
    }

    public func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        for window in windows {
            window.orderOut(nil)
        }
        isShowing = false
    }

    private func teardown() {
        hide()
        windows.removeAll()
    }
}
