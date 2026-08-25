import SwiftUI

/// The queue, as seen from a phone.
///
/// ⚠️ THE WAITING REASON IS THE POINT OF THIS SCREEN. A row that says "queued"
/// tells the user nothing the absence of an answer did not already tell them.
/// "No frontier-tier model is reachable — 3 smaller models online" tells them
/// to go wake the Mac Studio. A queue that cannot explain itself is
/// indistinguishable from a hang.
struct QueueView: View {
    @Environment(\.dismiss) private var dismiss

    let selection: ModelSelection
    /// Prefilled when opened from an unanswerable chat message, so "queue this
    /// instead" is one tap rather than retyping.
    let initialPrompt: String

    @State private var client = QueueClient()
    @State private var snapshot = QueueClient.Snapshot()
    @State private var prompt = ""
    @State private var error = ""
    @State private var disabled = false
    @State private var submitting = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if disabled {
                    unavailable
                } else {
                    content
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
                }
            }
        }
        .onAppear {
            prompt = initialPrompt
            startPolling()
        }
        .onDisappear { refreshTask?.cancel() }
    }

    // MARK: - Pieces

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 32))
                .foregroundStyle(Color.consoleDim)
            // "Not enabled" and "unreachable" send someone down completely
            // different paths, so never collapse them into one message.
            Text("This node doesn't have the job queue enabled.")
                .font(.mono(13))
                .foregroundStyle(Color.consoleText)
                .multilineTextAlignment(.center)
            Text("Queued work needs mycellm 0.8 or later with MYCELLM_QUEUE_ENABLED.")
                .font(.mono(10))
                .foregroundStyle(Color.consoleDim)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var content: some View {
        List {
            Section {
                TextField("What should the fleet work on?", text: $prompt, axis: .vertical)
                    .font(.mono(13))
                    .lineLimit(2...5)
                HStack {
                    Text(selection.label)
                        .font(.mono(10))
                        .foregroundStyle(Color.relayBlue)
                    Spacer()
                    Button(submitting ? "Queueing…" : "Queue it") { submit() }
                        .font(.mono(13))
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || submitting)
                }
            } header: {
                Text("Submit").font(.mono(10))
            } footer: {
                Text("Jobs run when a node is free and fit — an iPad on the charger tonight, a Mac that wakes in the morning. Nothing is lost if this app closes.")
                    .font(.mono(10))
            }

            if !snapshot.schedulerReason.isEmpty {
                Section {
                    Label(snapshot.schedulerReason, systemImage: "clock")
                        .font(.mono(11))
                        .foregroundStyle(Color.ledgerGold)
                }
            }

            if !error.isEmpty {
                Section {
                    Text(error).font(.mono(11)).foregroundStyle(Color.computeRed)
                }
            }

            Section {
                if snapshot.jobs.isEmpty {
                    Text("Nothing queued.")
                        .font(.mono(11))
                        .foregroundStyle(Color.consoleDim)
                }
                ForEach(snapshot.jobs) { job in
                    row(job)
                }
            } header: {
                Text(countsLabel).font(.mono(10))
            }
        }
        .refreshable { await refresh() }
    }

    private func row(_ job: QueueClient.Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(job.state.uppercased())
                    .font(.mono(9))
                    .foregroundStyle(color(for: job.state))
                if !job.minTier.isEmpty {
                    Text("≥ \(job.minTier)").font(.mono(9)).foregroundStyle(Color.consoleDim)
                }
                if !job.model.isEmpty {
                    Text(job.model).font(.mono(9)).foregroundStyle(Color.consoleDim)
                }
                Spacer()
                if !job.isTerminal {
                    Button {
                        cancel(job.id)
                    } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.consoleDim)
                }
            }
            Text(job.prompt)
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .lineLimit(2)

            if !job.waitingReason.isEmpty && job.state == "queued" {
                Text(job.waitingReason)
                    .font(.mono(10))
                    .foregroundStyle(Color.ledgerGold)
            }
            if !job.error.isEmpty {
                Text(job.error).font(.mono(10)).foregroundStyle(Color.computeRed)
            }
            if job.state == "done" {
                Text(job.resultText)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleText)
                    .lineLimit(6)
                if !job.servedModel.isEmpty || !job.servedBy.isEmpty {
                    // Same attribution rule as a chat reply: a queued job may
                    // run hours later on a different machine than the one that
                    // would have taken it at submit time, so who answered is
                    // not derivable after the fact.
                    Text(job.servedBy.isEmpty
                         ? job.servedModel
                         : "\(job.servedModel) · node:\(String(job.servedBy.prefix(8)))")
                        .font(.mono(9))
                        .foregroundStyle(Color.poisonPurple)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var countsLabel: String {
        guard !snapshot.counts.isEmpty else { return "Jobs" }
        return snapshot.counts
            .sorted { $0.key < $1.key }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: " · ")
    }

    private func color(for state: String) -> Color {
        switch state {
        case "running", "done": return .sporeGreen
        case "queued":          return .ledgerGold
        case "failed":          return .computeRed
        default:                return .consoleDim
        }
    }

    // MARK: - Actions

    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                // 5s while the sheet is open only. The queue's whole promise
                // is that you do not have to watch it.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func configure() async {
        await client.configure(
            endpoint: Preferences.shared.remoteEndpoint,
            apiKey: Preferences.shared.remoteApiKey
        )
    }

    private func refresh() async {
        await configure()
        do {
            snapshot = try await client.list()
            error = ""
            disabled = false
        } catch is QueueClient.Disabled {
            disabled = true
        } catch {
            self.error = "\(error)"
        }
    }

    private func submit() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        submitting = true
        Task {
            defer { submitting = false }
            await configure()
            do {
                _ = try await client.submit(prompt: text, selection: selection)
                prompt = ""
                await refresh()
            } catch is QueueClient.Disabled {
                disabled = true
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func cancel(_ id: String) {
        Task {
            await configure()
            do { try await client.cancel(id) } catch { self.error = "\(error)" }
            await refresh()
        }
    }
}
