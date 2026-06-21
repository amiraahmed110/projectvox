# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

VoxGuard (`vox_guard`) is a Flutter personal-safety / emergency-SOS app. It continuously
listens via the microphone, uses backend AI services (speech-to-text + emotion/voice-stress)
to detect danger, and on confirmation opens an SOS session that streams live GPS and uploads
audio evidence — surviving the screen being off. Targets mobile (Android/iOS); other platform
folders are stock Flutter scaffolding.

Flutter 3.35.x, Dart SDK `>=3.3.0 <4.0.0`. Lints: stock `flutter_lints`.

## Commands

```bash
flutter pub get                      # install deps
flutter run                          # run on attached device/emulator
flutter analyze                      # static analysis / lint
flutter test                         # run all tests
flutter test test/widget_test.dart  # run a single test file
flutter build apk                    # Android build
flutter build ios                    # iOS build (run `pod install` in ios/ if pods are stale)
dart run flutter_launcher_icons      # regenerate launcher icons from images/logo.png
```

Note: `test/widget_test.dart` is the **stale default counter smoke test** (it pumps
`VoxGuardApp` but asserts a counter that doesn't exist), so `flutter test` currently fails.
There is no real test suite — don't treat the existing test as a regression baseline.

## Backend is required and hardcoded

All network calls route through `lib/config/api_config.dart`, which hardcodes a **LAN IP
`http://192.168.1.191`**:
- `:8000/api` — main Laravel REST API (auth, SOS, dictionary, reports)
- `:8003/transcribe` — speech-to-text microservice
- `:8001/analyze-smart/` — emotion / voice-stress microservice

The app does not work against a real backend off that network. Change the host in **one place**
(`ApiConfig.host`). Some endpoints are explicit placeholders (commented `NOTE: assumed route`):
`monitorAudioUrl` and the background-log `POST /sos/{id}/log` — verify against the actual API
before relying on them.

## Architecture (the parts that span multiple files)

### Two isolates, one microphone
The app runs monitoring in two places that must never grab the mic simultaneously:
1. **Foreground monitor** — runs while the app is open on the home tab (`lib/screens/sos/home_screen.dart`).
2. **Background foreground-service isolate** — `lib/screens/sos/background_service.dart` (`onStart`,
   `@pragma('vm:entry-point')`), launched once at app start from `main.dart` and again per-SOS.

Coordination is via a SharedPreferences flag **`sos_active`** (`kSosActiveKey` in `ai_monitor.dart`):
the background service sets it `true` on SOS start and the foreground monitor checks it and steps
aside. When touching either monitor, preserve this handshake or the two will fight over `RECORD_AUDIO`.

The background service's notification channel id **`voxguard_emergency`** must stay identical in
`main.dart` (channel creation) and `background_service.dart` (`AndroidConfiguration`).

### SOS lifecycle — `lib/screens/sos/sos_service.dart`
UI-free service shared by both the manual flow (`emergency_screen.dart`) and AI auto-trigger:
- `startSession(triggerType)` → `POST /sos/start`. **Falls back to a mock session** (negative
  `sosId`, `isMock=true`) when there's no token or the backend is unreachable, so the SOS flow
  always completes for demos/offline. A **negative `sosId` means "don't upload to server"** —
  this convention is checked in the background service and `ai_monitor.uploadRecordingToBackend`.
- `startBackgroundGuard(...)` requests mic permission in the **foreground** (the background isolate
  can't prompt), starts the service, then `invoke('startSOS', {...})` to hand over the session.
- During SOS the background isolate records 2-minute WAV chunks (16kHz mono), uploads each as
  evidence, re-runs the AI pipeline on it, and streams location (`distanceFilter: 10m`) to
  `/sos/{id}/location`.

### AI detection — two-stage pipeline in `lib/screens/sos/ai_monitor.dart`
- **Stage 1 `screenForDanger`** (cheap, constant, 12s window `kListenWindow`): STT → backend
  danger-dictionary check.
- **Stage 2 `confirmEmotion`** (heavy, rare): emotion model on a 2-min clip (`kAiChunkDuration`),
  the final decision-maker.
- `analyzeAudioChunk` runs both, honoring the **Emotion Detection** toggle (off ⇒ a danger-word hit
  fires SOS directly).
- `isInsideSafeZone` pauses the auto pipeline inside user-defined SAFE zones (manual SOS is never
  paused). Danger zones do NOT pause it.

### SharedPreferences is the de-facto cross-component state bus
There is no state-management library (no Provider/Bloc/Riverpod). Components communicate through
well-known SharedPreferences keys. The important ones (defined as constants near their owners):
- `auth_token` / `token` — JWT (see token-key gotcha below)
- `user_id`, `user_name`, `user_image`
- `current_sos_id`, `sos_is_mock` (`SosService.prefsSosId` / `prefsIsMock`)
- `sos_active` (`kSosActiveKey`) — cross-isolate mic handoff
- `ai_auto_mode_enabled` (`kAiAutoModeKey`), `emotion_detection_enabled` (`kEmotionDetectionKey`) — Settings toggles
- `user_custom_zones_local` — JSON list of map zones, shared between map screen and `ai_monitor`
- `sos_bg_log` (`kSosBgLogKey`) — rolling 500-entry diagnostic log shown in `background_log_screen.dart`

### Navigation
Mixed: named routes are registered in `main.dart` (`/login`, `/home`, `/permissions`, …) but many
screens are also pushed directly via `MaterialPageRoute`. Follow the convention already used by the
neighboring screens you're editing.

## Conventions & gotchas

- **Comments and logs are bilingual (Arabic + English).** This is intentional throughout the SOS
  code — match the surrounding style; don't "clean up" Arabic comments.
- **Token-key inconsistency**: `SosService` reads `prefs.getString('token') ?? prefs.getString('auth_token')`,
  but `ai_monitor.dart` reads only `auth_token`. When writing auth state, set `auth_token` to stay
  compatible with both; be aware of this when debugging "works in SOS but AI calls are unauthorized".
- **Permissions are foreground-resolved.** `permission_handler` is the source of truth for mic status
  inside the background isolate (the `record` package's `hasPermission()` is unreliable there).
- Code lives under `lib/screens/<feature>/` (auth, sos, safety, map, profile, reports, fake_call,
  voice_password, trust_contacts, device). Shared config in `lib/config/`, shared widgets in
  `lib/custom_widgets/` and `lib/screens/widgets/`.
- Root contains stray non-Flutter dirs (`Amira/`, `voxGuard/`) — ignore them.
