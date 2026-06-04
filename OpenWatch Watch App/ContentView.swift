import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchAppModel.shared

    var body: some View {
        NavigationStack {
            if model.isPaired {
                // Outer axis = HORIZONTAL (default watchOS paging): page 0 is the live stack (unchanged),
                // swiping left/right reveals one page per real gateway session mirrored from the iPhone.
                TabView(selection: $model.horizontalIndex) {
                    liveStack
                        .tag(0)
                    ForEach(Array(model.gatewaySessions.enumerated()), id: \.element.id) { idx, gatewaySession in
                        GatewaySessionPage(model: model, session: gatewaySession)
                            .tag(idx + 1)
                    }
                }
            } else {
                WatchNotPairedView()
            }
        }
        .onAppear {
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
