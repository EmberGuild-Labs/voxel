import AppKit
import Foundation

/// Snapshots what is running right now and sorts it into a cover story.
///
/// The configuration story for Voxel is one button: arrange your machine the way
/// you want it to look, capture, correct the one or two guesses that are wrong.
/// The heuristics below only need to be good enough that correcting is faster
/// than building a profile by hand.
public enum ProfileCapture {

    public enum Classification: String {
        case conceal
        case reveal
        case ignore

        /// Display order: the things you must check first, first.
        var rank: Int {
            switch self {
            case .conceal: return 0
            case .reveal: return 1
            case .ignore: return 2
            }
        }
    }

    public struct Decision {
        public let bundleID: String
        public let name: String
        public let classification: Classification
        public let reason: String
        public let isFrontmost: Bool
    }

    public struct CaptureResult {
        public let profile: Profile
        public let decisions: [Decision]
    }

    /// Substrings that show up in the bundle ID or on-disk path of games and the
    /// launchers/translation layers that run them.
    private static let gameMarkers = [
        "steam", "valvesoftware", "epicgames", "epic games", "blizzard", "battle.net",
        "minecraft", "riotgames", "leagueoflegends", "roblox", "ubisoft", "origin",
        "ea app", "gog.com", "galaxy", "crossover", "whisky", "porting kit", "playonmac",
        "unity.", "unrealengine", "/applications/games/",
    ]

    /// Apps that make a plausible thing to be doing instead.
    private static let decoyBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.apple.Notes", "com.apple.TextEdit", "com.apple.Preview", "com.apple.iWork.Pages",
        "com.apple.iWork.Numbers", "com.apple.iWork.Keynote", "com.apple.mail",
        "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        "com.microsoft.Outlook", "md.obsidian", "notion.id", "com.tinyapp.TablePlus",
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.Terminal",
    ]

    /// Running `voxel capture` from a shell makes the terminal frontmost by
    /// definition, so the frontmost heuristic must never fire on one.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper",
        "com.mitchellh.ghostty", "com.anthropic.claudefordesktop",
    ]

    /// Menu-bar utilities and system agents -- irrelevant either way.
    private static func isSystemNoise(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return true }
        if id == Bundle.main.bundleIdentifier { return true }
        if id.hasPrefix("com.apple.") && decoyBundleIDs.contains(id) == false {
            // Finder is always running and never a meaningful decoy on its own.
            return id == "com.apple.finder" || id == "com.apple.systemuiserver"
        }
        return false
    }

    public static func capture(name: String, existing: Config = ConfigStore.load()) -> CaptureResult {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var decisions: [Decision] = []

        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier != nil }

        for app in apps {
            let bundleID = app.bundleIdentifier!
            let label = app.localizedName ?? bundleID
            let path = (app.bundleURL?.path ?? "").lowercased()
            let haystack = bundleID.lowercased() + " " + path

            let classification: Classification
            let reason: String

            if isSystemNoise(app) {
                classification = .ignore
                reason = "system app"
            } else if let marker = gameMarkers.first(where: { haystack.contains($0) }) {
                classification = .conceal
                reason = "matched \"\(marker)\""
            } else if decoyBundleIDs.contains(bundleID) {
                classification = .reveal
                reason = "known cover-story app"
            } else if bundleID == frontmost, !terminalBundleIDs.contains(bundleID) {
                // You captured while the thing you care about was in front.
                classification = .conceal
                reason = "frontmost when captured"
            } else {
                classification = .ignore
                reason = "unrecognised -- sort this one yourself"
            }

            decisions.append(Decision(bundleID: bundleID,
                                      name: label,
                                      classification: classification,
                                      reason: reason,
                                      isFrontmost: bundleID == frontmost))
        }

        decisions.sort { lhs, rhs in
            if lhs.classification != rhs.classification {
                return lhs.classification.rank < rhs.classification.rank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let conceal = decisions.filter { $0.classification == .conceal }.map(\.bundleID)
        var reveal = decisions.filter { $0.classification == .reveal }.map(\.bundleID)

        // Whichever decoy was most recently in front is the most plausible thing
        // to have "been doing", so it goes to the front on panic.
        if let recentDecoy = mostRecentlyUsedDecoy(among: reveal) {
            reveal.removeAll { $0 == recentDecoy }
            reveal.insert(recentDecoy, at: 0)
        }

        let profile = Profile(name: name,
                              conceal: conceal,
                              reveal: reveal,
                              mute: existing.profile.mute)
        return CaptureResult(profile: profile, decisions: decisions)
    }

    /// `runningApplications` is ordered oldest-first, but the app the user
    /// touched most recently before the frontmost one is a better default front
    /// than an arbitrary pick, so approximate with launch recency.
    private static func mostRecentlyUsedDecoy(among candidates: [String]) -> String? {
        let apps = NSWorkspace.shared.runningApplications
            .filter { candidates.contains($0.bundleIdentifier ?? "") }
        return apps.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) })?
            .bundleIdentifier
    }
}
