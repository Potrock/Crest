import Foundation

// What the helper and the process running an agent's script say to each
// other, one JSON line at a time over the process's standard streams.

/// What the helper says to the script's process.
enum AgentScriptRequest: Codable, Sendable {
    /// Run `script`, the body of an async function, with Crest's `tools`.
    case run(script: String, tools: [String])
    /// What Crest answered the call the script is waiting on.
    case answered(AgentToolResult)
}

/// What the script's process says to the helper.
enum AgentScriptEvent: Codable, Sendable {
    /// The script calls Crest's tool `name` with `arguments`, and waits.
    case call(name: String, arguments: AgentJSON)
    /// The script returned `value`, having logged `logs` and taken `images`,
    /// each a PNG in Base64.
    case finished(value: AgentJSON, logs: [String], images: [String])
    /// The script threw or could not run.
    case failed(message: String, logs: [String], images: [String])
}
