import SwiftUI

struct PendingApprovalView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "hourglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Finishing setup")
                    .font(.title2.bold())

                if let message = model.pairing.message {
                    Text(message)
                        .font(.body)
                }

                if model.pairing.phase == .connecting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("This usually takes a few seconds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let url = model.pairing.gatewayURL {
                    Text(url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Use a different gateway", role: .destructive) {
                    AppLog.info("PendingApprovalView: user chose different gateway (disconnect)")
                    model.disconnect()
                }
            }
            .padding()
        }
        .navigationTitle("Approval")
        .onAppear {
            AppLog.info("PendingApprovalView appeared; auto-polling approval")
            model.recheckApproval()
        }
    }
}
