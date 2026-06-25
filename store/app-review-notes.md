# mycellm — App Review notes (paste into App Store Connect → App Review Information → Notes)

Thank you for reviewing mycellm.

WHAT THE APP IS
mycellm runs open large language models (LLMs) for private chat. It is not a
single cloud service — it is a node in a distributed, peer-to-peer inference
network. No account, login, or personal information is required to use it.

HOW TO TEST (no download or account needed)
1. Launch the app. On first launch it opens to the Chat tab in "Network" mode,
   already connected to our public bootstrap — you can send a message and get a
   reply without downloading anything.
2. To test fully on-device: open the Models tab, download any listed model,
   then switch the Chat toggle to "On-Device". Inference then runs entirely on
   the device with no network use (airplane mode works).
3. The Dashboard, Models, and Network tabs show node status, available models,
   and credits.

WHICH MODELS ARE AVAILABLE (important context)
Users choose how to run inference, and that choice determines which models are
available:
• On-Device — only models the user has downloaded to their device run; output
  is generated locally.
• Public Network — the user borrows compute from the public peer-to-peer swarm;
  the available models are whatever nodes in that swarm currently serve.
• Private / Fleet Network — the user (or their organization) runs their own
  swarm with its own models, trust, and credit rules.
Because models come from the user's own device or from peer nodes the user
chooses to connect to, the exact model list is not fixed by us — it varies with
the swarm parameters the user selects. mycellm is the client/runtime, not a
content provider.

CONTENT & SAFETY (Guideline 1.2)
• Models are open, user-selected, and run on the user's own or chosen hardware —
  mycellm does not host or curate model output.
• A persistent AI disclaimer is shown in chat ("AI responses may be inaccurate.
  Verify important information.").
• Privacy Guard scans prompts on-device for sensitive data before anything
  leaves the device on a network.
• There is no public feed, social layer, or user-to-user content sharing — chat
  is between the user and the model only.

PRIVACY
• No account and no analytics/tracking SDKs. Identity is a cryptographic key
  stored only in the device Keychain.
• On-Device mode is fully offline. In Network mode, prompts are relayed to peer
  nodes to fulfill the request; this is described in the privacy policy.
• Privacy Policy: https://mycellm.dev/privacy · Terms: https://mycellm.dev/terms

PERMISSIONS & CAPABILITIES
• Local Network (Bonjour `_mycellm._tcp/_udp`) — to discover and connect to
  nearby nodes for peer-to-peer inference (NSLocalNetworkUsageDescription
  provided). Specific Bonjour service types are used; the multicast entitlement
  is intentionally not requested.
• Increased Memory Limit entitlement
  (`com.apple.developer.kernel.increased-memory-limit`) — required to load
  multi-GB models into unified memory on capable devices. Without it the app
  cannot load larger on-device models.
• Photo access uses the system PhotosPicker (for vision-capable models); no
  photo-library permission prompt is required.

Happy to answer any questions — thanks again.
