import SwiftUI

struct SetupCodeEntryView: View {
    @ObservedObject var model: AppModel
    @State private var setupCode = ""
    @FocusState private var setupCodeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect OpenClaw")
                    .font(.largeTitle.bold())

                Text("Paste a setup code from `openclaw qr --setup-code-only` on your gateway server, or from `/pair` in Telegram.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup code")
                        .font(.subheadline.weight(.semibold))
                    TextField("Paste setup code", text: $setupCode, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3 ... 8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($setupCodeFocused)
                    Text("The setup code includes your gateway address and pairing token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let banner = model.errorBanner {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    AppLog.info("SetupCodeEntry Connect tapped setupCodeLength=\(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).count)")
                    setupCodeFocused = false
                    model.submitPairing(setupCode: setupCode)
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
                .disabled(!canConnect)
            }
            .padding()
        }
        .navigationTitle("Pairing")
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    AppLog.info("SetupCodeEntry keyboard dismissed")
                    setupCodeFocused = false
                }
            }
        }
        .onAppear {
            setupCodeFocused = true
            AppLog.info("SetupCodeEntryView appeared")
        }
    }

    private var canConnect: Bool {
        !setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.pairing.phase != .connecting
    }
}
