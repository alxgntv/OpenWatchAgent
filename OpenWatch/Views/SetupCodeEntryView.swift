import SwiftUI

struct SetupCodeEntryView: View {
    @ObservedObject var model: AppModel
    @State private var setupCode = ""
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect OpenClaw")
                    .font(.largeTitle.bold())

                Text("Paste a fresh setup code, then tap Connect once. After reinstalling the app you need a new code (each install is a new device to the gateway).")
                    .font(.body)
                    .foregroundStyle(.secondary)

                TextField("Setup code", text: $setupCode, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3 ... 8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)

                if let banner = model.errorBanner {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    model.submitSetupCode(setupCode)
                } label: {
                    HStack {
                        if model.pairing.phase == .connecting {
                            ProgressView()
                        }
                        Text(model.pairing.phase == .connecting ? "Connecting…" : "Connect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pairing.phase == .connecting)
            }
            .padding()
        }
        .navigationTitle("Pairing")
        .onAppear {
            focused = true
            AppLog.info("SetupCodeEntryView appeared")
        }
    }
}
