import AppKit
import Foundation
import VoxelCore

// MARK: - Terminal formatting

enum Style {
    static let isTTY = isatty(fileno(stdout)) == 1

    static func wrap(_ text: String, _ code: String) -> String {
        isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ t: String) -> String { wrap(t, "1") }
    static func dim(_ t: String) -> String { wrap(t, "2") }
    static func red(_ t: String) -> String { wrap(t, "31") }
    static func yellow(_ t: String) -> String { wrap(t, "33") }
    static func green(_ t: String) -> String { wrap(t, "32") }
    static func cyan(_ t: String) -> String { wrap(t, "36") }
}

/// Wraps prose to the terminal width so long explanations stay readable.
func wrapped(_ text: String, indent: Int) -> String {
    var width = 100
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 40 {
        width = min(Int(size.ws_col), 100)
    }
    let limit = max(width - indent, 30)
    let pad = String(repeating: " ", count: indent)

    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= limit {
            current += " " + word
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines.enumerated()
        .map { $0.offset == 0 ? $0.element : pad + $0.element }
        .joined(separator: "\n")
}

// MARK: - Commands

func runLeaks() {
    let config = ConfigStore.load()
    let leaks = LeakReport.run(profile: config.profile)

    print("")
    print(Style.bold("Leak report") + Style.dim("  ·  profile \"\(config.profile.name)\""))
    print("")

    guard !leaks.isEmpty else {
        print("  " + Style.green("Nothing leaking.") + " Panic should be clean.\n")
        return
    }

    for leak in leaks {
        let (marker, colour): (String, (String) -> String) = {
            switch leak.severity {
            case .critical: return ("CRITICAL", Style.red)
            case .warning: return (" WARNING", Style.yellow)
            case .info: return ("    INFO", Style.dim)
            }
        }()

        print("  \(colour(marker))  \(Style.bold(leak.title))")
        print("            " + wrapped(leak.detail, indent: 12))
        if !leak.fix.isEmpty {
            print("            " + Style.cyan("fix: ") + wrapped(leak.fix, indent: 17))
        }
        print("")
    }

    let critical = leaks.filter { $0.severity == .critical }.count
    let warnings = leaks.filter { $0.severity == .warning }.count
    print(Style.dim("  \(critical) critical, \(warnings) warning\n"))
}

/// Counts down before capturing so you can switch to the app you actually care
/// about. Without this, running capture from a shell means the terminal is
/// frontmost and the heuristic has nothing useful to look at.
func countdown(_ seconds: Int) {
    guard seconds > 0 else { return }
    print("")
    for remaining in stride(from: seconds, to: 0, by: -1) {
        let message = "  Capturing in \(remaining)s — switch to the setup you want to record..."
        if Style.isTTY {
            print("\u{1B}[2K\r" + message, terminator: "")
            fflush(stdout)
        } else {
            print(message)
        }
        Thread.sleep(forTimeInterval: 1)
    }
    if Style.isTTY { print("\u{1B}[2K\r", terminator: "") }
}

func runCapture(name: String, delay: Int) {
    countdown(delay)
    let existing = ConfigStore.load()
    let result = ProfileCapture.capture(name: name, existing: existing)

    print("")
    print(Style.bold("Captured \"\(name)\""))
    print("")

    for decision in result.decisions {
        let label: String
        switch decision.classification {
        case .conceal: label = Style.red("conceal")
        case .reveal: label = Style.green("reveal ")
        case .ignore: label = Style.dim("ignore ")
        }
        let front = decision.isFrontmost ? Style.cyan(" ←front") : ""
        let padded = decision.name.padding(toLength: max(24, decision.name.count),
                                           withPad: " ", startingAt: 0)
        print("  \(label)  \(padded)\(front)")
        print("           \(Style.dim(decision.reason))  \(Style.dim(decision.bundleID))")
    }

    var config = existing
    config.profile = result.profile
    do {
        let url = try ConfigStore.save(config)
        print("")
        print("  Wrote \(url.path)")
        print("  " + Style.dim("Edit it to fix anything above that landed in the wrong bucket."))
        print("  " + Style.dim("The agent re-reads it on every panic — no restart needed."))
        print("")
    } catch {
        print("")
        print("  " + Style.red("Failed to write config: \(error.localizedDescription)"))
        print("")
    }
}

/// Runs the real panic sequence in-process, holds, then resumes -- so you can
/// see and time the thing without needing the agent or a free hand.
///
/// Timings here are indicative, not authoritative: the CLI has no run loop and
/// activation from a non-accessory process behaves slightly differently. The
/// number that actually matters comes from screen-recording the agent at 60fps
/// and counting frames.
func runDryRun(hold: Double) {
    let config = ConfigStore.load()
    let concealer = Concealer()

    print("")
    print(Style.bold("Dry run") + Style.dim("  ·  profile \"\(config.profile.name)\""))
    print("  " + Style.dim("Concealing for \(String(format: "%.1f", hold))s, then restoring."))
    print("")

    let panicTiming = concealer.panic(profile: config.profile)
    Thread.sleep(forTimeInterval: hold)
    let resumeTiming = concealer.resume()

    for (label, timing) in [("panic ", panicTiming), ("resume", resumeTiming)] {
        let total = timing.total
        let colour = total < 150 ? Style.green : (total < 400 ? Style.yellow : Style.red)
        print("  \(Style.bold(label))  " + colour(String(format: "%6.1f ms", total)))
        for phase in timing.phases {
            print("            \(Style.dim(phase.name.padding(toLength: 10, withPad: " ", startingAt: 0)))"
                  + String(format: "%6.1f ms", phase.milliseconds))
        }
    }
    print("")
    print("  " + Style.dim("<150ms is the target. Screen-record at 60fps for the real number."))
    print("")
}

func runConfig() {
    print("")
    print("  " + ConfigStore.url.path)
    print("")
    if let text = try? String(contentsOf: ConfigStore.url, encoding: .utf8) {
        print(text)
    } else {
        print("  " + Style.dim("Not created yet. Run `voxel capture` first."))
        print("")
    }
}

func runHelp() {
    print("""

    \(Style.bold("voxel")) — operator CLI for the CoreAudioHelper agent

      \(Style.cyan("capture [name]"))   Snapshot what's running and sort it into a cover story
                       \(Style.dim("--in <seconds>  count down first, so you can switch to the game"))
      \(Style.cyan("leaks"))            Audit what would still give you away after a panic
      \(Style.cyan("dry-run"))          Run panic, hold, then resume — with per-phase timings
                       \(Style.dim("--hold <seconds>  how long to stay concealed (default 2)"))
      \(Style.cyan("config"))           Print the config file path and contents
      \(Style.cyan("help"))             This

    """)
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "capture":
    // `voxel capture Homework --in 5`
    var captureName = "Default"
    var captureDelay = 0
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--in", index + 1 < arguments.count, let seconds = Int(arguments[index + 1]) {
            captureDelay = max(0, min(seconds, 60))
            index += 2
        } else if !argument.hasPrefix("--") {
            captureName = argument
            index += 1
        } else {
            index += 1
        }
    }
    runCapture(name: captureName, delay: captureDelay)
case "leaks", "leak":
    runLeaks()
case "dry-run", "dryrun":
    var hold = 2.0
    if arguments.count > 2, arguments[1] == "--hold", let seconds = Double(arguments[2]) {
        hold = max(0.2, min(seconds, 30))
    }
    runDryRun(hold: hold)
case "config":
    runConfig()
case "help", "--help", "-h", nil:
    runHelp()
case .some(let unknown):
    print("Unknown command: \(unknown)")
    runHelp()
    exit(1)
}
