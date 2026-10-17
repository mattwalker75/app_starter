// A bundle's light: green when every app in it is up, red when every one is down, yellow when some are up and
// some are down (Matt's rule). An empty bundle has no light.
import Foundation

public enum BundleStatus: String, Equatable, Sendable {
    case allUp, allDown, mixed, empty, allPaused

    public static func of(_ up: [Bool]) -> BundleStatus {
        if up.isEmpty { return .empty }
        if up.allSatisfy({ $0 }) { return .allUp }
        if !up.contains(true) { return .allDown }
        return .mixed
    }

    public var label: String {
        switch self { case .allUp: return "All up"; case .allDown: return "All down"; case .mixed: return "Some up, some down"; case .empty: return "No apps yet"; case .allPaused: return "All paused" }
    }
}
