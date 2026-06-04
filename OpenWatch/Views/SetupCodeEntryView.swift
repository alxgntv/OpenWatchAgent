import SwiftUI

struct SetupCodeEntryView: View {
    @ObservedObject var model: AppModel
    @State private var gatewayURL = ""
    @State private var setupCode = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case gateway
        case setupCode
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Connect OpenClaw")
                    .font(.largeTitle.bold())

                Text("Each gateway lives on its own server. Enter that server's address and a fresh setup code from `openclaw qr --setup-code-only` on that machine.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Gateway address")
                        .font(.subheadline.weight(.semibold))
                    TextField("wss://your-server:18789", text: $gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .gateway)
                    Text("Examples: wss://myhost.example.com:18789 · 192.168.1.10:18789 · tailnet-host:18789")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup code")
                        .font(.subheadline.weight(.semibold))
                    TextField("Paste full setup code or bootstrap token", text: $setupCode, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3 ... 8)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .setupCode)
                    Text("Full code from openclaw qr includes the URL — you can leave Gateway address empty. Or paste only the bootstrap token and fill Gateway address above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let banner = model.errorBanner {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    AppLog.info(
                        "SetupCodeEntry Connect tapped gatewayFieldEmpty=\(gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"
                    )
                    model.submitPairing(gatewayURL: gatewayURL, setupCode: setupCode)
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
        .onAppear {
            if gatewayURL.isEmpty, let last = SetupCodeDecoder.loadLastGatewayURL() {
                gatewayURL = last
                AppLog.info("SetupCodeEntryView prefilled last gateway host from defaults")
            }
            focusedField = gatewayURL.isEmpty ? .gateway : .setupCode
            AppLog.info("SetupCodeEntryView appeared")
        }
    }

    private var canConnect: Bool {
        let code = setupCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, model.pairing.phase != .connecting else { return false }
        let url = gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty { return true }
        return looksLikeFullSetupCode(code)
    }

    /// Heuristic: full openclaw setup codes are base64-ish and longer than a bare token.
    private func looksLikeFullSetupCode(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
