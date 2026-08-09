<p align="center">
  <img src="https://raw.githubusercontent.com/mycellm/mycellm/main/docs/assets/mycellm-red-logo.svg" width="80" alt="mycellm">
</p>

<h1 align="center">mycellm_ iOS</h1>

<p align="center">
  <strong>iOS &amp; iPadOS app for the mycellm network.</strong><br>
  <em>An M-series iPad Pro is a desktop-lite powerhouse — 3B+ models at 30+ tokens/sec on Metal. Runs on iPhone too.</em>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6761091607">
    <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" height="48">
  </a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License"></a>
  <a href="https://developer.apple.com/swift/"><img src="https://img.shields.io/badge/swift-6.0-orange.svg" alt="Swift"></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/iOS%20%26%20iPadOS-17.0+-black.svg" alt="iOS & iPadOS"></a>
  <a href="https://mycellm.ai"><img src="https://img.shields.io/badge/website-mycellm.ai-spore" alt="Website"></a>
</p>

<p align="center">
  <a href="https://mycellm.ai">Website</a> ·
  <a href="https://docs.mycellm.dev">Docs</a> ·
  <a href="https://github.com/mycellm/mycellm">CLI / Server</a>
</p>

---

<p align="center">
  <img src="screenshots/ipad-chat-network.png" alt="mycellm iPad — network chat with node attribution and spore particle background" width="100%">
</p>

## What is this?

The mycellm iOS app turns your iPad into a full peer on the [mycellm](https://github.com/mycellm/mycellm) distributed inference network — serve inference to the network, earn credits, and chat with privacy protection. An iPad Pro with an M-series chip runs 3B+ models at 30+ tokens/sec on Metal. Also works on iPhone.

- **On-device inference** — llama.cpp and MLX (mlx-swift-lm) on Metal, streaming tokens with thermal throttling
- **Multimodal (vision)** — load a vision-language model (Qwen2.5-VL) to serve and chat with images; attach a photo in the chat composer
- **Network + local routing** — toggle per message, automatic fallback if network fails
- **Sensitive Data Guard** — prompts are scanned on-device for PII; sensitive queries route to your local model automatically
- **Chat persistence** — threaded conversations with metadata (model, node, tokens/sec, route). Export, share, and private ephemeral sessions.
- **Credit economy** — earn credits by seeding, spend them consuming. Consumer co-signed receipts settle to the network's tracker (the source of truth, reconciled on-device); no blockchain.
- **OpenAI-compatible API** — your device serves `/v1/chat/completions` on your LAN for other tools

<p align="center">
  <img src="screenshots/iphone-chat-ondevice.png" alt="mycellm iPhone — on-device inference with Llama 3.2 3B on Metal" width="300">
</p>

## Requirements

- iOS 17.0+
- Xcode 16.0+
- Swift 6.0
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for project generation)

## Building

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Open in Xcode
open Mycellm.xcodeproj
```

Select your device or simulator and build (⌘B). SPM dependencies (SwiftCBOR, Hummingbird, llama.swift, mlx-swift-lm, swift-transformers) resolve automatically.

**Headless / CI builds need two flags:**

```bash
xcodebuild -project Mycellm.xcodeproj -scheme Mycellm \
  -destination "generic/platform=iOS Simulator" \
  -skipPackagePluginValidation -skipMacroValidation build
