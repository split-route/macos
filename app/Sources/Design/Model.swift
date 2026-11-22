import Foundation

public enum TunnelState: Equatable, Sendable {
    case off, connecting, needsAuth, connected
    /// A tunnel with no session of its own: running, but nothing proves the server answers.
    case ready
    case failed(String)

    public var label: String {
        switch self {
        case .off: return "Off"
        case .connecting: return "Connecting"
        case .needsAuth: return "Needs sign-in"
        case .connected: return "Connected"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    public var actionTitle: String {
        switch self {
        case .off: return "Connect"
        case .connecting: return "Cancel"
        case .needsAuth: return "Sign in"
        case .connected, .ready: return "Disconnect"
        case .failed: return "Retry"
        }
    }
}

public struct TunnelItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var detail: String
    public var line: Line
    public var state: TunnelState
    public init(id: String, name: String, detail: String, line: Line, state: TunnelState) {
        self.id = id; self.name = name; self.detail = detail; self.line = line; self.state = state
    }
}

public enum ListAction: String, CaseIterable, Sendable {
    case direct = "Direct", block = "Block", tunnel = "Tunnel"
}

public struct ListItem: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var note: String
    public var action: ListAction
    public var tunnelID: String?
    /// A failed download or import, shown under the row with a retry.
    public var problem: String?
    public init(id: String, name: String, note: String, action: ListAction, tunnelID: String? = nil, problem: String? = nil) {
        self.id = id; self.name = name; self.note = note; self.action = action; self.tunnelID = tunnelID; self.problem = problem
    }
}

public struct ActivityItem: Identifiable, Sendable {
    public let id = UUID()
    public let time: String
    public let text: String
    public let isError: Bool
    public init(time: String, text: String, isError: Bool = false) { self.time = time; self.text = text; self.isError = isError }
}
