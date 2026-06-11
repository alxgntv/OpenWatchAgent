import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchAppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    private let jobWatchdogTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            if model.isPaired {
                // Outer axis = HORIZONTAL (default watchOS paging): page 0 is the live stack (unchanged),
                // swiping left/right reveals the other top-level pages.
                // Horizontal order: Usage · Agents · live stack (main) · all gateway sessions (single vertical list page).
                TabView(selection: $model.horizontalIndex) {
                    UsagePage(model: model)
                        .tag(0)
                    AgentsPage(model: model)
                        .tag(1)
                    liveStack
                        .tag(2)
                    GatewaySessionsListPage(model: model)
                        .tag(3)
                }
            } else {
                WatchNotPairedView(model: model)
            }
        }
        .onAppear {
            FlowLog.started(step: 1, side: .watch, flow: "main-screen")
            FlowLog.function(step: 1, side: .watch, flow: "main-screen", name: "ContentView.onAppear")
            // Always open on the main (live) screen.
            model.horizontalIndex = 2
            WatchConnectivityWatchService.shared.logStep2IPhoneConnect(reason: "app-launched")
            AppLog.info("OpenWatch Watch app launched")
            model.deliverLaunchFeedbackIfNeeded()
            model.refreshComplicationPresentation()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                model.refreshComplicationPresentation()
            }
            if newPhase == .background {
                model.resetLaunchFeedbackSession()
            } else if newPhase == .active, oldPhase == .background {
                AppLog.info("OpenWatch Watch scene became active from background")
                model.deliverLaunchFeedbackIfNeeded()
            }
        }
        .onReceive(jobWatchdogTimer) { _ in
            model.tickJobStatusWatchdog()
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
