# Changelog

Notable changes to the mycellm iOS & iPadOS app. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Two versions matter here and they move independently: the **app version**
(App Store marketing version, below) and the **core parity version** — the
version of the Python [mycellm](https://github.com/mycellm/mycellm) core whose
protocol and API surface this build matches. A release can bump one without the
other.

## [1.2.0] — 2026-08-14 · build 22 · core parity 0.6.3

**Leaf-node API parity, plus the two things real hardware exposed.** A dashboard
or fleet tool pointed at an iOS node now manages it the same way it manages a
Linux one — 26 routes became 43. The gaps weren't inert: a dead cancel button,
blank dashboard tabs, and a node permanently misreported as pre-0.5.1. Testing
against an actual iPad then turned up two more, neither of which the simulator
could have shown.

### Fixed

- **Models are excluded from iCloud backup at the directory level.** Finished
  GGUF downloads, published MLX directories and imported files each set
  `isExcludedFromBackup` on what they produced — which covered finished models
  and nothing else. `.staging/` was not covered, so a backup running during a
  download uploaded gigabytes of partial weights; nor were models side-loaded
  through the Files app, which the app enables file sharing specifically to
  support. These live in Documents, which iOS backs up by default, so the cost
  was a user's iCloud quota filled with weights they can re-download in minutes
  — and it is what the iOS Data Storage Guidelines exist to stop, so also an
  App Store review risk. The `models/` directory is now excluded, covering the
  whole subtree including paths this code never touches.
- **A management key is minted on first launch.** A deliberate divergence from
  the Python node, which leaves `api_key` empty for the operator to set: iOS has
  no env, no config file and no shell, so "loopback only" there means the
  management surface can never be reached by anything. The gate is still
  possession of the key. The fleet key is pointedly *not* auto-generated — that
  one enrols the device in remote management by a network admin, which is the
  owner's decision to make.
- **Network view showed no peers, ever.** The Peers section was hardcoded to
  `count: 0` with an unconditional "No connected peers" — it never consulted the
  peer list, so a device with peers attached still reported none. It reads live
  data now, and the empty state explains that reaching the network through the
  bootstrap is normal rather than a fault to hunt for.
- **Settings → Privacy Guard → Rules showed two disclosure chevrons.**
  `NavigationLink` draws its own; the label added another.

### Changed

- **Network view opens with a "This Device" card** — serving or not, *why* not
  in terms that say what to do about it (node stopped, no model loaded, too
  hot, Low Power Mode, battery under 20%), and the LAN address the local API is
  reachable on. The reasons are the same conditions the node uses to demote
  itself in its capability advertisement, so the screen and the network cannot
  disagree.
- **Settings → Network section removed** — it was a pointer to the Network tab
  and nothing else.
- **Privacy Policy and Terms moved into About** as tappable rows. In the footer
  they read as fine print under the logo rather than as things you can open.

### Fixed

- **The node management API can actually be unlocked.** `NodeAuth` reads a
  device key from `api_key` and, when empty, serves `/v1/node/**` to loopback
  only — everything else gets 403. No screen ever wrote that key, so from 1.1.0
  onward the management surface was unreachable from any other machine,
  permanently. The lock behaved exactly as designed; there was simply no key.
  Settings → **Local API Server** now has an **API Key** field and a **Generate
  Key** button (160-bit CSPRNG). Found only by pointing the parity surface at a
  real iPad and discovering nothing could authenticate — every simulator test
  passed because loopback bypasses the check.
- **Model downloads no longer run over cellular unasked.** Both paths built
  their requests from defaults that permit cellular, expensive and constrained
  access, so a 4 GB MLX repo would pull over LTE — and over Low Data Mode —
  with nothing in the way. `Connectivity` had known the path was metered the
  whole time; it was wired only to dimming a label. Downloads are now refused on
  metered paths by default. See **Downloads** below.
- **The dashboard's download-cancel button works against an iOS node.** Cancel
  was served at `POST /v1/node/models/download/cancel`; every other node and
  client uses `POST /v1/node/models/downloads/abort`, so the button 404'd and
  the download carried on. The Python spelling is canonical now, returning
  `{"status": "aborted"}` and 404 for an unknown `download_id`. The old path
  stays as a deprecated alias — it shipped in build 18.
- **iOS nodes report their version.** `/v1/node/status` omitted `version`, and
  `menubar/state.py` reads its absence as "older than 0.5.1" — so every iOS node
  was misreported, permanently. Status now carries `version` (core parity) and
  `app_version`, plus the rest of the Python contract: `uptime_seconds`, `role`,
  `mode`, `tps`, `hardware`, `credits`, `peers`, `models`, `inference`, `nat`.
  The original eight keys are unchanged.
- **`/v1/embeddings` is routed instead of 404-ing.** The path was listed public
  in `NodeAuth` but no route was ever registered.
- **Failed completions are recorded**, so `total_errors`, `errors_5min` and the
  error sparkline can read something other than zero.
- **GGUF embedding models are recognised as such.** The shared tag heuristic
  keyed on the substring "embed", catching `nomic-embed-text` but missing
  `all-MiniLM-L6-v2`, `bge-small-en`, `gte-base`, `multilingual-e5-large` —
  every family actually shipped as GGUF for the job. The same list went into the
  Python core so both sides agree.

### Added — Downloads

- **Metered-network policy.** Off by default; Settings → **Downloads** → *Allow
  on Cellular* grants standing permission. `POST /v1/node/models/download`
  answers **409 `expensive_network`** with `network`, `estimated_bytes` and a
  message; `allow_expensive: true` overrides per request. MLX refusals happen
  *after* planning so the caller gets the real size — the number is the whole
  point of refusing out loud.

  A confirmation dialog would not have worked: this is an API, and the caller is
  the dashboard, a fleet tool or a script, with nobody at the device to tap
  anything. The policy is enforced per-*request* rather than per-session because
  the two download paths don't share a session — `MLXRepo` uses
  `URLSession.shared`, whose configuration cannot be mutated.

### Added — Device telemetry

- **`device` block on `/v1/node/status`** — `thermal` (state, `throttled`,
  `unloading`), `power` (battery %, charging, Low Power Mode), `network`
  (interface, `expensive`, `constrained`), `runtime` (app state,
  `serving_requires_foreground`). These are the facts a Linux node doesn't have
  and a phone lives by; without them a scheduler routes to iOS nodes on hardware
  specs alone.
- **`storage` on `/v1/node/system`** — free bytes on the models volume, using
  `ForImportantUsage` so a caller planning a download gets the honest figure.
- **The node demotes itself.** `role` is no longer "has a model loaded": a
  device that is thermally critical, in Low Power Mode, or under 20% on battery
  advertises `consumer` instead of `seeder` — in `/v1/node/status` *and* in the
  capability advertisement peers see. Self-protecting, and it needs no agreement
  from any scheduler in the fleet.
- `expensive` and `constrained` are reported separately. They were previously
  OR'd into one flag, which threw away the difference between "this costs money"
  and "the user asked the system to go easy".

### Added — Parity surface

- **Activity API** — `GET /v1/node/activity` (recent events, rolling stats,
  sparklines) and `GET /v1/node/activity/stream` (SSE). Event payloads are
  Python's flat `{type, timestamp, time, …}` shape with the same snake_case type
  vocabulary, so the dashboard's activity feed renders identically.
- **Logs API** — `GET /v1/node/logs` and `GET /v1/node/logs/stream` (SSE).
- **Prometheus metrics** — `GET /metrics` (public, as in Python), emitting the
  `mycellm_*` series a device can honestly measure: uptime, inference requests
  and tokens, models loaded, credits, peers connected, hardware. Series a device
  has no source for (fleet registry, seeder census, admission control) are
  absent rather than reported as zero.
- **Topology** — `GET /v1/node/peers` and `GET /v1/node/connections`.
- **`GET /v1/node/version`** — core version, app version and build, plus an App
  Store update check (the iOS counterpart to Python's PyPI check). Offline or
  timed out, it still reports the local versions.
- **Model management completed** — `GET /v1/node/models/{name}/config` (API keys
  masked to a last-four hint), `POST /v1/node/models/update`,
  `POST /v1/node/models/reload`, `POST /v1/node/models/load-status/clear`, and
  `GET /v1/node/models/search/{repo}/files`, which lists a repo's installable
  variants with disk/RAM warnings computed against *this* device — so a picker
  can grey out a model that won't fit before a multi-gigabyte download starts.
- **`GET /v1/node/credits/networks`** — per-network authoritative balances,
  served from the tracker-reconciled cache rather than re-querying the tracker
  on every dashboard poll.
- **`GET /v1/models/{id}`** — OpenAI single-model retrieve, 404 for unknown ids.


### Known issues

- **On-device embedding execution is disabled** (`LlamaCppBackend.embeddingsEnabled`).
  The path is implemented and runs — an encoder pass returns 384 finite floats
  per input at the correct dimension with a unit L2 norm — but the values are
  not usable embeddings. On all-MiniLM-L6-v2 Q4_K_M, three inputs (two
  near-identical sentences about a cat, one about financial regulation) came
  back collinear with sign flips: cos(cat,kitten) = **-0.999**,
  cos(kitten,finance) = **+0.955**. Per-sequence mean pooling is not producing
  independent results for a multi-sequence batch. Because every value looks
  plausible in isolation, shipping it would fill a caller's vector store with
  confident garbage and surface no error, so the execution path is gated off and
  `/v1/embeddings` answers `embeddings_not_supported` — the same response the
  Python node gives for a backend that cannot embed.

  Two real bugs were found and fixed on the way here and are worth not
  rediscovering: llama.cpp's `n_ctx` is the budget across *all* sequences and is
  divided by `n_seq_max`, so sizing it to a token total starves each sequence
  and llama.cpp responds by calling `abort()`; and creating/destroying an
  embedding context per request corrupts the heap ("Incorrect checksum for freed
  object") — the context is now created once per model and cleared between
  calls, which is what llama.cpp's own embedding example does. Re-enabling means
  establishing how llama.cpp wants a pooled multi-sequence batch submitted for
  an encoder-only model, with the similarity check above as the acceptance test.

### Notes

Deliberately **not** served on iOS: `/v1/admin/**`, `/v1/public/**`,
`/v1/node/federation/**`, `/v1/node/settings/**`, `/v1/node/proxy` and the
Ollama-compatible `/api/**` surface. These are coordinator/tracker roles or
credential surfaces that don't belong on a device — see the README for the
reasoning on each.

### Not done

- **Downloads still don't survive backgrounding.** iOS suspends the app within
  ~30s and the transfer dies. `URLSessionConfiguration.background` is the fix,
  but it is a larger change than it looks: the GGUF path could adopt it, while
  the MLX path fetches many shards over `URLSession.shared` and cannot the same
  way. Half of it would give "downloads survive backgrounding — except MLX ones,
  sometimes", which is worse than the current honest limitation. Its own build.

## [1.1.0] — build 18 · core parity 0.6.3

- Node-parity hardening: stop filter, download verification, tool-truncation
  recovery, bounded KV cache.
- Model downloads over the node API (MLX repos and GGUF files).
- Node management API requires a key; the fleet key is deliberately not accepted
  on HTTP.
- Join-key support, revealable secure fields, port-crash fixes.
- Tip jar; core-version parity display.
