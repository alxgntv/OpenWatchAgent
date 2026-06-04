import SwiftUI
import UIKit

/// Copyable instructions for adding agents on the OpenClaw gateway host when the iPhone lacks `operator.admin`.
enum AddAgentServerGuide {
    static let instructionsText = """
    Add agents on your OpenClaw gateway server

    In-app "Add agent" needs operator.admin on this iPhone. Most pairings only get operator.read and operator.write, so add agents on the server instead.

    Option A — CLI (recommended)

    1. SSH into the machine that runs your gateway.
    2. From your OpenClaw install directory, run:

    docker compose run --rm openclaw-cli agents add "Nutritionist" \\
      --non-interactive \\
      --workspace /home/node/.openclaw/workspace \\
      --model openai/gpt-5.5

    Replace Nutritionist with your agent name. The gateway derives the agent id from the name (e.g. nutritionist). Use the same workspace path your other agents use.

    Option B — edit openclaw.json

    Add a new object under agents.list (same shape as your existing agents: id, name, identity, model, workspace). Restart the gateway process/container.

    After adding on the server

    • Open OpenWatch on iPhone and pull to refresh on the home screen.
    • The new agent appears in its own section (Main Actor stays first).

    Optional — enable in-app creation later

    On the gateway, approve this iPhone with operator.admin scope, then Disconnect gateway in OpenWatch and pair again.
    """
}

/// Sheet shown when the phone cannot call agents.create (no operator.admin).
struct AddAgentServerGuideSheet: View {
    @Binding var isPresented: Bool
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(AddAgentServerGuide.instructionsText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Add Agent on Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        AppLog.info("Add agent server guide dismissed")
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") {
                        UIPasteboard.general.string = AddAgentServerGuide.instructionsText
                        didCopy = true
                        AppLog.info("Add agent server guide copied to pasteboard")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if didCopy {
                    Text("Copied to clipboard")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
        }
    }
}
