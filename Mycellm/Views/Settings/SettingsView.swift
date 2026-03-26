import SwiftUI
import StoreKit

struct SettingsView: View {
    @Environment(NodeService.self) private var node
    @State private var preferences = Preferences.shared
    @State private var showingExportKey = false
    @State private var showingScreenSaver = false
    @State private var tipJar = TipJarManager()

    var body: some View {
        NavigationStack {
            List {
                identitySection
                nodeSection
                networkSection
                privacyGuardSection
                remoteEndpointSection
                localAPISection
                displaySection
                screensaverSection
                storageSection
                telemetrySection
                tipJarSection
                aboutSection
                footerSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.voidBlack)
            .navigationTitle("Settings")
            .font(.mono(13))
            .fullScreenCover(isPresented: $showingScreenSaver) {
                ScreenSaverView {
                    showingScreenSaver = false
                }
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
                            .font(.system(size: 12))
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

    // MARK: - Network

    private var networkSection: some View {
        Section("Network") {
            LabeledContent("Bootstrap") {
                Text(preferences.bootstrapHost)
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("Mode") {
                Text(node.networkMode.displayName)
                    .font(.mono(12))
                    .foregroundStyle(Color.relayBlue)
            }
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
                LabeledContent("Rules") {
                    Text("\(SensitiveDataGuard.builtinRules.count) built-in")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
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
                SecureField("optional", text: Binding(
                    get: { preferences.remoteApiKey },
                    set: { preferences.remoteApiKey = $0 }
                ))
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Model")
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleDim)
                TextField("auto", text: Binding(
                    get: { preferences.remoteModel },
                    set: { preferences.remoteModel = $0 }
                ))
                .font(.mono(12))
                .foregroundStyle(Color.consoleText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: - Local API

    private var localAPISection: some View {
        Section("Local API Server") {
            Toggle("HTTP Server", isOn: Binding(
                get: { preferences.httpServerEnabled },
                set: { preferences.httpServerEnabled = $0 }
            ))
            .font(.mono(13))

            if preferences.httpServerEnabled {
                LabeledContent("Port") {
                    Text(verbatim: "\(preferences.apiPort)")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                }
                Text("Local HTTP server exposes an OpenAI-compatible API on this device.")
                    .font(.mono(10))
                    .foregroundStyle(Color.consoleDim)
            }
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
                showingScreenSaver = true
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

            if preferences.screenSaverEnabled {
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
            }
        }
    }

    // MARK: - Storage

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
        Section(header: Text("Buy Me a Coffee"), footer: Text("mycellm is free and open source. Tips help support continued development.").font(.mono(10))) {
            tipJarContent
        }
        .task { await tipJar.loadProducts() }
    }

    @ViewBuilder
    private var tipJarContent: some View {
        if tipJar.isLoading {
            tipJarLoading
        } else if tipJar.products.isEmpty {
            tipJarPlaceholders
        } else {
            tipJarProducts
        }
        tipJarStatus
    }

    private var tipJarLoading: some View {
        HStack {
            Spacer()
            ProgressView().tint(Color.sporeGreen)
            Spacer()
        }
    }

    private var tipJarPlaceholders: some View {
        ForEach(TipJarManager.tipTiers, id: \.id) { tier in
            HStack {
                Text(tier.emoji)
                Text(tier.label)
                    .font(.mono(13))
                    .foregroundStyle(Color.consoleText)
                Spacer()
                Text("—")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
        }
    }

    private var tipJarProducts: some View {
        ForEach(tipJar.products, id: \.id) { product in
            TipJarRow(product: product, tipJar: tipJar)
        }
    }

    @ViewBuilder
    private var tipJarStatus: some View {
        if case .success = tipJar.purchaseState {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Color.computeRed)
                Text("Thank you for your support!")
                    .font(.mono(12))
                    .foregroundStyle(Color.sporeGreen)
            }
        }
        if case .failed(let msg) = tipJar.purchaseState {
            Text(msg)
                .font(.mono(10))
                .foregroundStyle(Color.computeRed)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App") {
                Text("1.0.0 (1)")
                    .font(.mono(12))
                    .foregroundStyle(Color.consoleDim)
            }
            LabeledContent("mycellm Core") {
                Text("0.1.0")
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
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        Section {
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Link("Privacy Policy", destination: URL(string: NetworkConfig.privacyURL)!)
                        .font(.mono(12))
                        .foregroundStyle(Color.relayBlue)
                    Text("|")
                        .font(.mono(12))
                        .foregroundStyle(Color.consoleDim)
                    Link("Terms of Service", destination: URL(string: NetworkConfig.termsURL)!)
                        .font(.mono(12))
                        .foregroundStyle(Color.relayBlue)
                }

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

// MARK: - Tip Jar Row

private struct TipJarRow: View {
    let product: Product
    let tipJar: TipJarManager

    var body: some View {
        Button {
            Task { await tipJar.purchase(product) }
        } label: {
            label
        }
        .disabled(tipJar.purchaseState.isPurchasing)
    }

    private var label: some View {
        HStack {
            Text(tipJar.emoji(for: product.id))
            Text(tipJar.label(for: product.id))
                .font(.mono(13))
                .foregroundStyle(Color.consoleText)
            Spacer()
            Text(product.displayPrice)
                .font(.mono(12, weight: .medium))
                .foregroundStyle(Color.sporeGreen)
        }
    }
}
