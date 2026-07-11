# OpenWhisp for iOS

Local-first dictation for iPhone and iPad — a custom keyboard that dictates
anywhere, backed by on-device Whisper in the host app. **Nothing leaves your
phone**; sync with the [OpenWhisp macOS app](https://github.com/initcore0/openwhisp)
is peer-to-peer over your own Wi-Fi.

> Your Mac's dictation, now in your pocket — same private engine, no cloud,
> no subscription, no keylogger keyboard.

## Status

**Architecture / planning phase.** No app code yet. Start here:

| Doc | What it is |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design, module boundaries, decisions, and the Swift interfaces every component implements |
| [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md) | Concrete work packages (WP0–WP9) with dependencies, acceptance criteria, and test gates — sized for autonomous agent dispatch |
| [docs/RESEARCH.md](docs/RESEARCH.md) | The fact-checked feasibility study (platform constraints, App Store rules, sync tiers, MCP role) — the "why" behind every decision |

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
