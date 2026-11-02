# FIFTEEN - Hardcore App Blocker

[![iOS CI](https://github.com/JiajunGao88/hardcore-lock/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/JiajunGao88/hardcore-lock/actions/workflows/ios-ci.yml)
[![SwiftLint](https://github.com/JiajunGao88/hardcore-lock/actions/workflows/swiftlint.yml/badge.svg)](https://github.com/JiajunGao88/hardcore-lock/actions/workflows/swiftlint.yml)

A brutally honest iOS app that blocks distracting apps with **no way to unlock early**. Once you commit, there's no going back.

> *"NO ESCAPE. NO REFUNDS."*

## 📱 Overview

FIFTEEN (Hardcord Lock App) is a focus/digital detox application that uses Apple's Screen Time APIs to enforce app blocking. Unlike other focus apps that let you cheat by simply closing the app or paying to unlock, FIFTEEN is designed to be truly unbreakable.

**Key Philosophy:** Discipline through commitment. When you lock apps, they stay locked until the timer ends.

## ✨ Features

### Core Functionality
- **App Blocking** - Select specific apps or entire categories to block
- **Custom Duration** - Choose from presets (15m to 12h) or set custom durations up to 30 days
- **No Unlock Button** - The shield screen intentionally has no way to bypass
- **Persistence** - Lock survives app termination, phone restarts, and force quits
- **Tamper-resistant clock** - Changing the system date/time neither ends a lock
  early nor skews its countdown (monotonic clock within a boot)
- **Uninstall protection** - While a block is on, apps can't be deleted —
  including FIFTEEN itself (toggle on the NOW screen; on by default)
- **Schedule lock-in** - A schedule that is blocking can't be switched off,
  edited or deleted until its window ends
- **Health checks** - The home screen says so when Screen Time access is off or
  the App Group is missing, instead of silently not blocking
- **Total Time Tracking** - Tracks cumulative time spent in focus sessions

### Three Modes (v3.1+)
The home screen has a **NOW / SCHEDULE / AI** switcher:

- **NOW** — the original one-tap manual lock.
- **SCHEDULE** — *automatic* recurring blocks. Pick apps, the days of the week,
  a time window, and a cadence (every week, or *every N weeks*). The block turns
  on and off by itself in the background, even with the app closed. Overnight
  windows (e.g. 22:00 → 06:00) are supported.
- **AI** — *predict & prevent*. The app learns, fully on-device, **when** you
  reach for your distracting apps — separately for each weekday — then sends a
  nudge **before** that day's peak so you can pre-commit to a lock, on your
  command, never automatically. Under the hood:
  - a **hierarchical Bayesian (Beta-Binomial) model** per weekday × hour, shrunk
    toward the all-days estimate, with a 21-day forgetting half-life and
    decisions made on the posterior lower bound (no "habits" from 3 samples);
  - a **Thompson-sampling bandit** that learns which nudge lead time
    (5–30 min) you actually act on, from LOCK NOW vs. dismiss;
  - an optional **on-device language-model coach** (iOS 26 + Apple
    Intelligence, Foundation Models) that turns the numbers into a short
    weekly insight and nudge copy.

  See [ADR-0001](docs/adr/0001-v4-enforcement-learning-ci.md) for why this is
  the right model given what iOS lets an app see.

> **Privacy:** AI mode never sends usage data anywhere. Apple sandboxes Screen
> Time usage data on the device; every model here runs on the device (no
> cloud, no external AI calls). Schedule + AI are Pro features.

### Shield Screen
- Full-screen black shield when trying to open blocked apps
- Rotating motivational/taunting messages:
  - *"Don't be weak."*
  - *"Touch grass."*
  - *"Stay focused."*
  - *"You chose this."*
  - And 16 more...

### Business Model
- **One-time purchase: $4.99** - No subscriptions, lifetime access
- Purchase required before first lock
- Restore purchases supported

## 🏗️ Architecture

### Project Structure

```
Hardcord Lock App/
├── Main App
│   ├── Hardcord_Lock_AppApp.swift    # App entry point (+ AppDelegate adaptor)
│   ├── AppDelegate.swift              # AI-nudge notification actions
│   ├── ContentView.swift              # Main UI (NOW/SCHEDULE/AI switch + shield)
│   ├── BlockModesView.swift           # Schedule + AI screens
│   ├── SharedKit.swift                # SHARED w/ extension: App Group, named
│   │                                  #   stores, models, week-parity, AI stats
│   ├── LockGuard.swift                # SHARED: lock record, tamper-resistant
│   │                                  #   clock, segmented DeviceActivity backstop
│   ├── HabitModel.swift               # SHARED: Bayesian model + bandit + planner
│   ├── AICoach.swift                  # On-device LLM coach (iOS 26+, optional)
│   ├── ScheduleManager.swift          # Schedule CRUD + DeviceActivity registration
│   ├── HabitEngine.swift              # AI: learn → predict → nudge → challenge
│   ├── AppBlocker.swift               # Manual/AI lock (isolated `.manual` store)
│   ├── LockManager.swift              # Timer & state management
│   ├── FamilyControlsManager.swift    # Screen Time authorization
│   └── StoreManager.swift             # In-App Purchase handling
│
├── DeviceActivityManager/             # App Extension
│   ├── DeviceActivityMonitorExtension.swift
│   ├── Info.plist
│   └── DeviceActivityManager.entitlements
│
├── ShieldConfigurationExtension/      # App Extension
│   ├── ShieldConfigurationExtension.swift
│   ├── Info.plist
│   └── ShieldConfigurationExtension.entitlements
│
└── Tests/
    ├── Hardcord Lock AppTests/
    └── Hardcord Lock AppUITests/
```

### App Extensions

#### 1. DeviceActivityManager
- **Type:** Device Activity Monitor Extension
- **Purpose:** Runs blocking + learning in the background (app closed)
- **Behavior:**
  - `intervalDidStart`: For a **schedule** window, applies the shield to that
    schedule's isolated store (after an every-N-weeks parity check). For an **AI**
    window, marks the day as observed.
  - `intervalDidEnd`: For the manual lock, checks the lock record against the
    tamper-resistant clock and either clears it or re-shields and arms the next
    segment. For a schedule, clears the relevant store — the schedule
    whose window just ended (overnight windows clear only on the morning segment).
    Named stores keep manual / schedule / other locks from clearing each other.
  - `eventDidReachThreshold`: Records an AI "heavy use" hit for the current
    time-window into the App Group (the learning signal).
  - Shares `SharedKit.swift` with the app via the App Group.

#### 2. ShieldConfigurationExtension  
- **Type:** Shield Configuration Data Source
- **Purpose:** Customizes the blocking screen appearance
- **Features:**
  - Dark blur background
  - Random taunting message as title
  - **No buttons** - intentionally prevents any user interaction

### Key Frameworks Used

| Framework | Purpose |
|-----------|---------|
| `FamilyControls` | Screen Time authorization & app picker |
| `ManagedSettings` | Apply/remove app shields |
| `DeviceActivity` | Schedule monitoring intervals |
| `ManagedSettingsUI` | Customize shield appearance |
| `StoreKit` | In-App Purchase |
| `FoundationModels` | Optional on-device coach (iOS 26+) |
| `UserNotifications` | Lock completion alerts |

## 🔧 Technical Details

### How Blocking Works

1. **Authorization**: User grants Screen Time access via `FamilyControls`
2. **Selection**: User picks apps/categories using `FamilyActivityPicker`
3. **Record**: a `ManualLockRecord` (wall-clock start/end, monotonic start,
   boot ID) is written to the App Group so the app and extension agree
4. **Shielding**: `ManagedSettingsStore` applies shields (and, optionally,
   `denyAppRemoval`) to the selected apps
5. **Backstop**: `DeviceActivityCenter` arms a ≤24h interval with absolute
   date components; the extension chains the next one until the lock is over
6. **Completion**: whoever first sees `LockGuard` report the lock expired
   (extension or app) lifts the shield; the app credits TIME SAVED

### Why the clock can't be gamed

Within one boot, expiry is judged by `CLOCK_MONOTONIC_RAW` (keeps counting
while asleep; unaffected by Settings › Date & Time). Only after a reboot does
the wall clock decide. Every uncertain path fails **closed**: at worst a shield
stays up until the app is next opened.

### Minimum Duration
- **15 minutes minimum** - Enforced to prevent trivial locks
- Custom durations below 15m are auto-adjusted

### Bundle Identifiers

| Target | Bundle ID |
|--------|-----------|
| Main App | `com.bluewave.hardcorelock` |
| DeviceActivityManager | `com.bluewave.hardcorelock.deviceactivity` |
| ShieldConfiguration | `com.bluewave.hardcorelock.shield` |

## 🎨 UI Design

### Design Philosophy
- **Monospaced typography** - Technical, no-nonsense aesthetic
- **Black & white only** - Minimal, distraction-free
- **No emojis in UI** - Only in debug logs
- **Brutalist approach** - Square corners, stark contrast

### Screens

1. **Main Screen**
   - App title "FIFTEEN"
   - Total locked time counter
   - App selector button
   - Duration selector button  
   - LOCK button

2. **Shield Screen** (during active lock)
   - Large countdown timer (HH:MM:SS)
   - Rotating taunting message
   - Comment: `// NO UNLOCK BUTTON`

3. **Paywall**
   - "HARDCORE MODE" title
   - $3.99 price
   - "FOREVER" subtitle
   - UNLOCK button
   - Restore purchase link

## 📋 Requirements

- **iOS 18.0+** (supports iOS 18 through the latest 26.x; iOS 26.4-only APIs
  light up automatically on devices that have them, via availability checks)
- **Xcode 26.x**
- **Apple Developer Account** with Screen Time entitlements
- **App Store Connect** configured for IAP (product ID: `com.hardcorelock.pro`)

## 🔐 Entitlements

### Main App
```xml
<key>com.apple.developer.family-controls</key>
<true/>
<key>aps-environment</key>
<string>development</string>
<key>com.apple.security.application-groups</key>
<array><string>group.com.bluewave.hardcorelock</string></array>
```

### Extensions
```xml
<key>com.apple.developer.family-controls</key>
<true/>
<key>com.apple.security.application-groups</key>
<array><string>group.com.bluewave.hardcorelock</string></array>
```

## 🚀 Setup

1. Clone the repository
2. Open `Hardcord Lock App.xcodeproj` in Xcode
3. Update bundle identifiers and team ID
4. Request Screen Time API entitlement from Apple (if not already approved)
5. Configure IAP product in App Store Connect
6. **Register the App Group** (required for Schedule + AI modes — see below)
7. Build and run on physical device (Screen Time doesn't work in Simulator)

### ⚠️ App Group registration (required for Schedule + AI)

Schedule and AI modes rely on a shared **App Group** so the main app and the
`DeviceActivityManager` extension can share the selected apps, schedule configs,
and learned usage stats across processes. The group id is already wired into all
three targets' entitlements:

```
group.com.bluewave.hardcorelock
```

One **out-of-band** step the code can't do for you, before the first device build:

1. Apple Developer portal → **Certificates, Identifiers & Profiles → Identifiers →
   App Groups** → register `group.com.bluewave.hardcorelock` (once).
2. Make sure each App ID (main app + both extensions) has that App Group assigned.
   With **Automatic** signing, Xcode regenerates the provisioning profiles on the
   next build. If signing fails with *"profile doesn't include the
   application-groups entitlement"*, assign the group to the App IDs manually,
   then clean-build.

If the App Group is missing/mismatched, scheduled shields silently never apply
(the extension's shared `UserDefaults` is nil) — so this step is not optional.

## ⚠️ Important Notes

- **Physical device required** - Screen Time APIs don't work in Simulator
- **No unlock button** - By design, there's no way to unlock early in the app
- **App deletion** - Blocked while a block is on (uninstall protection). With
  it switched off, deleting FIFTEEN removes its shields — that is iOS behaviour
- **Known limit** - With `.individual` authorization, iOS always lets the user
  revoke FIFTEEN's Screen Time access in Settings. The app detects it and says
  so. For a truly locked-down setup, have someone else set a Screen Time passcode

## 🔁 Continuous Integration

GitHub Actions (`.github/workflows/`):

| Workflow | What it does |
|----------|--------------|
| `ios-ci.yml` | Simulator build + unit tests (uploads `.xcresult`), **Xcode Analyze**, and an unsigned **Release device build** — on every push and PR |
| `swiftlint.yml` | SwiftLint (config in `.swiftlint.yml`) |
| `codeql.yml` | CodeQL security scan for Swift — PRs to `main` + weekly |
| `dependabot.yml` | Keeps the Actions versions current |

CI builds unsigned (`CODE_SIGNING_ALLOWED=NO`) because Screen Time entitlements
need a real provisioning profile; that still compiles and links all three
targets. Shields themselves can only be verified on a physical device.

## 🧪 Debug Features

In `DEBUG` builds only:
- `🧪 DEV: Simulate Purchase` button - Bypasses IAP for testing

## 📝 License

[Add your license here]

## 👤 Author

Created by Jiajun Gao

---

*"Commit to your life. No subscriptions. No excuses."*
