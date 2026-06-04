import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel.shared

    var body: some View {
        NavigationStack {
            root
        }
        .onAppear {
            AppLog.info("OpenWatch iPhone root phase=\(model.pairing.phase.rawValue)")
        }
    }

    @ViewBuilder
    private var root: some View {
        switch model.pairing.phase {
        case .needsSetupCode, .failed:
            SetupCodeEntryView(model: model)
        case .waitingForApproval:
            PendingApprovalView(model: model)
        case .connecting:
            VStack(spacing: 16) {
                ProgressView()
                Text(model.pairing.message ?? "Connecting…")
            }
            .padding()
            .navigationTitle("OpenWatch")
        case .connected:
            HomeView(model: model)
        }
    }
}

#Preview {
    ContentView()
}
