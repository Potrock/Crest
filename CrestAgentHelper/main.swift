import Darwin
import Foundation

// crest-browser, the helper agents run to use Crest:
//
//   crest-browser mcp [--rex] [--compact]
//
// speaks the Model Context Protocol over its standard streams and reaches the
// Crest app it ships inside, which must be running with agents turned on.
// With --rex, an agent running in a Rex session gets a Rex tab for each Crest
// tab it uses, which runs
//
//   crest-browser rex-tab --hub SOCKET --tab ID
//
// to show that tab and what the agent does there. Its execute tool runs the
// agent's scripts in
//
//   crest-browser script-worker
//
// and --compact lists execute alone, which reaches every tool.

let usage = "usage: crest-browser mcp [--rex] [--compact]\n"
let arguments = Array(CommandLine.arguments.dropFirst())

/// The value after `option`, as `--option value`.
func value(of option: String) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

/// This helper, as it is on disk.
let helper = Bundle.main.executableURL?.resolvingSymlinksInPath()

/// The socket of the Crest this helper ships inside, at
/// Crest.app/Contents/Helpers/crest-browser, unless a review run names one.
@MainActor func socketPath() -> String? {
    if let named = value(of: "--socket") { return named }
    guard let executable = helper else { return nil }
    let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app", let identifier = Bundle(url: app)?.bundleIdentifier else { return nil }
    return AgentSocketLocation.path(forApp: identifier)
}

signal(SIGPIPE, SIG_IGN)
switch arguments.first {
case "mcp":
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let streams = AgentLineChannel(input: STDIN_FILENO, output: STDOUT_FILENO)
    let link = AgentAppLink(path: socketPath())
    let rexTabs =
        arguments.contains("--rex")
        ? AgentRexTabs.opened(environment: ProcessInfo.processInfo.environment, helper: helper, link: link) : nil
    let endpoint = AgentHelperEndpoint(
        output: streams, link: link, rexTabs: rexTabs, helper: helper, isCompact: arguments.contains("--compact"),
        version: version)
    for await line in streams.lines() {
        await endpoint.receive(line)
    }
    await rexTabs?.finish()
    exit(0)
case "script-worker":
    exit(AgentScriptWorker.run())
case "rex-tab":
    guard let hub = value(of: "--hub"), let tab = value(of: "--tab").flatMap(UUID.init(uuidString:)),
        let descriptor = AgentAppLink.connect(hub)
    else {
        FileHandle.standardError.write(Data("crest-browser: the agent that opened this tab has gone.\n".utf8))
        exit(1)
    }
    await AgentRexTabView(hub: AgentLineChannel(input: descriptor, output: descriptor), tab: tab).run()
    exit(0)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}
