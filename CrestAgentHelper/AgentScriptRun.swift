import Darwin
import Foundation

/// An agent's script, as `execute` runs it: in a process of its own, the
/// helper's script worker, which reaches nothing but Crest's tools and ends
/// when the script's time is up. Each tool the script calls goes through
/// `perform`, as if the agent had called it, so Crest and Rex see every one.
struct AgentScriptRun: Sendable {
    // MARK: - Static Variables

    static let defaultTimeout = 60.0
    static let maximumTimeout = 300.0
    /// The most text an answer carries, in characters.
    private static let maximumText = 200_000

    // MARK: - Variables

    private let helper: URL
    private let perform: @Sendable (String, AgentJSON) async -> AgentToolResult

    // MARK: - Initializers

    /// A run of the script worker inside `helper`, calling Crest's tools
    /// through `perform`.
    init(helper: URL, perform: @escaping @Sendable (String, AgentJSON) async -> AgentToolResult) {
        self.helper = helper
        self.perform = perform
    }

    // MARK: - Actions - Running

    /// Runs the script `arguments` names, answering what it returned or why
    /// it stopped.
    func result(for arguments: AgentJSON) async -> AgentToolResult {
        guard let script = arguments["script"]?.string, !script.isEmpty else {
            return .error("execute needs a script: the body of an async function.")
        }
        let timeout: Double =
            if case .number(let seconds) = arguments["timeout"] {
                min(max(seconds, 1), Self.maximumTimeout)
            } else {
                Self.defaultTimeout
            }

        let process = Process()
        process.executableURL = helper
        process.arguments = ["script-worker"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .error("Crest's script worker could not start.")
        }
        let worker = process.processIdentifier
        let channel = AgentLineChannel(
            input: output.fileHandleForReading.fileDescriptor, output: input.fileHandleForWriting.fileDescriptor)
        let tools = AgentToolDefinition.all.map(\.name)
        guard let start = try? JSONEncoder().encode(AgentScriptRequest.run(script: script, tools: tools)),
            channel.send(start)
        else {
            kill(worker, SIGKILL)
            return .error("Crest's script worker could not start.")
        }

        let started = ContinuousClock.now
        let deadline = Task {
            try await Task.sleep(for: .seconds(timeout))
            kill(worker, SIGKILL)
        }
        let outcome = await withTaskCancellationHandler {
            await exchange(over: channel)
        } onCancel: {
            kill(worker, SIGKILL)
        }
        let timedOut = outcome == nil && ContinuousClock.now - started >= .seconds(timeout - 0.5)
        deadline.cancel()
        kill(worker, SIGKILL)
        // The pipes stay open until the worker is gone, so its reads end.
        withExtendedLifetime((input, output)) {}

        switch outcome {
        case .finished(let value, let logs, let images):
            return Self.answer(value: value, logs: logs, images: images, failure: nil)
        case .failed(let message, let logs, let images):
            return Self.answer(value: nil, logs: logs, images: images, failure: message)
        case .call, nil:
            return .error(
                timedOut
                    ? "The script ran longer than \(Int(timeout)) seconds and was stopped. Pass a longer timeout, up to \(Int(Self.maximumTimeout))."
                    : "The script stopped before it finished.")
        }
    }

    /// Answers the worker's tool calls until it says how the script ended.
    private func exchange(over channel: AgentLineChannel) async -> AgentScriptEvent? {
        for await line in channel.lines() {
            guard let event = try? JSONDecoder().decode(AgentScriptEvent.self, from: line) else { return nil }
            guard case .call(let name, let arguments) = event else { return event }
            let result =
                name == AgentToolDefinition.execute.name
                ? AgentToolResult.error("A script can't run another script.")
                : await perform(name, arguments)
            guard let reply = try? JSONEncoder().encode(AgentScriptRequest.answered(result)), channel.send(reply)
            else { return nil }
        }
        return nil
    }

    /// The tool's answer: the script's log and result, or why it failed, with
    /// the images it took.
    private static func answer(value: AgentJSON?, logs: [String], images: [String], failure: String?)
        -> AgentToolResult
    {
        var sections: [String] = []
        if !logs.isEmpty { sections.append("Log:\n" + logs.joined(separator: "\n")) }
        if let failure {
            sections.append("The script failed: " + failure)
        } else if let value {
            sections.append(text(of: value))
        }
        var body = sections.joined(separator: "\n\n")
        if body.count > maximumText {
            body =
                String(body.prefix(maximumText)) + "\n… The answer was cut at \(maximumText) characters; return less."
        }
        let pictures = images.map { AgentToolResult.Content(type: .image, text: nil, data: $0, mimeType: "image/png") }
        return AgentToolResult(content: [.text(body.isEmpty ? "null" : body)] + pictures, isError: failure != nil)
    }

    private static func text(of value: AgentJSON) -> String {
        if case .string(let text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}
