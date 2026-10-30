# OpenMEAT — Product & Technical Spec

Status: **Draft v0.1** (2026-10-29). Living document — change it as we learn.

OpenMEAT is an open-source iOS app that replaces the *cooking* experience of the
ThermoWorks app for RFX probes. It talks to ThermoWorks Cloud using the user's own
ThermoWorks account. It deliberately does **not** do probe setup, pairing, firmware,
or gateway configuration — use the official app for that.

---

## 1. Goals and non-goals

### Goals
1. **Fast target setup** — set a target temperature for any probe in ≤ 2 taps from the live screen, with presets (e.g. "Brisket 203°F", "Chicken breast 160°F").
2. **Great live graphs** — real-time, multi-probe, including ambient sensors; zoom, pan, scrub, toggle series, annotations for notes.
3. **Estimated time to target** — physics-based estimate (Newton's law of heating with an EWMA-smoothed `k`), updating as data arrives. The estimator is pluggable; we expect to iterate on it.
4. **Notes during a cook** — quick timestamped notes ("Wrapped", "Spritzed") that appear on the graph.
5. **Cook history** — every cook is saved with all samples, notes, and targets; browse and re-open with the full interactive graph.
6. **Live Activity / Dynamic Island** — start time, elapsed time, current temp, target, ETA.
7. **"Almost done" notification** — X minutes before the estimated done time (default **5 min**, adjustable globally and per cook), plus "target reached".
8. **Excellent test coverage** — unit, integration and UI suites, all runnable without a real account via a mock API.

### Non-goals (v1)
- Probe/gateway configuration, renaming, alarms on the device, firmware updates.
- Non-RFX devices (Signals, Smoke, Node). The client should *tolerate* them (unknown types render as generic channels), but they are not tested targets.
- Android, watchOS, macOS (watchOS is a plausible v2).
- Social/sharing features beyond exporting a cook (CSV/JSON).

---

## 2. Users and core flows

| Flow | Description |
| --- | --- |
| **Sign in** | Email + password for ThermoWorks Cloud. Credentials → Keychain; tokens refreshed automatically. "Demo mode" uses the mock API (also used by UI tests and App Review). |
| **Start a cook** | Live screen lists all online probes. "Start cook" → pick which probes/channels belong to this cook, set each sensor's role (meat / ambient) and name — **remembered per channel for next time** — optional title → recording begins. Roles and names can also be changed mid-cook (long-press a card). |
| **Set target** | Tap a probe card's target chip → wheel/stepper + preset list → done. Target line appears on the graph immediately; ETA starts computing. |
| **Watch** | Live screen: probe cards (current temp, target, ETA, trend arrow, ambient) on top, interactive chart below, note bar at the bottom. |
| **Add a note** | Tap a quick-note chip or "+" for free text. The note is time-stamped "now" (editable time) and drawn as a marker on the chart. |
| **Get notified** | "~5 min until Pork Butt hits 203°F" and "Pork Butt reached 203°F". Live Activity reflects the same state. |
| **Finish** | "End cook" → summary (duration, peak temps, notes) → saved to history. Cooks also auto-end after N hours of no data (configurable, default 2h). |
| **History** | List of past cooks (title, date, duration, mini sparkline). Detail screen = same interactive chart, notes list, export. |

---

## 3. ThermoWorks Cloud API

There is no official public API. The unofficial Python library
[`python-thermoworks-cloud`](https://github.com/a2hill/python-thermoworks-cloud) documents
the observed behavior of the ThermoWorks web client (cloud.thermoworks.com). The service is a
standard **Firebase** project: Firebase Auth (Identity Toolkit) + Cloud Firestore REST + Firebase Storage.

> ⚠️ **Licensing:** the Python library is **GPL-3.0**. A line-by-line port would make OpenMEAT a
> derivative work (GPL-3.0 is also awkward for App Store distribution). Our Swift client is written
> **clean-room against Google's public Firebase REST documentation** plus the *facts* about
> endpoints and document field names (which are not copyrightable). Do not copy code or
> structure from the Python library. OpenMEAT is MIT-licensed.

### 3.1 Endpoints

| Purpose | Request |
| --- | --- |
| Project config | `GET https://firebase.googleapis.com/v1alpha/projects/-/apps/{appId}/webConfig` with `x-goog-api-key` → `projectId`, `storageBucket` |
| Sign in | `POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key={apiKey}` `{email, password, returnSecureToken: true}` → `idToken`, `refreshToken`, `expiresIn`, `localId` |
| Refresh | `POST https://securetoken.googleapis.com/v1/token?key={apiKey}` `{grant_type: "refresh_token", refresh_token}` → `id_token`, `refresh_token`, `expires_in`, `user_id` |
| User | `GET {root}/documents/users/{uid}` → `accountId`, prefs |
| Devices | `POST {root}/documents:runQuery` with `structuredQuery` on `devices` where `accountId == …` |
| Channels (one) | `GET {root}/documents/devices/{serial}/channels/{n}` |
| Channels (all) | `GET {root}/documents/devices/{serial}/channels` (list) — **to verify**; fallback: probe `1…N` until 404 |
| Channels (batched) | `POST {root}/documents:batchGet` with all channel doc names → one request per poll for every probe |
| Archives | `GET {root}/documents/devices/{serial}/archive?orderBy=createdOn desc` and Storage `GET /v0/b/{bucket}/o/{file}?alt=media` (rows: `[channel, ts, value, units]`) |

`root = https://firestore.googleapis.com/v1/projects/{projectId}/databases/(default)`.
All Firestore/Storage requests carry `Authorization: Bearer {idToken}`; Firebase calls carry
`referer: https://cloud.thermoworks.com/`. The API key and app id are the public web-client
values, kept in `ThermoWorksConfiguration` so they can be overridden.

### 3.2 Data model (as observed)

- **Device** (`devices/{serial}`): `serial`, `label`, `type` (`"rfx"` for RFX), `device` (`"rfx meat"`),
  `battery`, `batteryState`, `gatewayRSSI` (string *or* int), `wifi_stength` (sic), `status`,
  `lastSeen`, `transmitIntervalInSeconds`, `recordingIntervalInSeconds`, `sessionStart`,
  optional `fan` map.
- **Channel** (`devices/{serial}/channels/{n}`): `value` (double *or* integer), `units` (`F`/`C`),
  `status` (`NORMAL`, …), `type`, `label`, `number`, `lastSeen`, `lastTelemetrySaved`,
  `alarmHigh`/`alarmLow` (`enabled`, `alarming`, `value`, `units`), `minimum`/`maximum`.
- Firestore values are typed wrappers (`stringValue`, `integerValue` *as a string*, `doubleValue`,
  `timestampValue`, `mapValue.fields`, `arrayValue.values`, `nullValue`). Our decoder must
  accept either numeric representation and ignore unknown fields.

### 3.3 Unknowns to resolve against a real account (Milestone 0)
1. **RFX channel layout**: which channel numbers/`type` values are the internal sensors vs. the
   ambient sensor of an RFX Meat probe. Until confirmed, `ChannelRoleClassifier` uses `type`/`label`
   heuristics and the user can override a channel's role.
2. **Update cadence**: how often RFX channel docs update (`transmitIntervalInSeconds`?). Drives polling interval.
3. **History backfill**: does the web client fetch a live session's history (graph) from an endpoint
   we can call? If yes, we backfill gaps when the app was suspended. If no, gaps remain gaps (drawn as breaks).
4. **Firestore `listen`** (streaming) viability over REST/WebChannel — would replace polling.
5. Rate limits / ToS sensitivities. Keep polling polite (default 15 s, min 5 s, back off on errors).

Milestone 0 deliverable: a `capture` debug command that dumps sanitized device/channel JSON into
`Packages/OpenMEATKit/Tests/Fixtures/` so tests run against real shapes.

---

## 4. Architecture

```
┌─────────────────────────── OpenMEAT (iOS app, SwiftUI) ───────────────────────────┐
│ Features: Auth · Live · Chart · Notes · History · Settings                          │
│ Services: AppEnvironment (DI) · NotificationScheduler · LiveActivityController      │
│           CredentialStore (Keychain) · AppSettings · BackgroundRefresh              │
└──────────────┬──────────────────────────────────────────────────────┬──────────────┘
               │                                                      │ CookActivityAttributes
┌──────────────▼──────────────── OpenMEATKit (Swift package) ─────────▼──────────────┐
│ CookSession   – LiveCookSession (polling loop, sample ingest, estimates, events)    │
│ CookCore      – Cook, Sample, Temperature, estimators, LTTB downsampler,            │
│                 AlertPlanner, CookStore (file-backed)                  (pure Swift) │
│ ThermoWorksCloud – Firestore value decoding, models, auth/token mgmt, HTTP client,  │
│                    ThermoWorksService protocol + live implementation               │
│ ThermoWorksMock  – CookSimulator (physics), MockThermoWorksService,                 │
│                    StubHTTPClient + recorded fixtures                               │
└─────────────────────────────────────────────────────────────────────────────────────┘
OpenMEATWidgets (extension) – Live Activity + Dynamic Island UI
```

Principles
- **Everything that isn't UI lives in the package** and builds/tests on macOS with `swift test`
  (fast loop, no simulator).
- **Protocols at the seams**: `ThermoWorksService`, `HTTPClient`, `CookStore`, `DoneTimeEstimator`,
  `NotificationScheduling`, `LiveActivityControlling`, `TimeSource`. Real and fake implementations for each.
- **Swift 6 strict concurrency.** Services are `Sendable`; the session is an `actor`; view models are `@MainActor @Observable`.
- **Injected time** (`TimeSource`) everywhere so the estimator, alerts and simulator are deterministic in tests.
- Minimum iOS **18.0** (Swift Charts scrolling/selection, ActivityKit, Observation).

### 4.1 Live data pipeline
1. `LiveCookSession` polls `ThermoWorksService.fetchChannels(for:)` every `pollInterval` (default 15 s; uses `batchGet`).
2. New readings are deduped by `lastTelemetrySaved` (don't record the same reading twice) and appended as `Sample(t, value)` per `ChannelKey(serial, channel)`, normalized to °C internally.
3. For each channel with a target, the estimator produces `Estimate { eta, k, confidence, state }`.
4. The session publishes `SessionSnapshot` via `AsyncStream` → UI, `LiveActivityController`, `NotificationScheduler`.
5. Samples are persisted incrementally (append-only, flushed every N samples / on background) so a crash loses ≤ 1 minute.

### 4.2 Background behavior (important constraint)
iOS suspends apps in the background, so **polling stops** and timers don't fire when the user leaves
the app. There is no API that lets a third-party app run a timer every minute while suspended.
What we do (implemented in `BackgroundRefresh` / `LiveActivityController`):

| Lever | Effect |
| --- | --- |
| **Foreground + "Keep screen on"** (default on during a cook) | Real-time polling (default 15 s). Best experience: phone on a stand by the cooker. |
| **Grace window on backgrounding** (`beginBackgroundTask`) | Pushes the freshest state to the Live Activity and saves before suspension. |
| **`BGAppRefreshTask`**, requested 60 s out, re-requested on every wake | Opportunistic: iOS decides when (often 15+ min; more often for apps used a lot, on power). Each wake polls, updates the Live Activity, reschedules alerts. |
| **Self-updating Live Activity UI** | Elapsed time (`Text(timerInterval:)`), ETA countdown, and a cook-progress bar (`ProgressView(timerInterval:)`) keep moving with no updates. After 20 min without an update it shows "Updated hh:mm". |
| **Pre-scheduled alerts** | "X min before done" / "should be done" are scheduled with UNNotification time triggers from the last ETA, so they fire even while suspended. |
| **Resume after termination** | On launch, the newest unfinished cook is resumed and its Live Activity adopted; orphaned activities from killed processes are ended. |

Not used: silent-audio / location background modes (App Review rejects them for this) and
background `URLSession` relaunch chains (iOS rate-limits relaunches; not reliable per-minute).

- **v2 (optional relay):** a tiny self-hostable worker (e.g. Cloudflare Worker) that polls ThermoWorks for an active cook and sends ActivityKit push updates + APNs alerts every minute. This is the only way to get true per-minute updates while the app is suspended. Opt-in; the app works fully without it.

---

## 5. Domain model (CookCore)

```swift
struct Temperature        // canonical Celsius Double; formatting in °F/°C
struct ChannelKey         // deviceSerial + channel number (Hashable, Codable)
enum   ProbeRole          // .internal, .ambient, .unknown  (user-overridable)
struct Sample             // time: Date, celsius: Double
struct CookProbe          // key, label, role, target: Temperature?, color index, pairedAmbient: ChannelKey?
struct CookNote           // id, time, text, kind (.free, .preset(String))
struct Cook               // id, title, startedAt, endedAt?, probes, notes, series [ChannelKey: [Sample]], metadata
struct Estimate           // eta: Date?, ratePerMinute, k, confidence, state (.warmingUp, .estimating, .stalled, .reached, .unavailable)
```

Persistence: `FileCookStore` — one JSON document per cook in Application Support plus a small
index for the history list. A 16-hour cook × 6 channels × 15 s ≈ 23k samples ≈ ~1 MB JSON, fine.
If it becomes a problem: binary sample encoding or SQLite (GRDB). Export: JSON + CSV.

---

## 6. Time-to-target estimation

> **Provisional** — expected to change. Implemented behind `DoneTimeEstimator` so alternatives
> (linear, Kalman, stall-aware, ML) can be A/B'd against recorded cooks.

**Model:** Newton's law of heating. With probe temp `T`, ambient `Ta`, rate constant `k`:

```
dT/dt = k · (Ta − T)        →   k_inst = (dT/dt) / (Ta − T)
```

**Real-time k:**
1. Smooth the derivative: `dT/dt` from a least-squares slope over a trailing window (default 5 min) — raw 15 s deltas at 0.1° resolution are noise.
2. `k_inst` from the slope and the window-average `(Ta − T)`. Skip when `Ta − T` is small (< 5 °C) — ill-conditioned.
3. **Time-aware EWMA** so irregular sampling (gaps, background) is handled:
   `α = 1 − exp(−Δt · ln2 / halfLife)`, `k ← α·k_inst + (1 − α)·k` (default half-life 10 min).

**ETA:** when `Ta > target`:
```
t_remaining = ln((Ta − T) / (Ta − target)) / k
```
Otherwise (ambient below target, no ambient, or k ≤ 0): fall back to an EWMA of the linear rate
(`(target − T) / rate`), and mark confidence low.

**Ambient source:** the probe's own ambient sensor if present → user-chosen pit probe → none (linear fallback). `Ta` itself is EWMA-smoothed (lid openings cause spikes).

**States:** `.warmingUp` (< 10 min of data or k not yet stable) → show "Calculating…";
`.stalled` (rate ≈ 0 in the 60–77 °C band for > 20 min) → show "Stall" and suppress ETA-based alerts;
`.reached`; `.unavailable` (no data / disconnected).

**Known limitation (measured in the simulator):** pure Newton can't foresee a stall. In the
`brisketStall` scenario, ETAs before the stall are ~4 h early; once the stall clears, k recovers
within ~2 half-lives and the ETA is accurate (< 15 % remaining-time error). Candidate fixes for v2:
a stall prior by meat type, or widening the displayed range while in the stall band.

**Evaluation harness:** `SimulatedCookTests` replay simulated cooks and assert ETA error
bounds over time (e.g. within ±15 % for the last 50 % of the cook). Tuning parameters live in
`EstimatorConfiguration` and are exposed in a hidden debug settings screen.

---

## 7. UX spec

### 7.1 Live screen
- **Probe cards** (horizontal, one per internal probe): big current temp, target chip (tap to set), ETA ("~1h 12m · 3:42 PM"), trend (°/min), paired ambient temp, connection/battery badge. Ambient-only channels render as compact chips.
- **Chart** (see 7.2) fills the middle.
- **Note bar**: quick-note chips (customizable list) + "+" for free text + camera (v1.1).
- Toolbar: cook title, elapsed timer, "End cook".

### 7.2 Interactive chart (Swift Charts)
- One `LineMark` series per channel; internals solid, ambients dashed and lighter; stable colors per probe.
- **Target lines** (`RuleMark`) per probe in its color, labeled.
- **Projection**: dashed curve from "now" to the ETA following the fitted model, with a shaded uncertainty band (v1.1).
- **Scrub**: long-press/drag shows a vertical crosshair and a tooltip with every series' value at that time, plus elapsed time.
- **Zoom & pan**: pinch on X (time) zooms; drag pans (`chartScrollableAxes(.horizontal)`); double-tap toggles "fit all" / "last 30 min".
- **Follow live**: when the right edge is "now", the chart auto-advances; panning away pauses follow and shows a "Jump to live" button.
- **Readout above the plot** shows each series' current value (or its value at the scrubbed time), so it never clips; its items are the legend and toggle series visibility. Y-axis rescales to visible series.
- **Color** is reserved for data: one hue per meat probe from a CVD-validated categorical order (blue first); an ambient sensor uses a lighter tint of its meat probe's hue and is dashed; app chrome is neutral.
- **Note markers** on the X axis; tapping one opens the note.
- **Performance**: LTTB downsampling to ~ (2 × plot width) points per visible series; full resolution when zoomed in.
- Axis modes: clock time / elapsed time (remembered). Ticks are aligned (round clock times, or round offsets from the start), spaced for ~4–6 labels, and edge labels stay inside the plot.

### 7.3 Target picker
Sheet with large wheel (1° steps), presets grouped by meat (doneness for steaks, pull temps for BBQ), "clear target", and "apply to all internal sensors of this probe".

### 7.4 History
List grouped by month; row = title, date, duration, sparkline, final temps. Detail = chart (same component, no live follow), notes, stats (time in stall, max ambient, time per 10° band), export, delete, edit title/notes.

### 7.5 Live Activity / Dynamic Island
- **Lock screen**: title · start time · elapsed (ticking) · primary probe temp → target · ETA countdown (ticking) · progress bar (start temp → target).
- **Compact**: leading = current temp, trailing = ETA countdown. **Minimal**: temp. **Expanded**: all probes with targets.
- Primary probe = user-pinned, else the one with the soonest ETA.
- Started when a cook starts (if enabled), ended on cook end (lingers 30 min with the summary).

### 7.6 Notifications
| Alert | Default | Notes |
| --- | --- | --- |
| Almost done | ON, **5 min** lead | Global default in Settings; per-cook override. Pre-scheduled from ETA, rescheduled as ETA moves. Suppressed while stalled. |
| Target reached | ON | Fired on actual crossing (foreground/background refresh); pre-scheduled at ETA as fallback when backgrounded. |
| Probe offline | ON | No new data for > 3 × poll interval while in foreground, or on refresh. |
| Ambient out of range | OFF | v1.1, high/low bounds. |

### 7.7 Settings
Units, poll interval, almost-done lead time, quick-note list, target presets, Live Activity on/off,
sign out, demo mode toggle, debug (estimator parameters, export logs).

---

## 8. Mock API and demo mode

- `CookSimulator`: generates channel readings for N probes using Newton's law with configurable
  `k`, ambient profile (steady, ramp, lid-open dips, fire dying), a **stall** model (evaporative
  plateau around 65–75 °C), sensor noise and dropouts. Deterministic given a seed.
- `MockThermoWorksService`: implements `ThermoWorksService` over the simulator with an injectable
  `TimeSource` and **time scale** (e.g. 600× so a 10-hour cook runs in a minute).
- Scenarios: `brisketStall`, `chickenFast`, `twoProbesSteak`, `probeDisconnects`, `noAmbient`.
- App launch arguments: `-OM_MOCK 1 -OM_SCENARIO brisketStall -OM_TIME_SCALE 600 -OM_RESET 1`.
- `StubHTTPClient` (an `HTTPClient` stub, parallel-test safe unlike a global `URLProtocol`) + JSON fixtures emulate Firestore/Auth HTTP so the *real* client is exercised in tests. Fixtures are synthesized until M1 captures real ones.

---

## 9. Testing strategy

| Suite | Where | Framework | Runs | Scope |
| --- | --- | --- | --- | --- |
| **Unit (package)** | `Packages/OpenMEATKit/Tests/{ThermoWorksCloudTests, CookCoreTests, CookSessionTests}` | Swift Testing | `swift test` (macOS, seconds) | Firestore decoding, models, token expiry/refresh logic, estimator math, LTTB, alert planning, store round-trips, session ingest/dedupe |
| **Integration (hermetic)** | `Packages/OpenMEATKit/Tests/IntegrationTests` | Swift Testing | `swift test` | Real `LiveThermoWorksService` → `StubHTTPClient` fixtures (auth → devices → channels → refresh on expiry → errors); full pipeline: simulator → session → estimator → store; estimator replay accuracy |
| **Integration (live)** | same target, tag `.live` | Swift Testing | only with `THERMOWORKS_EMAIL`/`THERMOWORKS_PASSWORD` set | Smoke test against the real cloud: sign in, list devices, read channels. Never runs in CI by default. |
| **App unit** | `OpenMEATTests` | Swift Testing | simulator | View models, launch-config parsing, notification scheduling against a fake center, Live Activity state mapping |
| **UI** | `OpenMEATUITests` | XCTest/XCUITest | simulator | Demo-mode flows: start cook → set target → see ETA → add note → note on chart → end cook → history detail; settings lead time; accessibility identifiers on every interactive element |

Conventions
- Every interactive view has an `accessibilityIdentifier` from `AccessibilityID` (shared enum) so UI tests don't depend on copy.
- No sleeps in tests: inject `TimeSource`; UI tests use time scale + `waitForExistence`.
- Coverage target: ≥ 85 % for the package, tracked in CI.
- CI (GitHub Actions, macOS runner): `make test-package` on every push; `make test-app` (unit + UI on simulator) on PRs.

---

## 10. Project layout

```
openmeat/
├── project.yml                  # XcodeGen spec (source of truth for the .xcodeproj)
├── OpenMEAT.xcodeproj           # generated — `make generate`
├── Makefile                     # generate, build, test-package, test-unit, test-ui, test
├── docs/SPEC.md
├── OpenMEAT/                    # app target
│   ├── App/  Features/{Auth,Live,Chart,Notes,History,Settings}/  Services/  Resources/
├── OpenMEATWidgets/             # Live Activity extension
├── Shared/                      # files compiled into app + widget (CookActivityAttributes, AccessibilityID)
├── OpenMEATTests/  OpenMEATUITests/
└── Packages/OpenMEATKit/
    ├── Sources/{ThermoWorksCloud, CookCore, CookSession, ThermoWorksMock}/
    └── Tests/{ThermoWorksCloudTests, CookCoreTests, CookSessionTests, IntegrationTests}/
```

---

## 11. Milestones

| # | Milestone | Done when |
| --- | --- | --- |
| M0 | **Skeleton** (this) | Project builds; all suites run green; spec agreed |
| M1 | **API client** | Sign-in, token refresh, devices, channels (batched), against fixtures + live smoke test; resolve §3.3 unknowns |
| M2 | **Live cook core** | Session polling, persistence, demo mode end-to-end |
| M3 | **Chart** | All §7.2 interactions, performance on 16 h cooks |
| M4 | **Targets, ETA, notifications** | Estimator v1 + replay harness, alerts with lead time |
| M5 | **Live Activity** | Lock screen + Dynamic Island, background refresh |
| M6 | **History & notes polish** | History detail, export, quick-note customization |
| M7 | **Beta** | TestFlight, CI, README/contributing |

---

## 12. Open questions
1. ~~License~~ — **MIT** (decided 2026-10-29). The API client stays clean-room so this holds.
2. Bundle identifier / team ID / App Group name (placeholders: `org.openmeat.OpenMEAT`, `group.org.openmeat`).
3. Should setting a target also write `alarmHigh` to the cloud so the ThermoWorks push alarm fires as a backup? (It's "configuring the probe", but it's the only server-side alert we get for free.)
4. Relay server (§4.2 v2): in scope for v1.x or not?
5. Estimator details (§6) — revisit after collecting a few real cooks.
