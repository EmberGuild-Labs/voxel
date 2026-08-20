import AppKit
import Carbon.HIToolbox
import Foundation

/// A global hotkey, stored as a raw virtual keycode plus modifier flags.
///
/// Keycodes are `kVK_ANSI_*` values from Carbon. They are layout-independent
/// (physical key positions), which is what we want: the panic key should sit in
/// the same spot regardless of the user's keyboard layout.
public struct HotkeyBinding: Codable, Equatable {
    public var keyCode: UInt32
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    public init(keyCode: UInt32, control: Bool = false, option: Bool = false,
                command: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if control { mask |= UInt32(controlKey) }
        if option { mask |= UInt32(optionKey) }
        if command { mask |= UInt32(cmdKey) }
        if shift { mask |= UInt32(shiftKey) }
        return mask
    }

    public var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "key\(keyCode)")
    }

    static let keyNames: [UInt32: String] = [
        4: "H", 38: "J", 40: "K", 37: "L", 6: "Z", 7: "X", 8: "C", 9: "V",
        49: "Space", 53: "Escape", 105: "F13", 107: "F14", 113: "F15",
    ]
}

/// A cover story: what to hide, and what to show instead.
public struct Profile: Codable {
    public var name: String
    /// Bundle identifiers to hide on panic.
    public var conceal: [String]
    /// Bundle identifiers to bring forward. The first entry becomes frontmost.
    public var reveal: [String]
    /// Mute system output on panic and restore it on resume.
    public var mute: Bool

    public init(name: String, conceal: [String], reveal: [String], mute: Bool = true) {
        self.name = name
        self.conceal = conceal
        self.reveal = reveal
        self.mute = mute
    }
}

public struct Config: Codable {
    public var panicKey: HotkeyBinding
    public var resumeKey: HotkeyBinding
    public var profile: Profile
    public var cover: CoverSettings

    public init(panicKey: HotkeyBinding,
                resumeKey: HotkeyBinding,
                profile: Profile,
                cover: CoverSettings = CoverSettings()) {
        self.panicKey = panicKey
        self.resumeKey = resumeKey
        self.profile = profile
        self.cover = cover
    }

    /// Decoded leniently so a config written by an older build -- one with no
    /// `cover` key at all -- keeps working instead of failing to parse and
    /// silently reverting the user to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        panicKey = try container.decode(HotkeyBinding.self, forKey: .panicKey)
        resumeKey = try container.decode(HotkeyBinding.self, forKey: .resumeKey)
        profile = try container.decode(Profile.self, forKey: .profile)
        cover = try container.decodeIfPresent(CoverSettings.self, forKey: .cover) ?? CoverSettings()
    }

    /// Defaults are deliberately two-handed chords. Single-key ergonomics is an
    /// open question the P0 spike exists to answer -- see README.
    public static let fallback = Config(
        panicKey: HotkeyBinding(keyCode: 4, control: true, option: true, command: true),   // ⌃⌥⌘H
        resumeKey: HotkeyBinding(keyCode: 38, control: true, option: true, command: true), // ⌃⌥⌘J
        profile: Profile(
            name: "Untitled",
            conceal: [],
            reveal: [],
            mute: true
        )
    )
}

public enum ConfigStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Voxel", isDirectory: true)
    }

    public static var url: URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return .fallback }
        return config
    }

    @discardableResult
    public static func save(_ config: Config) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
        return url
    }

    public static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
