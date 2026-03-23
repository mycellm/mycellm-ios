import SwiftUI

struct SettingsView: View {
    @Environment(NodeService.self) private var node
    @State private var preferences = Preferences.shared
    @State private var showingExportKey = false
    @State private var showingScreenSaver = false

    var body: some View {
        NavigationStack {
            List {
                // Identity
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

                // Node
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

                // Network
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

                // Privacy Guard
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

                // Remote Endpoint (for Network chat)
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

                // API
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

                // Display
                Section("Display") {
                    Toggle("Keep Awake While Running", isOn: Binding(
                        get: { preferences.keepAwake },
                        set: { preferences.keepAwake = $0 }
                    ))
                    .font(.mono(13))
                }

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

                // Storage
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

                // Telemetry
                Section("Telemetry") {
                    Toggle("Send Anonymous Usage Data", isOn: Binding(
                        get: { preferences.telemetryEnabled },
                        set: { preferences.telemetryEnabled = $0 }
                    ))
                    .font(.mono(13))
                }

                // About
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

                // Footer
                Section {
                    VStack(spacing: 16) {
                        HStack(spacing: 16) {
                            Link("Privacy Policy", destination: URL(string: "https://mycellm.ai/privacy/")!)
                                .font(.mono(12))
                                .foregroundStyle(Color.relayBlue)
                            Text("|")
                                .font(.mono(12))
                                .foregroundStyle(Color.consoleDim)
                            Link("Terms of Service", destination: URL(string: "https://mycellm.ai/terms/")!)
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

    private var availableStorageDescription: String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        ), let freeSize = attrs[.systemFreeSize] as? Int64 else {
            return "Unknown"
        }
        return ByteCountFormatter.string(fromByteCount: freeSize, countStyle: .file)
    }
}
