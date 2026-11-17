import Darwin
import Foundation

/// The Rex tabs of a helper whose agent runs in a Rex session. Each Crest tab
/// the agent uses gets a tab of its own in the agent's Rex session, opened
/// behind the person's work, which shows the page and what the agent does
/// there. The helper is the only program Crest knows as the agent, so its Rex
/// tabs hear from it over a socket only the person's account reaches, and ask
/// it to act for them.
actor AgentRexTabs {
    // MARK: - Types

    /// A Crest tab the agent used, as its Rex tab shows it.
    private struct Watched {
        var title = ""
        var url: String?
        /// The Space the tab is in, once Crest said.
        var space: UUID?
        /// Counts the page's refreshes, so only the latest one goes on.
        var refresh = 0
        var activities: [AgentRexActivity] = []
        /// The Rex window showing the tab, once Rex made it.
        var window: String?
        var isOpening = false
        var viewers: [ObjectIdentifier: AgentLineChannel] = [:]
        /// The person closed the tab's Rex tab, so it stays closed.
        var isDismissed = false

        /// The window's label, as Rex shows it in the tab bar.
        var label: String {
            let name = title.isEmpty ? (url.flatMap { URL(string: $0)?.host } ?? "Crest") : title
            return "🌐 " + String(name.withoutControlCharacters.prefix(48))
        }
    }

    /// A call the agent is making.
    private struct Running {
        let tab: UUID?
        /// The name the agent gave itself, when the call is `identify`.
        let introduced: String?
        var activity: AgentRexActivity
    }

    /// The tab a tab tool answers with, as Crest lists it.
    private struct TabAnswer: Decodable {
        struct Tab: Decodable {
            let id: UUID
            let title: String
            let url: String?
            let space: UUID?
        }

        let tab: Tab?
    }

    /// What `list_tabs` answers.
    private struct TabList: Decodable {
        let tabs: [TabAnswer.Tab]
    }

    /// What `rex window new --json` answers.
    private struct CreatedWindow: Decodable {
        let window: String

        private enum CodingKeys: String, CodingKey {
            case window = "window_id"
        }
    }

    /// What `session.set_window_label` takes.
    private struct WindowLabel: Encodable {
        let window: String
        let label: String

        private enum CodingKeys: String, CodingKey {
            case window = "window_id"
            case label
        }
    }

    // MARK: - Static Variables

    /// Arguments a Rex tab shows as they are. Anything else, such as text the
    /// agent fills or types and the scripts it runs, it shows only by length.
    private static let shownArguments = ["url", "action", "uid", "key", "dy"]
    private static let measuredArguments = ["value", "text", "function"]
    /// The most calls a Rex tab keeps for a tab.
    private static let history = 200
    /// Calls that can take a tab to another page. Crest answers them before
    /// the page loads, so the tab's page is read again while it does.
    private static let pageChanges: Set<String> = [
        AgentToolDefinition.openTab.name, AgentToolDefinition.navigate.name, AgentToolDefinition.click.name,
        AgentToolDefinition.pressKey.name,
    ]
    /// How long after such a call each read waits for the one before.
    private static let refreshDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]

    // MARK: - Variables

    private let session: String
    private let rex: URL
    private let helper: URL
    private let link: AgentAppLink
    private let socket: String
    private var tabs: [UUID: Watched] = [:]
    private var running: [Int: Running] = [:]
    private var nextCall = 1
    private var agent: String?
    private var client: AgentClientInfo?

    // MARK: - Initializers

    /// The Rex tabs for an agent in Rex session `session`, opened by the `rex`
    /// at `rex` and running `helper`, which call Crest through `link`.
    private init(session: String, rex: URL, helper: URL, link: AgentAppLink, socket: String) {
        self.session = session
        self.rex = rex
        self.helper = helper
        self.link = link
        self.socket = socket
    }

    /// The Rex tabs of a helper at `helper` whose agent runs in Rex, as its
    /// `environment` says, or nil when it runs elsewhere or Rex can't be reached.
    static func opened(environment: [String: String], helper: URL?, link: AgentAppLink) -> AgentRexTabs? {
        guard let session = environment["REX_SESSION"], !session.isEmpty, let helper,
            let rex = executable("rex", path: environment["PATH"]), let socket = listen()
        else { return nil }
        let tabs = AgentRexTabs(session: session, rex: rex, helper: helper, link: link, socket: socket.path)
        Thread.detachNewThread {
            while true {
                let client = accept(socket.descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    break
                }
                var user = uid_t()
                var group = gid_t()
                guard getpeereid(client, &user, &group) == 0, user == getuid() else {
                    close(client)
                    continue
                }
                Task { await tabs.attach(AgentLineChannel(input: client, output: client)) }
            }
        }
        return tabs
    }

    // MARK: - Actions - Calls

    /// The agent began calling `tool` with `arguments`, as `client`. Answers
    /// the call's number, which `ended` takes.
    func began(_ tool: String, arguments: AgentJSON, client: AgentClientInfo?) -> Int {
        if let client {
            self.client = client
            if agent == nil { agent = client.title ?? client.name }
        }
        let call = nextCall
        nextCall += 1
        let tab = arguments["tab"]?.string.flatMap(UUID.init(uuidString:))
        let activity = AgentRexActivity(
            call: call, tool: tool, detail: Self.detail(of: arguments), started: Date(), finished: nil, failure: nil)
        let introduced = tool == AgentToolDefinition.identify.name ? arguments["name"]?.string : nil
        running[call] = Running(
            tab: tab, introduced: introduced.map { $0.withoutControlCharacters }, activity: activity)
        if let tab, tabs[tab] != nil { record(activity, in: tab) }
        return call
    }

    /// Call `call` answered `result`.
    func ended(_ call: Int, result: AgentToolResult) {
        guard var finished = running.removeValue(forKey: call) else { return }
        finished.activity.finished = Date()
        if result.isError { finished.activity.failure = result.content.compactMap(\.text).first }
        if let name = finished.introduced, !result.isError {
            agent = name
            broadcast(.agent(name: name))
        }
        let answer = Self.tab(in: result)
        guard let id = finished.tab ?? answer?.id else { return }
        if tabs[id] == nil {
            // A Rex tab opens only for a tab the agent reached.
            guard !result.isError else { return }
            tabs[id] = Watched()
        }
        record(finished.activity, in: id)
        if let answer, answer.id == id {
            if let space = answer.space { tabs[id]?.space = space }
            retitle(id, title: answer.title, url: answer.url)
        }
        if !result.isError, Self.pageChanges.contains(finished.activity.tool) { refreshPage(id) }
        if finished.activity.tool == AgentToolDefinition.closeTab.name, !result.isError {
            send(.closed, to: id)
            tabs[id]?.isDismissed = true
            return
        }
        openIfNeeded(id)
    }

    /// The helper is ending: its socket goes, and its Rex tabs see the agent
    /// disconnect when the helper exits.
    func finish() {
        unlink(socket)
    }

    // MARK: - Actions - Rex Tabs

    /// A Rex tab connected over `channel`.
    private func attach(_ channel: AgentLineChannel) async {
        var watching: UUID?
        for await line in channel.lines() {
            guard let request = try? JSONDecoder().decode(AgentRexTabRequest.self, from: line) else { continue }
            switch request {
            case .watch(let id):
                guard watching == nil, let tab = tabs[id] else { continue }
                watching = id
                tabs[id]?.viewers[ObjectIdentifier(channel)] = channel
                if let agent { Self.send(.agent(name: agent), on: channel) }
                Self.send(.page(title: tab.title, url: tab.url), on: channel)
                for activity in tab.activities { Self.send(.activity(activity), on: channel) }
            case .show:
                guard let watching else { continue }
                Task {
                    _ = try? await link.call(
                        AgentToolDefinition.showTab.name, arguments: .object(["tab": .string(watching.uuidString)]),
                        client: client)
                }
            }
        }
        channel.close()
        guard let watching else { return }
        tabs[watching]?.viewers.removeValue(forKey: ObjectIdentifier(channel))
        if tabs[watching]?.viewers.isEmpty == true { tabs[watching]?.isDismissed = true }
    }

    private func openIfNeeded(_ id: UUID) {
        guard let tab = tabs[id], tab.window == nil, !tab.isOpening, !tab.isDismissed else { return }
        tabs[id]?.isOpening = true
        let arguments = [
            "window", "new", "-s", session, tab.label, "--focus=false", "--shell=none", "--json", "--",
            helper.path, "rex-tab", "--hub", socket, "--tab", id.uuidString,
        ]
        Task {
            let created = await run(arguments).flatMap { try? JSONDecoder().decode(CreatedWindow.self, from: $0) }
            opened(id, window: created?.window)
        }
    }

    /// Reads the tab's page from Crest again while it loads, so its Rex tab
    /// shows where it landed rather than where it was.
    private func refreshPage(_ id: UUID) {
        guard let space = tabs[id]?.space else { return }
        tabs[id]?.refresh += 1
        let generation = tabs[id]?.refresh
        let arguments = AgentJSON.object(["space": .string(space.uuidString)])
        Task {
            for delay in Self.refreshDelays {
                try? await Task.sleep(for: delay)
                guard tabs[id]?.refresh == generation, tabs[id]?.isDismissed == false else { return }
                guard
                    let result = try? await link.call(
                        AgentToolDefinition.listTabs.name, arguments: arguments, client: client),
                    let listed = Self.decoded(TabList.self, in: result)?.tabs.first(where: { $0.id == id })
                else { continue }
                retitle(id, title: listed.title, url: listed.url)
            }
        }
    }

    private func opened(_ id: UUID, window: String?) {
        tabs[id]?.isOpening = false
        tabs[id]?.window = window
        // Rex couldn't open it, so the tab goes without one.
        if window == nil { tabs[id]?.isDismissed = true }
    }

    // MARK: - Mutators

    private func record(_ activity: AgentRexActivity, in id: UUID) {
        guard var tab = tabs[id] else { return }
        if let index = tab.activities.lastIndex(where: { $0.call == activity.call }) {
            tab.activities[index] = activity
        } else {
            tab.activities.append(activity)
            if tab.activities.count > Self.history { tab.activities.removeFirst(tab.activities.count - Self.history) }
        }
        tabs[id] = tab
        send(.activity(activity), to: id)
    }

    private func retitle(_ id: UUID, title: String, url: String?) {
        guard let tab = tabs[id], tab.title != title || tab.url != url else { return }
        let label = tab.label
        tabs[id]?.title = title
        tabs[id]?.url = url
        send(.page(title: title, url: url), to: id)
        guard let window = tab.window, let relabelled = tabs[id]?.label, relabelled != label,
            let body = try? JSONEncoder().encode(WindowLabel(window: window, label: relabelled))
        else { return }
        let arguments = [
            "api", "call", "-s", session, "session.set_window_label", String(decoding: body, as: UTF8.self),
        ]
        Task { _ = await run(arguments) }
    }

    private func send(_ event: AgentRexTabEvent, to id: UUID) {
        guard let viewers = tabs[id]?.viewers.values else { return }
        for viewer in viewers { Self.send(event, on: viewer) }
    }

    private func broadcast(_ event: AgentRexTabEvent) {
        for id in tabs.keys { send(event, to: id) }
    }

    private static func send(_ event: AgentRexTabEvent, on channel: AgentLineChannel) {
        guard let line = try? JSONEncoder().encode(event) else { return }
        channel.send(line)
    }

    /// Runs `rex` with `arguments`, answering what it printed when it
    /// succeeded. It never shares the agent's streams, which carry the
    /// protocol.
    private nonisolated func run(_ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = rex
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reader = output.fileHandleForReading
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = reader.readDataToEndOfFile()
                continuation.resume(returning: finished.terminationStatus == 0 ? data : nil)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }

    /// What a call with `arguments` was about, as a Rex tab lists it.
    private static func detail(of arguments: AgentJSON) -> String? {
        var parts: [String] = []
        for name in shownArguments {
            switch arguments[name] {
            case .string(let value): parts.append(value)
            case .number(let value): parts.append(name + " " + String(Int(value)))
            default: break
            }
        }
        for name in measuredArguments {
            if let value = arguments[name]?.string { parts.append("\(value.count) characters") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ").withoutControlCharacters
    }

    /// The tab a tab tool answered with.
    private static func tab(in result: AgentToolResult) -> TabAnswer.Tab? {
        decoded(TabAnswer.self, in: result)?.tab
    }

    /// A tool's answer as `type`: its JSON, after any note Crest put before it.
    private static func decoded<Answer: Decodable>(_ type: Answer.Type, in result: AgentToolResult) -> Answer? {
        guard !result.isError, let text = result.content.compactMap(\.text).first else { return nil }
        let json =
            text.hasPrefix("{")
            ? Substring(text) : text.range(of: "\n{").map { text[text.index(before: $0.upperBound)...] }
        guard let json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private static func executable(_ name: String, path: String?) -> URL? {
        for directory in (path ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// A socket listening in a folder only the person's account reaches.
    private static func listen() -> (descriptor: Int32, path: String)? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crest-rex", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { return nil }
        let path = directory.appendingPathComponent("\(getpid()).sock").path
        guard path.utf8.count <= AgentSocketLocation.maximumPathLength else { return nil }
        unlink(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8.prefix(bytes.count - 1)))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        return (descriptor, path)
    }
}
