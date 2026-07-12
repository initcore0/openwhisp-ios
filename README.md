# OpenWhisp for iOS

Local-first dictation for iPhone and iPad — a custom keyboard that dictates
anywhere, backed by on-device Whisper in the host app. **Nothing leaves your
phone**; sync with the [OpenWhisp macOS app](https://github.com/initcore0/openwhisp)
is peer-to-peer over your own Wi-Fi.

> Your Mac's dictation, now in your pocket — same private engine, no cloud,
> no subscription, no keylogger keyboard.

## Status

**P2P sync (WP6) — pairing, TLS-PSK transport, SyncEngine.** On top of the WP5
dictation handoff, the phone now syncs its vocabulary, history, profiles, and
modes with a paired Mac over the LAN — the Agent Bridge wire (NDJSON JSON-RPC)
carried over a TLS-PSK `NWConnection` instead of the Mac's UNIX socket. Nothing
leaves the two devices: QR-paired out of band, a 32-byte pre-shared key in the
Keychain, mutual-PSK TLS, no CA. Settings → **Your Mac** pairs a Mac (camera QR
scan), shows the paired-device card (last synced, Sync Now, Unpair), and
auto-syncs on app-foreground (fail-silent, logged to a sync journal). The merge
is deliberately boring and fully tested: vocabulary union by id (newer
`updatedAt` wins), history append-only union by id, profiles/modes
last-writer-wins — idempotent, so a converged re-sync moves nothing.

What's in place for sync:

- **`SyncCore`** (pure, in the `swift test` gate) — `PeerIdentity`,
  `PairingPayload` (QR parse/validate + PSK fingerprint), the manifest/plan/report
  models, `SyncPlanner.plan`, and the `SyncMerge` policy functions.
- **`SyncKit`** (OS-bound) — `KeychainSecretStore`, `DefaultPairingService`
  (pair → Keychain + peer store; unpair = key destruction), `BonjourPeerTransport`
  (`NWBrowser` + TLS-PSK `NWConnection` → a `BridgeSession` conformer speaking
  NDJSON), and `SyncEngine.run` applying to the app's real JSON stores.
- **Tests** — the merge/planner matrix + idempotency and QR parse (Tier 1); the
  engine end-to-end against an in-process fake peer, a hermetic real-TLS-PSK
  handshake loopback, Keychain CRUD, and an env-gated integration test against the
  Mac loopback harness (Tier 3b, self-skips); plus an XCUITest for the Your Mac
  section + pairing sheet fallback.

Previously — **dictation handoff (WP5) — floor flow end-to-end + hero surfaces.**
On top of the WP3 host app (on-device composer + engine layer) and the WP1
scaffold, dictation flows from the app to the keyboard through the App Group.

What's in place:

- **`Packages/OpenWhispMobileKit`** — the shared SwiftPM package. `MobileCore`
  and `KeyboardCore` are Foundation-only and unit-tested (the `swift test`
  gate); `CaptureKit` holds the OS-bound engine + capture conformers. The pure
  handoff/flow logic (`CaptureFlow`, `DeepLink`, `DictationActivityState`,
  `AppGroupHandoffStore`, `MicKeyResolver`, `TranscriptInsertPolicy`) is
  implemented and tested.
- **Floor flow (ARCHITECTURE §5.2)** — the host registers the `openwhisp://` URL
  scheme; `openwhisp://dictate` presents a compact **dictation sheet** that
  captures, publishes the cleaned transcript to the App Group, pings the keyboard
  (`DarwinHandoffNotifier`), and mirrors the coarse capture state for the mic key.
  The composer's "Dictate for another app" button takes the same path.
- **Hero surfaces (ARCHITECTURE §5.1)** — `StartDictationIntent`
  (`AudioRecordingIntent`) / `StopDictationIntent`, the "Listening…" Live Activity
  + Dynamic Island, and a Control Center control, plus an Action-button setup
  walkthrough in Settings. Background capture-start from the intent is pending the
  R0a real-device pass (simulator can't prove it); it degrades to opening the app.
- **`Apps/`** — the three targets: `OpenWhisp` (SwiftUI host app + shared App
  Intents), `OpenWhispKeyboard` (keyboard extension), and `OpenWhispWidgets`
  (Live Activity + Control Center control).
- **`project.yml`** — the XcodeGen spec (the `.xcodeproj` is generated and
  git-ignored). Bundle IDs, the `group.app.openwhisp.ios` App Group, the
  `openwhisp://` URL scheme, `NSSupportsLiveActivities`, and iOS 18 deployment are
  wired here (decisions D2/D10).

### Bootstrap, test, build

```sh
./scripts/bootstrap.sh       # verify/install XcodeGen, generate OpenWhisp.xcodeproj
./scripts/test.sh            # swift test on OpenWhispMobileKit (the always-green gate)
./scripts/check-fixtures.sh  # validate the checked-in audio fixtures
./scripts/build-sim.sh       # unsigned simulator build of all three targets
./scripts/run-sim.sh         # boot a simulator, install + launch the app (see it running)
./scripts/uitest.sh          # simulator XCUITest (host smoke + dictation floor flow + system-keyboard typing)
```

The full testing contract — the tier table, what runs in CI vs. locally/nightly,
the env-gated real-engine runs, and the real-device checklist — is in
[docs/TESTING.md](docs/TESTING.md).

Signing uses automatic signing with the team taken from the `DEVELOPMENT_TEAM`
environment variable; simulator builds succeed unsigned (no team needed). CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs the package tests
and the unsigned simulator build on every push/PR.

> **Device builds:** the generated project carries the literal
> `${DEVELOPMENT_TEAM}` build setting, so Xcode only resolves a team when it
> inherits the env var — launch it via `DEVELOPMENT_TEAM=XXXXXXXXXX xed .`
> (or export it in your shell profile). Opening Xcode from the Dock leaves the
> team empty and automatic signing for device runs will fail; simulator runs
> are unaffected.

The design docs remain the source of truth:

| Doc | What it is |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, module boundaries, decisions, and the Swift interfaces every component implements |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Concrete work packages (WP0–WP9) with dependencies, acceptance criteria, and test gates — sized for autonomous agent dispatch |
| [docs/RESEARCH.md](docs/RESEARCH.md) | The fact-checked feasibility study (platform constraints, App Store rules, sync tiers, MCP role) — the "why" behind every decision |
| [docs/TESTING.md](docs/TESTING.md) | The tiered testing contract: the `swift test` gate, fixtures, simulator XCUITest, env-gated real-engine runs, and the real-device checklist |

Tracking: [MAK-51](https://linear.app/maksym-naboka/issue/MAK-51/strategic-bet-local-first-iosipados-companion-on-device-dictation)

## The one constraint that shapes everything

iOS keyboard extensions **cannot access the microphone** — ever, even with Full
Access. So the keyboard is a thin client that inserts finished text, and
capture + Whisper transcription live in the host app, handed off through an
App Group container. See [docs/RESEARCH.md](docs/RESEARCH.md) §2.

## Principles (inherited from OpenWhisp)

1. **Never phones home.** On-device transcription; network use is only the
   opt-in LAN link to *your* Mac.
2. **Pay once, own it.** No subscription, no account.
3. **Power user's kit.** Same vocabulary, prompt packs, voice commands, and
   MCP participation as the Mac app.
