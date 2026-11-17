import Darwin
import Foundation

/// A Rex tab showing one Crest tab an agent uses: the page, and the agent's
/// calls there, newest last. It reports to Rex by the Program Status Protocol,
/// so Rex marks the tab while the agent works and while Crest asks the person
/// something before the agent can go on. `o` shows the tab in Crest and `q`
/// closes the Rex tab; closing it leaves the Crest tab as it is.
actor AgentRexTabView {
    // MARK: - Types

    /// What the Rex tab tells Rex, as one of the Program Status Protocol's
    /// states.
    struct State: Equatable, Sendable {
        static let idle = Self(name: "idle", kind: nil, color: "\u{1B}[32m")
        static let working = Self(name: "working", kind: nil, color: "\u{1B}[33m")
        /// Crest is asking the person something before the agent can go on.
        static let asking = Self(name: "blocked", kind: "permission", color: "\u{1B}[35m")
        /// The agent's connection ended.
        static let done = Self(name: "done", kind: nil, color: "\u{1B}[2m")

        let name: String
        let kind: String?
        /// How the Rex tab colours its line about the state.
        let color: String

        /// The report that tells Rex this state, with `message`.
        func report(_ message: String) -> String {
            var pairs = ["state=\(name)", "app=crest"]
            if let kind { pairs.append("kind=\(kind)") }
            let text = String(message.withoutControlCharacters.prefix(400))
            pairs.append("msg=" + Data(text.utf8).base64EncodedString())
            return "\u{1B}]7501;" + pairs.joined(separator: ":") + "\u{1B}\\"
        }
    }

    // MARK: - Static Variables

    /// Tools Crest may stop to ask the person about.
    private static let asking = [AgentToolDefinition.showTab.name, AgentToolDefinition.closeTab.name]
    /// How long one of those runs before the Rex tab says Crest is asking.
    private static let askingAfter: TimeInterval = 1

    // MARK: - Variables

    private let hub: AgentLineChannel
    private let tab: UUID
    private let clock: DateFormatter
    private var agent = "The agent"
    private var title = ""
    private var url: String?
    private var activities: [AgentRexActivity] = []
    private var isConnected = true
    private var reported: String?
    private var drawnSize: (rows: Int, columns: Int) = (0, 0)
    private var drawn = Date.distantPast
    private var original = termios()

    // MARK: - Initializers

    init(hub: AgentLineChannel, tab: UUID) {
        self.hub = hub
        self.tab = tab
        clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
    }

    // MARK: - Actions - Running

    /// Shows the tab until the person closes the Rex tab or the Crest tab
    /// closes.
    func run() async {
        enterTerminal()
        guard let watch = try? JSONEncoder().encode(AgentRexTabRequest.watch(tab: tab)), hub.send(watch) else {
            disconnected()
            return
        }
        let hub = hub
        Task {
            for await line in hub.lines() {
                guard let event = try? JSONDecoder().decode(AgentRexTabEvent.self, from: line) else { continue }
                self.receive(event)
            }
            self.disconnected()
        }
        Task {
            for await key in Self.keys() { self.press(key) }
        }
        render()
        while true {
            try? await Task.sleep(for: .milliseconds(250))
            tick()
        }
    }

    // MARK: - Actions - Events

    private func receive(_ event: AgentRexTabEvent) {
        switch event {
        case .agent(let name): agent = name.withoutControlCharacters
        case .page(let title, let url):
            self.title = title.withoutControlCharacters
            self.url = url?.withoutControlCharacters
        case .activity(let activity):
            if let index = activities.lastIndex(where: { $0.call == activity.call }) {
                activities[index] = activity
            } else {
                activities.append(activity)
            }
        case .closed: quit()
        }
        render()
    }

    private func disconnected() {
        isConnected = false
        render()
    }

    private func press(_ key: UInt8) {
        switch key {
        case UInt8(ascii: "o"), UInt8(ascii: "O"):
            if let show = try? JSONEncoder().encode(AgentRexTabRequest.show) { hub.send(show) }
        case UInt8(ascii: "q"), UInt8(ascii: "Q"): quit()
        default: break
        }
    }

    /// Redraws when the terminal changed size, or each second while a call
    /// runs, so its time and Crest's question show.
    private func tick() {
        let size = Self.size()
        let running = activities.contains { $0.finished == nil }
        if size != drawnSize || (running && Date().timeIntervalSince(drawn) >= 1) { render() }
    }

    // MARK: - Actions - Drawing

    private var state: (State, String) {
        guard isConnected else { return (.done, "\(agent) disconnected") }
        let page = title.isEmpty ? (url ?? "the tab") : title
        guard let current = activities.last(where: { $0.finished == nil }) else {
            return (.idle, activities.last.map { "\(agent) last used \($0.tool) on \(page)" } ?? "Waiting for \(agent)")
        }
        if Self.asking.contains(current.tool), Date().timeIntervalSince(current.started) > Self.askingAfter {
            return (.asking, "Crest is asking you about \(page)")
        }
        return (.working, "\(agent): \(current.tool) on \(page)")
    }

    private func render() {
        let size = Self.size()
        drawnSize = size
        drawn = Date()
        let (state, message) = state
        let report = state.report(message)
        var screen = "\u{1B}[H\u{1B}[2J"
        if report != reported {
            screen += report
            reported = report
        }
        let width = max(size.columns - 2, 10)
        var lines = [
            "\u{1B}[1m" + Self.fit(title.isEmpty ? "New Tab" : title, width) + "\u{1B}[0m",
            "\u{1B}[2m" + Self.fit(url ?? "", width) + "\u{1B}[0m",
            state.color + "● " + Self.fit(message, width - 2) + "\u{1B}[0m",
            "\u{1B}[2m" + String(repeating: "─", count: width) + "\u{1B}[0m",
        ]
        let room = max(size.rows - lines.count - 2, 0)
        lines += activities.suffix(room).map { line(for: $0, width: width) }
        screen += lines.map { " " + $0 }.joined(separator: "\r\n")
        screen +=
            "\u{1B}[\(max(size.rows, 1));1H\u{1B}[2m " + Self.fit("o Show in Crest    q Close", width) + "\u{1B}[0m"
        Self.write(screen)
    }

    private func line(for activity: AgentRexActivity, width: Int) -> String {
        let time = clock.string(from: activity.started)
        let mark: String
        var trailing = ""
        if let finished = activity.finished {
            mark = activity.failure == nil ? "\u{1B}[32m✓\u{1B}[0m" : "\u{1B}[31m✗\u{1B}[0m"
            trailing = String(format: "  %.1fs", finished.timeIntervalSince(activity.started))
            if let failure = activity.failure { trailing += "  " + failure.withoutControlCharacters }
        } else {
            mark = "\u{1B}[33m…\u{1B}[0m"
            trailing = String(format: "  %.0fs", Date().timeIntervalSince(activity.started))
        }
        let text =
            activity.tool.padding(toLength: 16, withPad: " ", startingAt: 0) + (activity.detail ?? "")
            + trailing
        return "\u{1B}[2m\(time)\u{1B}[0m \(mark) " + Self.fit(text, width - time.count - 3)
    }

    private static func fit(_ text: String, _ width: Int) -> String {
        guard width > 0 else { return "" }
        return text.count <= width ? text : String(text.prefix(max(width - 1, 0))) + "…"
    }

    // MARK: - Mutators

    private func enterTerminal() {
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        Self.write("\u{1B}[?1049h\u{1B}[?25l")
    }

    private func quit() -> Never {
        Self.write(State.idle.report("") + "\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSANOW, &original)
        exit(0)
    }

    private static func write(_ text: String) {
        Array(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDOUT_FILENO, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    private static func size() -> (rows: Int, columns: Int) {
        var size = winsize()
        guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 else { return (24, 80) }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    /// The keys the person presses, one byte each.
    private static func keys() -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            Thread.detachNewThread {
                var byte: UInt8 = 0
                while true {
                    let count = read(STDIN_FILENO, &byte, 1)
                    if count < 0, errno == EINTR { continue }
                    guard count == 1 else { break }
                    continuation.yield(byte)
                }
                continuation.finish()
            }
        }
    }
}