```

Without them the build fails at `Validate plug-in "CudaBuild" in package
"mlx-swift"` — a package **plugin-trust** prompt that Xcode raises interactively
and that has no answer on a machine with no one sitting at it. The failure is
easy to misread: it reports three failed build commands and prints no `error:`
line anywhere, so it looks like a broken source tree rather than a consent
dialog nobody can click. In Xcode.app the prompt appears once and is remembered;
over SSH it never appears at all.

### Configuration

The project uses XcodeGen (`project.yml`) for reproducible project generation. Key settings:

| Setting | Value |
|---------|-------|
| Bundle ID | `com.mycellm.app` |
| Deployment Target | iOS 17.0 |
| Swift Version | 6.0 (strict concurrency) |
| Device Families | iPhone + iPad |

> **Note:** Set your own `DEVELOPMENT_TEAM` in `project.yml` before building.

## Architecture

```
Mycellm/
├── Core/
│   ├── Identity/      Ed25519 keypairs, device certs, Keychain storage
│   ├── Transport/     QUIC via NWConnection, TLS, peer management
│   ├── Protocol/      CBOR message envelopes, 20 message types
│   ├── Network/       NodeService facade, bootstrap client, fleet handler
│   ├── API/           Hummingbird HTTP server, OpenAI-compatible routes
│   ├── Inference/     llama.cpp + MLX (mlx-swift-lm / MLXVLM) engines, model lifecycle, thermal throttle
│   ├── Accounting/    Credit ledger, co-signed receipts, tracker reconcile
│   ├── NAT/           STUN discovery, UDP hole punching
│   ├── Privacy/       Sensitive data guard (PII/credential scanning)
│   └── Storage/       SwiftData models, UserDefaults preferences
├── Views/
│   ├── Dashboard/     Node KPIs, activity feed
│   ├── Chat/          Streaming chat with routing + node attribution
│   ├── Models/        Model browser, HuggingFace search, load/unload
│   ├── Peers/         Connected peers, network membership
│   ├── Settings/      Identity, privacy, remote endpoints, tip jar
│   └── Components/    Splash screen, screensaver
└── Utilities/         CBOR coding, compression, hardware info
```

<p align="center">
  <img src="screenshots/ipad-dashboard.png" alt="mycellm dashboard — inference count, credit balance, QUIC connection, activity feed" width="49%">
  <img src="screenshots/ipad-models.png" alt="mycellm models — Llama 3.2 loaded, HuggingFace suggested downloads" width="49%">
</p>

### Design Principles

- **Actor isolation** — `InferenceEngine`, `BootstrapClient`, `CreditLedger` are actors for thread safety
- **Observable state** — `NodeService` and `ModelManager` use `@Observable` for reactive UI
- **Service facade** — Views interact with `NodeService`, not internal subsystems
- **Dark mode only** — Void Black (#0A0A0A) background, JetBrains Mono typography
- **Protocol compatible** — CBOR message format matches the Python daemon exactly

### API Endpoints Served

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/v1/models` | List loaded models |
| POST | `/v1/chat/completions` | Chat (streaming + non-streaming) |
| GET | `/v1/node/status` | Node status |
| GET | `/v1/node/system` | Hardware info |

## Built with AI

This project was developed in collaboration with [Claude Code](https://claude.ai/code) by Anthropic. Claude served as a pair-programming partner throughout architecture design, implementation, and testing. All technical decisions, project direction, and code review are my own.

## Credits

Built by [Michael Gifford-Santos](https://github.com/mijkal).

- **AI pair programming**: [Claude Code](https://claude.ai/code) by Anthropic
- **Inference**: [llama.swift](https://github.com/mattt/llama.swift) by Mattt · [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) by Apple
- **Design references**: streaming stop-sequence holdback and tool-call recovery inspired by [oMLX](https://github.com/jundot/omlx); verified downloads inspired by [turbo-fieldfare](https://github.com/drumih/turbo-fieldfare) — see the main repo's [NOTICE](https://github.com/mycellm/mycellm/blob/main/NOTICE)
- **HTTP server**: [Hummingbird](https://github.com/hummingbird-project/hummingbird)
- **Serialization**: [SwiftCBOR](https://github.com/valpackett/SwiftCBOR)
- **Typography**: [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono)

## License

Apache 2.0 — see [LICENSE](LICENSE).

"mycellm" and the mycellm logo are trademarks of Michael Gifford-Santos.
See [TRADEMARK.md](TRADEMARK.md) for usage guidelines.

---

<p align="center">
  <sub>mycellm_ — /my·SELL·em/ — mycelium + LLM</sub>
</p>
