import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchAppModel.shared
    @State private var horizontalPage = 2
    @State private var mainAgentId = "main"
    @State private var agentSelection: String?
    private let jobWatchdogTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    // ─── Ariadne's Thread [AT-0103] ─────────────────────
    // What: Keep top-level TabView page selection as local SwiftUI state.
    // Why:  Apple TabView(selection:) owns page navigation; routing page changes through ObservableObject reducer crashes watchOS paging.
    // Date: 2026-06-08
    // Related: [AT-0099] WatchAppModel.reduce, [AT-0098] WatchShellState
    // ─────────────────────────────────────────────────────
    private var horizontalSelection: Binding<Int> {
        Binding(
            get: { horizontalPage },
            set: {
                horizontalPage = $0
                AppLog.info("Watch horizontal page selection changed page=\($0)")
            }
        )
    }

    var body: some View {
        NavigationStack {
            if model.isPaired {
                // Outer axis = HORIZONTAL (default watchOS paging): page 0 is the live stack (unchanged),
                // swiping left/right reveals the other top-level pages.
                // Horizontal order: Usage · Agents · live stack (main) · all gateway sessions (single vertical list page).
                TabView(selection: horizontalSelection) {
                    UsagePage(model: model)
                        .tag(0)
                    AgentsPage(model: model, selection: $agentSelection)
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
            horizontalPage = 2
            mainAgentId = model.mainAgentIdForUI
            agentSelection = mainAgentId
            WatchConnectivityWatchService.shared.logStep2IPhoneConnect(reason: "app-launched")
            WatchConnectivityWatchService.shared.requestAgentNavigationModel(knownAgentIds: model.knownGatewayAgentIdsForSync)
            AppLog.info("OpenWatch Watch app launched")
        }
        .onChange(of: agentSelection) { _, agentId in
            guard let agentId, agentId != mainAgentId else { return }
            mainAgentId = agentId
            model.setMainAgentIdForNextRecording(agentId)
            horizontalPage = 2
            AppLog.info("Watch selected agent through List selection agentId=\(agentId)")
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
