# mycellm — App Store Copy

App Store Connect listing copy for **Mycellm — Run LLMs**. Bundle:
`com.mycellm.app` • App ID: `6761091607`.

This doc is the source of truth for what gets pasted into ASC. Update here
first, then mirror into App Store Connect. Avoid drift between this file
and what's actually live.

## Listing fields

### Name (30 char limit) — currently set

```
Mycellm — Run LLMs
```

### Subtitle (30 char limit)

```
Private on-device chat AI
```

Alternates if Apple objects to "on-device":
- `Run LLMs on your iPad`
- `Distributed AI for everyone`
- `Bring your own GPU`

### Promotional Text (170 char) — bumpable without re-review

```
Chat with open-source AI models that run on YOUR device, not in someone else's cloud. Your iPad becomes the AI. Your home network becomes the inference cluster.
```

(ASC rejects emojis in promotional text. Save the 🍄 for marketing-site copy where it's allowed.)

### Keywords (100 char total, comma-separated)

```
llm,ai,chat,local,offline,private,gpu,llama,mistral,qwen,assistant,distributed
```

Notes: dropped "openai" / "claude" / "chatgpt" — Apple often rejects
keyword-stuffing competitor brand names. Kept open-model family names
(llama, mistral, qwen) which are descriptive of capability.

### Support URL

```
https://github.com/mycellm/mycellm-ios/issues
```

(`mycellm.ai/support` doesn't exist yet. GitHub Issues is the actual
support channel for an Apache-2.0 OSS app and Apple accepts that.)

### Marketing URL

```
https://mycellm.ai
```

### Privacy Policy URL

```
https://mycellm.ai/privacy
```

### Copyright

```
2026 Michael Gifford-Santos. Apache-2.0 License.
```

### Category

- Primary: **Developer Tools**
- Secondary: **Productivity**

Rationale: this is a power-user tool. "AI" category is crowded with
ChatGPT clones; Developer Tools positions it correctly for the audience
that'll actually appreciate self-hosted inference.

---

## Description (4000 char limit)

```
Mycellm turns your iPad or iPhone into a node in your own AI network. Run open-source language models on your own hardware, chat with them privately, and connect them into a swarm with other devices on your network — no accounts, no telemetry, no rented GPUs.

WHY MYCELLM

When you chat with ChatGPT or Claude, your prompts leave your network. They live on someone else's server, get logged, get used for training, get subpoena-able. Mycellm is the opposite shape: the model runs on YOUR Apple Silicon, your conversations never touch a cloud, and even when you do route a request to another mycellm node it's between machines you trust.

HOW IT WORKS

• **On-Device mode**: download a model from the curated library (Llama 3.2, Qwen 3, Mistral Small, more), tap to load, chat. Inference happens on your iPad's Neural Engine via llama.cpp and MLX. No internet required.

• **Network mode**: when your local hardware can't fit the model you want, mycellm relays your prompt to other nodes — your own homelab Mac, a friend's server, or a public bootstrap that aggregates idle compute. You stay in control of which nodes are trusted.

• **Privacy Guard**: scans outgoing prompts for sensitive data (API keys, passwords, PII) before they leave your device, with rules you control.

WHAT'S INCLUDED

• Chat UI with streaming responses, reasoning panel for thinking models, tool/function calling
• Auto-load models on launch, pinned favorites, search the Hugging Face MLX-community catalog
• Distributed mode: your iPad can serve other apps on your LAN via OpenAI-compatible API
• Cross-network: connect to mycellm.ai's public network for community-contributed compute
• Built-in node dashboard: live token rate, peer count, memory pressure
• No accounts. No login screens. No telemetry. Open-source under Apache 2.0.

SUPPORTED MODELS

Anything in GGUF (llama.cpp) or MLX (mlx-community/) format. We curate a starter set: Qwen 3 1.7B / Coder 30B, Llama 3.2 3B, Mistral 7B. Bring your own by importing a folder via Files.

WHO IT'S FOR

• Developers building with local LLMs who want their iPad to be a node
• Privacy-minded chat users who don't want a cloud account
• Apple Silicon owners with VRAM to spare wanting to give it to the network
• Anyone curious about distributed inference

NOT FOR

• Users who want the most-capable model regardless of where it runs — GPT-5 / Claude Opus still outperform on hard tasks. Mycellm is about ownership, not benchmark wins.
• Users who don't want any setup — you'll choose a model, watch it download, and live with the constraints of your device's VRAM.

TIP JAR

Like the project? Optional one-time tips support development at Coffee ($0.99) through Party ($24.99). No subscription, no nagging — there's a single section in Settings. We'd rather have your goodwill than your monthly card billing.

OPEN SOURCE

Built on Apache 2.0 code at github.com/mycellm/mycellm-ios. Python core at github.com/mycellm/mycellm. Issues + contributions welcome.
```

---

## What's New (For each release)

### v0.3.0 (initial App Store submission)

```
Initial release.

• Network + On-Device chat modes
• Streaming responses with reasoning panel for thinking models (Qwen 3 hybrid, DeepSeek-R1, GLM-4 Thinking)
• OpenAI-compatible tool/function calling support (server-side)
• Privacy Guard scans for sensitive data before requests leave your device
• Local model library — Qwen 3, Llama 3.2, Mistral, more — via Hugging Face catalog
• MLX backend for Apple Silicon (faster than llama.cpp Metal path on Apple chips)
• Distributed mode: your iPad serves other apps on your LAN via OpenAI-compatible API
• Optional tip jar with no subscriptions
```

---

## App Privacy (App Store Connect Privacy Questionnaire)

For the "App Privacy" section ASC requires before submission:

| Data Type | Collected | Linked to User | Used for Tracking |
|---|---|---|---|
| Crash data | Yes | No | No |
| Performance data (TPS, latency) | Yes | No | No |
| User content (chat) | **No** | No | No |
| Identifiers (Device ID) | **No** | No | No |
| Contact info | **No** | No | No |
| Location | **No** | No | No |
| Diagnostics | Yes | No | No |

Key answer: **mycellm does not collect chat content, user identifiers, or
location data**. Crash and performance telemetry can be sent (optional,
off by default in Settings → Telemetry).

Privacy Policy URL: https://mycellm.ai/privacy — must exist before
submission (currently empty in ASC, see TODO below).

---

## IAP (In-App Purchase) Configuration

5 consumable tip-jar products. Reference name + product ID + price tier:

| Reference Name | Product ID | Price Tier | Display Name | Description |
|---|---|---|---|---|
| Tip - Coffee | `com.mycellm.tip.small` | Tier 1 ($0.99) | Coffee ☕ | Buy us a coffee. Keeps the lights on. |
| Tip - Matcha | `com.mycellm.tip.medium` | Tier 3 ($2.99) | Matcha 🍵 | Mid-tier love. Funds a model download. |
| Tip - Pizza | `com.mycellm.tip.large` | Tier 5 ($4.99) | Pizza 🍕 | Real support. Powers an afternoon of coding. |
| Tip - Bento | `com.mycellm.tip.generous` | Tier 10 ($9.99) | Bento 🍱 | Generous patronage. A full feature sponsored. |
| Tip - Party | `com.mycellm.tip.huge` | Tier 25 ($24.99) | Party 🎉 | The kind of support that pays the cloud bill. |

Localized display names + descriptions for each — see column above.

Review screenshot for each IAP: take a screenshot of the Settings → Tip
Jar section with the relevant tier highlighted. Apple wants to see what
the user actually purchases.

---

## Screenshots Plan (matches `.maestro/` flows)

| # | Filename | Caption | Source flow |
|---|---|---|---|
| 1 | `01-network-chat.png` | Chat with frontier-class models — no account required | network-chat |
| 2 | `02-on-device-chat.png` | On-device inference on Apple Silicon | on-device-chat |
| 3 | `03-models-library.png` | Browse + download from the curated MLX catalog | models-tour |
| 4 | `04-dashboard.png` | Watch your node serve the network in real time | dashboard-tour |
| 5 | `05-settings-privacy.png` | Privacy Guard scans before prompts leave your device | settings-tour |
| 6 | `06-settings-reasoning.png` | Optional "Show Reasoning" toggle for thinking models | settings-tour |
| 7 | `07-tipjar.png` | Like the work? Tip optional. No subscriptions. | settings-tour |

iPad and iPhone get the same 7-screen set, differently composed for
aspect ratio.

---

## Pre-submission TODO (your-side ASC work)

- [ ] Sign Paid Apps Agreement (Banking + Tax info) — required for ANY IAP including the tip jar
- [ ] Set subtitle to "Private on-device chat AI" (currently empty in ASC)
- [ ] Set primary category: Developer Tools
- [ ] Set secondary category: Productivity
- [ ] Set Privacy Policy URL: https://mycellm.ai/privacy
- [ ] Set Support URL: https://mycellm.ai/support
- [ ] Set Marketing URL: https://mycellm.ai
- [ ] Create 5 consumable IAPs per table above
- [ ] Upload 7 iPad screenshots (1290×2796 or 2048×2732 depending on iPad model — iPad A16 native is 2048×2732)
- [ ] Upload 7 iPhone 6.9" screenshots (1320×2868 for 17 Pro Max)
- [ ] Fill App Privacy section per table above
- [ ] Add reviewer test instructions: how to load a model + use Network mode against api.mycellm.dev
- [ ] Add demo account (if Apple asks) — N/A, no accounts in the app

## Pre-submission TODO (this repo)

- [ ] Capture 7 marketing screenshots per device via `.maestro/capture-all.sh`
- [ ] Verify TipJar UI loads StoreKit products against a local .storekit config (sandbox)
- [ ] Verify Privacy Policy page exists at https://mycellm.ai/privacy
- [ ] Verify Support page exists at https://mycellm.ai/support (currently 404?)
- [ ] Build a signed Archive on a Mac with the upload keystore + provisioning profile
