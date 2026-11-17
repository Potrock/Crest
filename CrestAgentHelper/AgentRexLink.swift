import Foundation

// What the helper and the Rex tabs it opens say to each other over the
// helper's own socket, one JSON object per line. A Rex tab shows one Crest
// tab the agent uses. It never reaches Crest itself, which would take it for
// another program asking to be an agent, so it hears what the agent does from
// the helper and asks the helper to act for it.

// MARK: - Types

/// One call the agent made in a Crest tab, as its Rex tab lists it.
struct AgentRexActivity: Codable, Equatable, Sendable {
    /// The helper's number for the call, which its answer keeps.
    let call: Int
    let tool: String
    /// What the call was about, without anything the person may have typed.
    let detail: String?
    let started: Date
    var finished: Date?
    /// What Crest said when the call failed.
    var failure: String?
}

/// What a Rex tab hears from the helper.
enum AgentRexTabEvent: Codable, Sendable {
    /// The agent named itself `name`.
    case agent(name: String)
    /// The Crest tab shows `title` at `url`.
    case page(title: String, url: String?)
    /// The agent began, or finished, `activity`.
    case activity(AgentRexActivity)
    /// The Crest tab closed.
    case closed
}

/// What a Rex tab asks the helper.
enum AgentRexTabRequest: Codable, Sendable {
    /// The Rex tab shows Crest tab `tab`. A Rex tab says this first.
    case watch(tab: UUID)
    /// The person asked to see the tab in Crest.
    case show
}
