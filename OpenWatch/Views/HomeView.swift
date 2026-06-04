import SwiftUI

struct HomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Connected")
                            .font(.headline)
                        if let url = model.pairing.gatewayURL {
                            Text(url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            Section("Voice on iPhone") {
                Button {
                    model.toggleListenOnPhone()
                } label: {
                    Label(
                        activeJob?.status == .listening ? "Tap to send" : "Tap to listen",
                        systemImage: activeJob?.status == .listening ? "paperplane.fill" : "mic.fill"
                    )
                }

                if let job = activeJob, job.status == .listening || job.status == .sending || job.status == .running {
                    HStack {
                        ProgressView()
                        Text(job.statusDetail ?? job.status.rawValue.capitalized)
                    }
                }
            }

            Section("Session") {
                Button {
                    model.startNewSession()
                } label: {
                    Label("New session", systemImage: "plus.bubble")
                }
            }

            Section("Recent jobs") {
                if model.jobs.isEmpty {
                    Text("Use your Apple Watch or tap Listen above.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(job: job)
                        } label: {
                            JobRowView(job: job)
                        }
                    }
                }
            }

            Section {
                Button("Disconnect gateway", role: .destructive) {
                    model.disconnect()
                }
            }
        }
        .navigationTitle("OpenWatch")
        .onAppear { AppLog.info("HomeView appeared jobs=\(model.jobs.count)") }
    }

    private var activeJob: VoiceJob? {
        guard let id = model.activeJobId else { return nil }
        return model.jobs.first { $0.id == id }
    }
}

struct JobRowView: View {
    let job: VoiceJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.transcript ?? job.statusDetail ?? job.status.rawValue.capitalized)
                .lineLimit(2)
            Text(job.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct JobDetailView: View {
    let job: VoiceJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let transcript = job.transcript {
                    Group {
                        Text("You said")
                            .font(.caption.bold())
                        Text(transcript)
                    }
                }
                if let result = job.resultText {
                    Group {
                        Text("Response")
                            .font(.caption.bold())
                        Text(result)
                    }
                }
                if let error = job.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Job")
    }
}
