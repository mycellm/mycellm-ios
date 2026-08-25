import SwiftUI
import StoreKit
import SafariServices

struct SettingsView: View {
    @Environment(NodeService.self) private var node
    @Environment(\.showScreenSaver) private var showScreenSaver
    @State private var preferences = Preferences.shared
    @State private var showingExportKey = false
    @State private var showingTipJar = false
    @State private var safariURL: URL?
    @State private var tipJar = TipJarManager()
    @State private var copiedKey = false

    var body: some View {
        NavigationStack {
            List {
                identitySection
                nodeSection
                chatSection
                if AppDatabase.syncFeatureEnabled { chatSyncSection }
                privacyGuardSection
                remoteEndpointSection
                localAPISection
                downloadsSection
                appIconSection
                displaySection
                screensaverSection
                storageSection
                telemetrySection
                aboutSection
                tipJarSection
                footerSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Settings")
            .font(.mono(13))
            .sheet(item: $safariURL) { url in
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("Peer ID") {
                HStack {
                    Text(String(node.peerId.prefix(16)) + "…")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleText)
                    Button {
                        UIPasteboard.general.string = node.peerId
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 14))
                    }
                }
            }

            if let dk = node.deviceKey {
                LabeledContent("Public Key") {
                    Text(String(dk.publicHex.prefix(16)) + "…")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }
            }

            if let cert = node.deviceCert {
                LabeledContent("Certificate") {
                    Text(cert.deviceName)
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleText)
                }
                LabeledContent("Role") {
                    Text(cert.role)
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
        }
    }

    // MARK: - Node

    private var nodeSection: some View {
        Section("Node") {
            LabeledContent("Name") {
                Text(node.nodeName)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleText)
            }
            LabeledContent("API Port") {
                Text(verbatim: "\(preferences.apiPort)")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("QUIC Port") {
                Text(verbatim: "\(preferences.quicPort)")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        Section(header: Text("Chat"), footer: Text("When Show Reasoning is off (default), thinking-model output is stripped at the server so the chat only shows the answer. Turn on to see the model's step-by-step reasoning in a collapsible panel above each response.").font(.mono(10))) {
            Toggle("Render Markdown", isOn: Binding(
                get: { preferences.chatRenderMarkdown },
                set: { preferences.chatRenderMarkdown = $0 }
            ))
            .font(.mono(13))
            Toggle("Show Reasoning", isOn: Binding(
                get: { preferences.chatShowReasoning },
                set: { preferences.chatShowReasoning = $0 }
            ))
            .font(.mono(13))
        }
    }

    // MARK: - Privacy Guard

    private var privacyGuardSection: some View {
        Section(header: Text("Privacy Guard"), footer: Text("Scans outgoing messages for sensitive data (API keys, passwords, PII) and routes to trusted/local nodes.").font(.mono(10))) {
            Toggle("Sensitive Data Detection", isOn: Binding(
                get: { preferences.sensitiveGuardEnabled },
                set: { preferences.sensitiveGuardEnabled = $0 }
            ))
            .font(.mono(13))

            if preferences.sensitiveGuardEnabled {
                NavigationLink {
                    RulesView()
                } label: {
                    // ⚠️ NO MANUAL CHEVRON HERE. NavigationLink draws its own
                    // disclosure indicator, so adding one to the label rendered
                    // the row with two — "10 built-in › ›".
                    LabeledContent("Rules") {
                        Text("\(SensitiveDataGuard.builtinRules.count) built-in")
                            .font(.mono(12))
                            .foregroundStyle(Color.consoleDim)
                    }
                }
                LabeledContent("Public Network") {
                    Text("Block + redirect")
                        .font(.mono(12))
                        .foregroundStyle(Color.sporeGreen)
                }
                LabeledContent("Private Network") {
                    Text("Warn on high")
                        .font(.mono(12))
                        .foregroundStyle(Color.ledgerGold)
                }
            }
        }
    }

    // MARK: - Remote Endpoint

    private var remoteEndpointSection: some View {
        Section(header: Text("Remote Endpoint"), footer: Text("OpenAI-compatible API for Network chat mode. Works with mycellm nodes, OpenRouter, ollama, etc.").font(.mono(10))) {
            HStack {
                Text("URL")
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleDim)
                TextField("https://…", text: Binding(
                    get: { preferences.remoteEndpoint },
                    set: { preferences.remoteEndpoint = $0 }
                ))
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("API Key")
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleDim)
                RevealableSecureField("optional", text: Binding(
                    get: { preferences.remoteApiKey },
                    set: { preferences.remoteApiKey = $0 }
                ))
            }
            // ⚠️ NOT A TEXT FIELD ANY MORE. It used to ask for a model's exact
            // name, which meant in practice nobody set it and every network
            // chat went out as "default". A picker also makes the tier floor
            // reachable at all — it has been implemented server-side since 0.8
            // and had no way in from this app.
            RemoteModelPicker(preferences: preferences)
        }
    }

