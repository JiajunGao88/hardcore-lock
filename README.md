# FIFTEEN - Hardcore App Blocker

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
- **Total Time Tracking** - Tracks cumulative time spent in focus sessions

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
│   ├── Hardcord_Lock_AppApp.swift    # App entry point
│   ├── ContentView.swift              # Main UI (home + shield views)
│   ├── AppBlocker.swift               # Core blocking logic
│   ├── LockManager.swift              # Timer & state management
│   ├── FamilyControlsManager.swift    # Screen Time authorization
│   ├── StoreManager.swift             # In-App Purchase handling
│   └── Item.swift                     # SwiftData model (unused)
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
- **Purpose:** Monitors scheduled activity intervals
- **Behavior:** 
  - `intervalDidStart`: Logs when lock session begins
  - `intervalDidEnd`: Automatically removes all shields when timer expires

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
| `SwiftData` | Data persistence (minimal use) |
| `UserNotifications` | Lock completion alerts |

## 🔧 Technical Details

### How Blocking Works

1. **Authorization**: User grants Screen Time access via `FamilyControls`
2. **Selection**: User picks apps/categories using `FamilyActivityPicker`
3. **Scheduling**: `DeviceActivityCenter` schedules a monitoring interval
4. **Shielding**: `ManagedSettingsStore` applies shields to selected apps
5. **Persistence**: Lock end time stored in `UserDefaults` to survive restarts
6. **Completion**: `DeviceActivityMonitor` extension removes shields when interval ends

### State Persistence

```swift
// Lock survives app termination
UserDefaults.standard.set(lockEndTime, forKey: "lockEndTime")

// On app launch, check for pending lock
if savedEndTime > now {
    // Resume lock with remaining time
}
```

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

- **iOS 17.5+** (uses latest Screen Time APIs)
- **Xcode 15.4+**
- **Apple Developer Account** with Screen Time entitlements
- **App Store Connect** configured for IAP (product ID: `com.hardcorelock.pro`)

## 🔐 Entitlements

### Main App
```xml
<key>com.apple.developer.family-controls</key>
<true/>
<key>aps-environment</key>
<string>development</string>
```

### Extensions
```xml
<key>com.apple.developer.family-controls</key>
<true/>
```

## 🚀 Setup

1. Clone the repository
2. Open `Hardcord Lock App.xcodeproj` in Xcode
3. Update bundle identifiers and team ID
4. Request Screen Time API entitlement from Apple (if not already approved)
5. Configure IAP product in App Store Connect
6. Build and run on physical device (Screen Time doesn't work in Simulator)

## ⚠️ Important Notes

- **Physical device required** - Screen Time APIs don't work in Simulator
- **Cannot be bypassed** - By design, there's no way to unlock early
- **App deletion won't help** - Shield is system-level, persists even if app is deleted
- **Reinstalling app** - Will detect existing lock from UserDefaults and resume

## 🧪 Debug Features

In `DEBUG` builds only:
- `🧪 DEV: Simulate Purchase` button - Bypasses IAP for testing

## 📝 License

[Add your license here]

## 👤 Author

Created by Jiajun Gao

---

*"Commit to your life. No subscriptions. No excuses."*
