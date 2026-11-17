import Foundation

extension AgentToolDefinition {
    // MARK: - Static Variables

    /// The helper's own tool: a script that calls Crest's tools in one step,
    /// so work that takes many calls takes one, and the agent reads only what
    /// the script returns.
    static let execute = Self(
        name: "execute", title: "Run a Crest script",
        description: executeDescription,
        arguments: [
            .string("script", "The body of an async function that calls crest.<tool>(arguments) and returns a result."),
            .number(
                "timeout",
                "Seconds the script may run, up to \(Int(AgentScriptRun.maximumTimeout)). Defaults to \(Int(AgentScriptRun.defaultTimeout))."
            ),
        ], readOnly: false, destructive: true, idempotent: false, openWorld: true)

    /// What `execute` says it does, with every tool a script can call.
    private static let executeDescription = """
        Runs JavaScript that calls Crest's tools in one step: use it for any work that takes more than one call, and \
        return only what you need. The script is the body of an async function. Call a tool as \
        `await crest.<tool>({…arguments})`: it returns the tool's JSON as an object, or its text, and throws when the \
        tool refuses. `log(…)` adds lines to the answer, `sleep(ms)` waits, and `return` gives the result. \
        Screenshots are attached to the answer. Scripts reach nothing but these tools: no network, files or timers.

        Example:
        const { tab } = await crest.open_tab({ space, url: "https://example.com" });
        const outline = await crest.take_snapshot({ tab: tab.id });
        return outline.slice(0, 2000);

        Tools:
        \(all.map(\.signature).joined(separator: "\n"))
        """

    // MARK: - Variables

    /// How a script calls the tool, with its arguments, optional ones marked,
    /// and what it does.
    var signature: String {
        let names = arguments.map { $0.isRequired ? $0.name : $0.name + "?" }
        let call = names.isEmpty ? "crest.\(name)()" : "crest.\(name)({ \(names.joined(separator: ", ")) })"
        let summary = description.range(of: ". ").map { String(description[..<$0.lowerBound]) } ?? description
        return "\(call): \(summary.hasSuffix(".") ? String(summary.dropLast()) : summary)."
    }
}