    // MARK: - Local API

    private var localAPISection: some View {
        Section(
            header: Text("Local API Server"),
            footer: Text("Inference and discovery (/v1/chat/completions, /v1/models, /health, /metrics) are always open on the LAN. Management (/v1/node/…) needs the key below — without one it works only from this device, so the dashboard and fleet tools can't reach it. This key is device-level and grants the full management surface; for narrow cross-node control (status, load/unload/scope) set a Fleet Key on a network instead — Network tab → the network → Fleet Key.").font(.mono(10))
        ) {
            Toggle("HTTP Server", isOn: Binding(
                get: { preferences.httpServerEnabled },
                set: { preferences.httpServerEnabled = $0 }
            ))
            .font(.mono(13))

            // ⚠️ NOT GATED ON THE TOGGLE ABOVE, FOR TWO REASONS.
            //
            // The toggle is not the only thing that starts the server —
            // `networkMode.apiServerEnabled` does too, so a node can be serving
            // on the LAN while this reads off. Hiding the key behind it hid the
            // key in exactly the case where someone needed it: a reachable node
            // they cannot authenticate against.
            //
            // And the gate did not even work. `Preferences` is @Observable, but
            // `httpServerEnabled` is a computed property over UserDefaults —
            // the macro instruments stored properties only, so flipping the
            // toggle wrote the value and invalidated nothing. The rows stayed
            // hidden until some unrelated change rebuilt the view.
            Group {
                LabeledContent("Port") {
                    Text(verbatim: "\(preferences.apiPort)")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }

                // ⚠️ WITHOUT THIS FIELD THE MANAGEMENT API IS UNREACHABLE, FULL
                // STOP. NodeAuth reads `api_key` from UserDefaults and, when it
                // is empty, serves /v1/node/** to loopback only — everything
                // else gets 403. Nothing else in the app ever wrote that key,
                // so from 1.1.0 until now no iOS node could be managed from the
                // dashboard or any fleet tool, on any network, ever. The lock
                // was working exactly as designed; there was simply no key.
                HStack {
                    Text("API Key").font(.mono(13)).foregroundStyle(Color.consoleDim)
                    RevealableSecureField("not set", text: Binding(
                        get: { preferences.apiKey },
                        set: { preferences.apiKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ))
                    .accessibilityIdentifier("settings.nodeApiKey")

                    // ⚠️ A GENERATED KEY YOU CANNOT COPY IS A KEY YOU CANNOT
                    // USE. The whole point of minting one automatically is that
                    // the management API works out of the box — but the client
                    // that needs it runs somewhere else, so the key has to
                    // leave the device. Retyping 40 hex characters off a phone
                    // screen is not a workflow. Same copy affordance the Peer ID
                    // row already uses.
                    Button {
                        UIPasteboard.general.string = preferences.apiKey
                        copiedKey = true
                    } label: {
                        Image(systemName: copiedKey ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(copiedKey ? Color.sporeGreen : Color.consoleDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(preferences.apiKey.isEmpty)
                    .accessibilityIdentifier("settings.copyApiKey")
                    .accessibilityLabel("Copy API key")
                }

                Button {
                    preferences.apiKey = Preferences.generateAPIKey()
                    copiedKey = false
                } label: {
                    Text(preferences.apiKey.isEmpty ? "Generate Key" : "Regenerate Key")
                        .font(.mono(12))
                        .foregroundStyle(Color.sporeGreen)
                }
                .accessibilityIdentifier("settings.generateApiKey")

                Text("Local HTTP server exposes an OpenAI-compatible API on this device.")
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
            }
        }
    }

    // MARK: - App Icon

    private var appIconSection: some View {
        Section(
            header: Text("App Icon"),
            footer: Text("Changes the icon on your home screen. Red is the default.")
                .font(.mono(10))
        ) {
            AppIconPicker()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section("Display") {
            Toggle("Keep Awake While Running", isOn: Binding(
                get: { preferences.keepAwake },
                set: { preferences.keepAwake = $0 }
            ))
            .font(.mono(13))
        }
    }

    // MARK: - Screensaver

    private var screensaverSection: some View {
        Section(header: Text("Screensaver"), footer: Text("Prevents burn-in on OLED displays. Activates automatically after the configured idle time when Keep Awake is enabled.").font(.mono(10))) {
            Button {
                showScreenSaver.wrappedValue = true
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.poisonPurple)
                    Text("Preview Screensaver")
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                }
            }

            Toggle("Auto-Start with Keep Awake", isOn: Binding(
                get: { preferences.screenSaverEnabled },
                set: { preferences.screenSaverEnabled = $0 }
            ))
            .font(.mono(13))

            Picker("Activate After", selection: Binding(
                get: { preferences.screenSaverDelay },
                set: { preferences.screenSaverDelay = $0 }
            )) {
                Text("1 min").tag(1)
                Text("2 min").tag(2)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
            }
            .font(.mono(13))
            .disabled(!preferences.screenSaverEnabled)
            .foregroundStyle(preferences.screenSaverEnabled ? Color.consoleText : Color.consoleDim)

            Toggle("Show Logo", isOn: Binding(
                get: { preferences.screenSaverShowLogo },
                set: { preferences.screenSaverShowLogo = $0 }
            ))
            .font(.mono(13))

            Toggle("Show Host / IP", isOn: Binding(
                get: { preferences.screenSaverShowHostInfo },
                set: { preferences.screenSaverShowHostInfo = $0 }
            ))
            .font(.mono(13))

            Toggle("Show Time", isOn: Binding(
                get: { preferences.screenSaverShowTime },
                set: { preferences.screenSaverShowTime = $0 }
            ))
            .font(.mono(13))

            Toggle("Show Network Stats", isOn: Binding(
                get: { preferences.screenSaverShowStats },
                set: { preferences.screenSaverShowStats = $0 }
            ))
            .font(.mono(13))
        }
    }

    // MARK: - Storage

    private var chatSyncSection: some View {
        Section(
            header: Text("Chat Sync"),
            footer: Text("Syncs conversations to your private iCloud, shared across your devices signed into the same Apple ID. Off by default — chats can contain the credentials and personal data the Privacy Guard exists to catch, so this is opt-in. Models and activity never sync. Turning it off stops future syncing but does not remove what iCloud already holds; delete conversations first if that is what you want.").font(.mono(10))
        ) {
            Toggle("Sync to iCloud", isOn: Binding(
                get: { preferences.chatSyncEnabled },
                set: { preferences.chatSyncEnabled = $0 }
            ))
            .font(.mono(13))
            .accessibilityIdentifier("settings.chatSync")

            // A toggle whose effect is invisible until relaunch looks broken.
            // Say so, but only while it is actually true.
            if let active = AppDatabase.activeSyncSetting, active != preferences.chatSyncEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text(preferences.chatSyncEnabled
                         ? "Sync starts the next time the app launches."
                         : "Sync stops the next time the app launches.")
                        .font(.mono(10))
                }
                .foregroundStyle(Color.ledgerGold)
            }
        }
    }

    private var downloadsSection: some View {
        Section(
            header: Text("Downloads"),
            footer: Text("Models run to several gigabytes. When off, downloads are refused on cellular and in Low Data Mode — the API answers 409 expensive_network with the size, so a caller can retry with allow_expensive. Wi-Fi is unaffected.").font(.mono(10))
        ) {
            Toggle("Allow on Cellular", isOn: Binding(
                get: { preferences.allowExpensiveDownloads },
                set: { preferences.allowExpensiveDownloads = $0 }
            ))
            .font(.mono(13))
            .accessibilityIdentifier("settings.allowExpensiveDownloads")
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Models Directory") {
                Text(ModelManager.modelsDirectory.lastPathComponent)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("Available Space") {
                Text(availableStorageDescription)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
        }
    }

    // MARK: - Telemetry

    private var telemetrySection: some View {
        Section("Telemetry") {
            Toggle("Send Anonymous Usage Data", isOn: Binding(
                get: { preferences.telemetryEnabled },
                set: { preferences.telemetryEnabled = $0 }
            ))
            .font(.mono(13))
        }
    }

    // MARK: - Tip Jar

    private var tipJarSection: some View {
        Section {
            Button {
                showingTipJar = true
            } label: {
                HStack {
                    Text("☕")
                    Text("Buy Me a Coffee")
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                    Spacer()
                    if case .success = tipJar.purchaseState {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Color.computeRed)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
        }
        .task { await tipJar.loadProducts() }
        .sheet(isPresented: $showingTipJar) {
            TipJarSheet(tipJar: tipJar)
                .presentationDetents([.medium])
                // ⚠️ The section's own .task already fetches on Settings appear;
                // this is the belt to that braces. `loadProducts` guards on
                // `products.isEmpty`, so the second call is free — and without it
                // a sheet opened before the first fetch returns shows the tiers
                // with "—" where the prices belong, which looks broken rather
                // than pending.
                .task { await tipJar.loadProducts() }
        }
    }

    // MARK: - About

    /// Real marketing version + build from the bundle (was hardcoded "1.0.0 (1)",
    /// which lied on every build incl. production).
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App") {
                Text(appVersionString)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("mycellm Core") {
                Text(NetworkConfig.version)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("Protocol") {
                Text("v\(protocolVersion)")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("Platform") {
                Text("iOS — Metal")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }

            // Moved out of the footer: these are reference links, which is what
            // an About section is for. In the footer they read as fine print
            // under the logo rather than as things you can tap.
            Button {
                safariURL = URL(string: NetworkConfig.privacyURL)
            } label: {
                HStack {
                    Text("Privacy Policy")
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            Button {
                safariURL = URL(string: NetworkConfig.termsURL)
            } label: {
                HStack {
                    Text("Terms of Service")
                        .font(.mono(13))
                        .foregroundStyle(Color.consoleText)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.consoleDim)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        Section {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Image("MycellmLogo-red")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)

                    Text("Mycellm")
                        .font(.mono(13, weight: .semibold))
                        .foregroundStyle(Color.consoleText)
                    Text("\u{00A9} 2026 Michael Gifford-Santos")
                        .font(.mono(11))
                        .foregroundStyle(Color.consoleDim)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Helpers

    private var availableStorageDescription: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ), let freeSize = attrs[.systemFreeSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: freeSize, countStyle: .file)
    }
}

// MARK: - Tip Jar Sheet

private struct TipJarSheet: View {
    let tipJar: TipJarManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(footer: Text("mycellm is free and open source. Tips help support continued development.").font(.mono(10))) {
                    if tipJar.isLoading {
                        HStack { Spacer(); ProgressView().tint(Color.sporeGreen); Spacer() }
                    } else if tipJar.products.isEmpty {
                        ForEach(TipJarManager.tipTiers, id: \.id) { tier in
                            HStack {
                                Text(tier.emoji)
                                Text(tier.label).font(.mono(13)).foregroundStyle(Color.consoleText)
                                Spacer()
                                Text("—").font(.mono(12)).foregroundStyle(Color.consoleDim)
                            }
                        }
                    } else {
                        ForEach(tipJar.products, id: \.id) { product in
                            Button {
                                Task { await tipJar.purchase(product) }
                            } label: {
                                HStack {
                                    Text(tipJar.emoji(for: product.id))
                                    Text(tipJar.label(for: product.id))
                                        .font(.mono(13))
                                        .foregroundStyle(Color.consoleText)
                                    Spacer()
                                    // ⚠️ THE TAP HAD NO VISIBLE EFFECT. StoreKit takes a
                                    // second or two to raise Apple's payment sheet, and in
                                    // that gap the only feedback was the row quietly
                                    // disabling — which reads as "the button is broken",
                                    // not as "it is working". The spinner replaces the
                                    // price on the row that was actually tapped, so the
                                    // feedback is where the finger is.
                                    if tipJar.purchasingProductId == product.id {
                                        ProgressView()
                                            .controlSize(.small)
                                            .tint(Color.sporeGreen)
                                    } else {
                                        Text(product.displayPrice)
                                            .font(.mono(12, weight: .medium))
                                            .foregroundStyle(Color.sporeGreen)
                                    }
                                }
                            }
                            .disabled(tipJar.purchaseState.isPurchasing)
                        }
                    }

                    if tipJar.purchaseState.isPurchasing {
                        Text("Contacting the App Store…")
                            .font(.mono(10))
                            .foregroundStyle(Color.consoleDim)
                    }
                    if case .success = tipJar.purchaseState {
                        HStack {
                            Image(systemName: "heart.fill").foregroundStyle(Color.computeRed)
                            Text("Thank you for your support!")
                                .font(.mono(12)).foregroundStyle(Color.sporeGreen)
                        }
                    }
                    if case .failed(let msg) = tipJar.purchaseState {
                        Text(msg).font(.mono(10)).foregroundStyle(Color.computeRed)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Buy Me a Coffee")
            .navigationBarTitleDisplayMode(.inline)
            .font(.mono(13))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.font(.mono(13))
                }
            }
        }
    }
}

// MARK: - In-App Safari

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.preferredControlTintColor = UIColor(Color.sporeGreen)
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
