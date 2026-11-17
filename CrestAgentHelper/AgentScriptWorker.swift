import Darwin
import Foundation
import JavaScriptCore

/// The process that runs an agent's script, apart from the helper, so a
/// script that runs too long ends with its process. JavaScriptCore gives the
/// script no network, files or timers; its one way out is Crest's tools,
/// which it calls through the helper over its standard streams and waits on.
enum AgentScriptWorker {
    // MARK: - Types

    /// What the script collected for its answer.
    private final class Collected {
        var logs: [String] = []
        var images: [String] = []
        var calls = 0
        var outcome: AgentScriptEvent?
    }

    /// Lines from a file descriptor, read as they are needed.
    private final class LineReader {
        private let descriptor: Int32
        private var pending = Data()

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        func next() -> Data? {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[pending.startIndex..<newline])
                    pending.removeSubrange(pending.startIndex...newline)
                    return line
                }
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0, pending.count < AgentLineChannel.maximumLineLength else { return nil }
                pending.append(contentsOf: buffer[0..<count])
            }
        }
    }

    // MARK: - Static Variables

    /// The most tool calls one script makes.
    private static let maximumCalls = 500
    /// The longest one `sleep` waits.
    private static let maximumSleep = 30.0

    /// What every script runs inside: `crest.<tool>(arguments)` for each tool,
    /// `log` and `sleep`, and the script itself as the body of an async
    /// function, whose outcome goes to `__finish` or `__fail`.
    private static let prelude = """
        const crest = Object.freeze(Object.fromEntries(__tools.map((name) => [name, (args) => {
          const answer = JSON.parse(__call(name, JSON.stringify(args ?? {})));
          if ("error" in answer) throw new Error(answer.error);
          return answer.value;
        }])));
        const log = (...items) => __log(items.map((item) =>
          typeof item === "string" ? item : JSON.stringify(item, null, 2)).join(" "));
        const sleep = (milliseconds) => __sleep(Number(milliseconds) || 0);
        """

    // MARK: - Actions - Running

    /// Runs the script the helper sends, answering the process's exit status.
    static func run() -> Int32 {
        let input = LineReader(descriptor: STDIN_FILENO)
        let output = AgentLineChannel(input: STDIN_FILENO, output: STDOUT_FILENO)
        guard let line = input.next(),
            case .run(let script, let tools)? = try? JSONDecoder().decode(
                AgentScriptRequest.self, from: line),
            let context = JSContext()
        else { return 1 }

        let collected = Collected()
        let call: @convention(block) (String, String) -> String = { name, arguments in
            answer(name, arguments: arguments, collected: collected, input: input, output: output)
        }
        let logLine: @convention(block) (String) -> Void = { collected.logs.append($0) }
        let pause: @convention(block) (Double) -> Void = { milliseconds in
            Thread.sleep(forTimeInterval: min(max(milliseconds / 1000, 0), maximumSleep))
        }
        let finish: @convention(block) (String) -> Void = { json in
            let value = (try? JSONDecoder().decode(AgentJSON.self, from: Data(json.utf8))) ?? .null
            collected.outcome = .finished(value: value, logs: collected.logs, images: collected.images)
        }
        let fail: @convention(block) (String) -> Void = { message in
            collected.outcome = .failed(message: message, logs: collected.logs, images: collected.images)
        }
        context.setObject(tools, forKeyedSubscript: "__tools" as NSString)
        context.setObject(call, forKeyedSubscript: "__call" as NSString)
        context.setObject(logLine, forKeyedSubscript: "__log" as NSString)
        context.setObject(pause, forKeyedSubscript: "__sleep" as NSString)
        context.setObject(finish, forKeyedSubscript: "__finish" as NSString)
        context.setObject(fail, forKeyedSubscript: "__fail" as NSString)

        context.evaluateScript(prelude)
        context.evaluateScript(
            """
            (async () => {
            \(script)
            })().then(
              (value) => __finish(JSON.stringify(value === undefined ? null : value) ?? "null"),
              (error) => __fail(error instanceof Error ? `${error.name}: ${error.message}` : String(error)));
            """)
        if collected.outcome == nil, let exception = context.exception {
            collected.outcome = .failed(
                message: exception.toString() ?? "The script could not run.", logs: collected.logs,
                images: collected.images)
        }
        let outcome =
            collected.outcome
            ?? .failed(
                message:
                    "The script didn't finish. It can only await Crest's tools; it has no timers or network.",
                logs: collected.logs, images: collected.images)
        guard let event = try? JSONEncoder().encode(outcome) else { return 1 }
        output.send(event)
        return 0
    }

    /// Calls Crest's tool `name` through the helper and answers what the
    /// script reads: `{"value": …}` or `{"error": …}`, as JSON.
    private static func answer(
        _ name: String, arguments: String, collected: Collected, input: LineReader, output: AgentLineChannel
    ) -> String {
        collected.calls += 1
        guard collected.calls <= maximumCalls else {
            return reply(["error": .string("A script makes at most \(maximumCalls) tool calls.")])
        }
        let parsed = (try? JSONDecoder().decode(AgentJSON.self, from: Data(arguments.utf8))) ?? .object([:])
        guard let request = try? JSONEncoder().encode(AgentScriptEvent.call(name: name, arguments: parsed)),
            output.send(request), let line = input.next(),
            case .answered(let result)? = try? JSONDecoder().decode(AgentScriptRequest.self, from: line)
        else { return reply(["error": .string("The helper stopped answering.")]) }

        let texts = result.content.compactMap(\.text)
        if result.isError {
            return reply(["error": .string(texts.joined(separator: "\n"))])
        }
        var parts: [AgentJSON] = []
        for content in result.content {
            if let data = content.data, content.type == .image {
                collected.images.append(data)
                parts.append(.string("[image \(collected.images.count), attached to the answer]"))
            } else if let text = content.text {
                parts.append(value(of: text, collected: collected))
            }
        }
        return reply(["value": parts.count == 1 ? parts[0] : .array(parts)])
    }

    /// A tool's text as the script reads it: its JSON, after any note Crest
    /// put before it, which goes to the log; or the text itself.
    private static func value(of text: String, collected: Collected) -> AgentJSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[",
            let value = try? JSONDecoder().decode(AgentJSON.self, from: Data(trimmed.utf8))
        {
            return value
        }
        if let start = trimmed.range(of: "\n{") ?? trimmed.range(of: "\n["),
            let value = try? JSONDecoder().decode(
                AgentJSON.self, from: Data(trimmed[trimmed.index(after: start.lowerBound)...].utf8))
        {
            collected.logs.append(String(trimmed[..<start.lowerBound]))
            return value
        }
        return .string(text)
    }

    private static func reply(_ fields: [String: AgentJSON]) -> String {
        (try? JSONEncoder().encode(AgentJSON.object(fields))).map { String(decoding: $0, as: UTF8.self) }
            ?? #"{"error":"Crest's answer could not be read."}"#
    }
}
