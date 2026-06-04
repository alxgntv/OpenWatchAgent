import SwiftUI

struct ContentView: View {
    @StateObject private var model = WatchAppModel.shared

    var body: some View {
        NavigationStack {
            if model.isPaired {
                TabView(selection: $model.currentIndex) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { idx, session in
                        WatchSessionPage(model: model, session: session, index: idx)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.verticalPage)
            } else {
                WatchNotPairedView()
            }
        }
        .onAppear {
            WatchConnectivityWatchService.shared.requestSync()
            AppLog.info("OpenWatch Watch app launched")
        }
    }
}

#Preview {
    ContentView()
}
