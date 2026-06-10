import Foundation
import Network

// ─── Ariadne's Thread [AT-0036] ─────────────────────
// What: NWPathMonitor on iPhone logs internet path for server upload steps.
// Why:  FLOW-2 and FLOW-5 must report whether iPhone has internet to reach the gateway.
// Date: 2026-06-07
// Related: [AT-0036] OpenWatchShared/FlowLog
// ─────────────────────────────────────────────────────
@MainActor
final class PhoneNetworkPathMonitor {
    static let shared = PhoneNetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openwatchagent.phone-network-monitor")
    private(set) var lastPathSummary = "status=unknown"
    private(set) var internetAvailable = false

    private init() {
        monitor.pathUpdateHandler = { path in
            let summary = Self.describe(path)
            let available = path.status == .satisfied
            Task { @MainActor in
                PhoneNetworkPathMonitor.shared.lastPathSummary = summary
                PhoneNetworkPathMonitor.shared.internetAvailable = available
                AppLog.info("iPhone internet path changed: \(summary)")
            }
        }
        monitor.start(queue: queue)
        AppLog.info("iPhone NWPathMonitor started")
    }

    private nonisolated static func describe(_ path: NWPath) -> String {
        var parts: [String] = ["status=\(path.status)"]
        if path.usesInterfaceType(.wifi) { parts.append("wifi=true") }
        if path.usesInterfaceType(.cellular) { parts.append("cellular=true") }
        if path.usesInterfaceType(.wiredEthernet) { parts.append("ethernet=true") }
        if path.usesInterfaceType(.other) { parts.append("other=true") }
        parts.append("internetAvailable=\(path.status == .satisfied)")
        parts.append("constrained=\(path.isConstrained)")
        parts.append("expensive=\(path.isExpensive)")
        return parts.joined(separator: " ")
    }
}
