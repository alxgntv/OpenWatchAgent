import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchAppModel.shared

    var body: some View {
        NavigationStack {
            if model.isPaired {
                // Outer axis = HORIZONTAL (default watchOS paging): page 0 is the live stack (unchanged),
                // swiping left/right reveals one page per real gateway session mirrored from the iPhone.
                // Horizontal order: Usage (left) · live stack (main) · one page per gateway session (right).
                TabView(selection: $model.horizontalIndex) {
                    UsagePage(model: model)
                        .tag(0)
                    liveStack
                        .tag(1)
                    ForEach(Array(model.gatewaySessions.enumerated()), id: \.element.id) { idx, gatewaySession in
                        GatewaySessionPage(model: model, session: gatewaySession)
                            .tag(idx + 2)
                    }
                }
            } else {
                WatchNotPairedView()
            }
        }
        .onAppear {
            // Always open on the main (live) screen.
            model.horizontalIndex = 1
            WatchConnectivityWatchService.shared.requestSync()
            AppLog.info("OpenWatch Watch app launched")
        }
    }

    /// The existing vertical session stack, untouched: swipe up to the empty top page starts a brand-new session.
    private var liveStack: some View {
        TabView(selection: $model.currentIndex) {
            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { idx, session in
                WatchSessionPage(model: model, session: session, index: idx)
                    .tag(idx)
            }
        }
        .tabViewStyle(.verticalPage)
    }
}

#Preview {
    ContentView()
}
