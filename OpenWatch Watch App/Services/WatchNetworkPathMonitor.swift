import Foundation
import Network

// ─── Ariadne's Thread [AT-0035] ─────────────────────
// What: NWPathMonitor on Watch logs internet path changes to the console.
// Why:  Terminal must show whether the Watch has network (including via iPhone).
// Date: 2026-06-07
// Related: [AT-0035] app→WatchConnectivityWatchService logConnectivitySnapshot
// ─────────────────────────────────────────────────────
@MainActor
final class WatchNetworkPathMonitor {
    static let shared = WatchNetworkPathMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openwatchagent.network-monitor")
    private(set) var lastPathSummary = "status=unknown"
    private(set) var internetAvailable = false

    private init() {
        monitor.pathUpdateHandler = { path in
            let summary = Self.describe(path)
            Task { @MainActor in
                let previous = WatchNetworkPathMonitor.shared.lastPathSummary
                WatchNetworkPathMonitor.shared.lastPathSummary = summary
                WatchNetworkPathMonitor.shared.internetAvailable = path.status == .satisfied
                AppLog.info("Watch internet path changed: \(summary)")
                if previous != summary {
                    WatchConnectivityWatchService.shared.logStep2IPhoneConnect(reason: "internet-changed")
                }
            }
        }
        monitor.start(queue: queue)
        AppLog.info("Watch NWPathMonitor started")
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
