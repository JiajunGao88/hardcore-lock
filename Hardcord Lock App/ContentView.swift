//
//  ContentView.swift
//  Hardcord Lock App
//

import SwiftUI
import FamilyControls
import UserNotifications

struct ContentView: View {
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var familyControls = FamilyControlsManager.shared
    @StateObject private var lockManager = LockManager.shared
    @StateObject private var scheduleManager = ScheduleManager.shared
    @StateObject private var habitEngine = HabitEngine.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedMode: BlockMode = .now

    @State private var showPaywall = false
    @State private var paywallIntent: PaywallIntent = .manualLock
    @State private var showAppPicker = false
    @State private var showDurationPicker = false
    @State private var selectedDuration: Int = 900 // 15 分钟
    @State private var showDevAlert = false
    @State private var devAlertMessage = ""
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showMinDurationNotice = false
    @State private var minDurationNoticeText = ""
    /// Fullscreen countdown is the default face of an active lock; the user can
    /// step out to manage Schedule/AI and come back. Reset when a lock starts.
    @State private var showFullShield = true

    enum PaywallIntent { case manualLock, unlockPro }

    // 嘲讽文案
    private let tauntingMessages = [
        "Don't be weak.", "Touch grass.", "Stay focused.", "No escape.",
        "You chose this.", "Embrace the void.", "Discipline is freedom.",
        "The phone can wait.", "Be present.", "Resist the urge.",
        "You're stronger than this.", "Focus on what matters.", "Time is precious.",
        "Break the addiction.", "Control yourself.", "This too shall pass.",
        "Breathe.", "Stay hard.", "No excuses.", "Commit."
    ]

    @State private var currentTaunt: String = "Stay focused."

    // 时长选项（包含 OTHER）
    private let durationOptions: [(label: String, value: Int)] = [
        ("15m", 900), ("30m", 1800), ("1h", 3600), ("3h", 10800),
        ("6h", 21600), ("12h", 43200), ("OTHER", -1)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lockManager.isLocked && showFullShield {
                shieldView
            } else {
                mainContent
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(onPurchaseSuccess: handlePaywallSuccess)
        }
        .familyActivityPicker(
            isPresented: $showAppPicker,
            selection: $familyControls.selectedApps
        )
        .sheet(isPresented: $showDurationPicker) {
            durationPickerSheet
                .onDisappear { showCustomPicker = false }
        }
        .onAppear {
            currentTaunt = tauntingMessages.randomElement() ?? "Stay focused."
            familyControls.refreshAuthorizationStatus()
            if !familyControls.isAuthorized {
                requestAuthorization()
            }
            refreshAutomation()
            // The nudge is now the ONLY way an AI lock starts, so a request that
            // arrived before this view existed (cold launch from the notification)
            // must be drained here — .onChange never fires for it.
            if habitEngine.pendingChallenge { startAIChallenge() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshAutomation()
                if habitEngine.pendingChallenge { startAIChallenge() }
            }
        }
        .onChange(of: habitEngine.pendingChallenge) { _, pending in
            if pending { startAIChallenge() }
        }
        .onChange(of: lockManager.isLocked) { _, locked in
            // A newly started lock always opens fullscreen (the ritual); when it
            // ends, reset so the NEXT lock opens fullscreen too.
            showFullShield = true
            if locked { selectedMode = .now }
        }
        .alert("DEV", isPresented: $showDevAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(devAlertMessage) }
        .alert("ERROR", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage) }
        .alert("NOTICE", isPresented: $showMinDurationNotice) {
            Button("OK", role: .cancel) {}
        } message: { Text(minDurationNoticeText) }
    }

    // MARK: - 主界面（含模式切换）

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            ModePickerBar(mode: $selectedMode)
                .padding(.top, 20)
                .padding(.bottom, 8)

            switch selectedMode {
            case .now:
                nowModeContent
            case .schedule:
                ScheduleModeView(requestPaywall: { presentProPaywall() })
            case .ai:
                AIModeView(requestPaywall: { presentProPaywall() })
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FIFTEEN")
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 50)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("TIME SAVED")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.gray)
                Text(lockManager.formatTotalTime(lockManager.totalLockedSeconds))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 16)
            .padding(.horizontal, 24)
        }
    }

    // MARK: - NOW 模式（原手动锁定）

    private var nowModeContent: some View {
        if lockManager.isLocked {
            return AnyView(lockedNowContent)
        }
        return AnyView(idleNowContent)
    }

    /// NOW tab while a lock is running: the pickers and LOCK button make no
    /// sense (the manual store is busy), so show a clean countdown card instead.
    private var lockedNowContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("LOCK RUNNING")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.gray)
                Text(lockManager.formatTime(lockManager.remainingSeconds))
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let end = lockManager.lockEndDate {
                    Text("ENDS AT \(Self.endTimeFormatter.string(from: end).uppercased())")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(.gray)
                }
                Button(action: { showFullShield = true }) {
                    Text("FULLSCREEN")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
            .padding(.horizontal, 24)

            Spacer()

            Text("SCHEDULE & AI STAY AVAILABLE ABOVE")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .padding(.bottom, 30)
        }
    }

    private static let endTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private var idleNowContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Button(action: { showAppPicker = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("APPS TO BLOCK")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.gray)
                            Text(appsSelectedText)
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text(">")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 0).stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                .padding(.horizontal, 24)

                Button(action: { showDurationPicker = true }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DURATION")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.gray)
                            Text(formatDuration(selectedDuration))
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text(">")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 0).stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button(action: handleLockPress) {
                Text("LOCK")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color.white)
            }
            .padding(.horizontal, 24)
            .disabled(!hasSelectionToBlock)
            .opacity(!hasSelectionToBlock ? 0.5 : 1)

            Group {
                if storeManager.purchasedPro {
                    Text("PRO: UNLIMITED")
                } else {
                    Text("FREE LOCKS LEFT: \(storeManager.freeLocksRemaining)/\(storeManager.freeLockLimitValue)")
                }
            }
            .font(.system(size: 10, weight: .regular, design: .monospaced))
            .foregroundColor(.gray.opacity(0.7))
            .padding(.top, 10)

            Text("NO ESCAPE. NO REFUNDS.")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .padding(.top, 10)
                .padding(.bottom, 30)

            #if DEBUG
            debugControls
            #endif
        }
    }

    #if DEBUG
    private var debugControls: some View {
        VStack(spacing: 8) {
            Text("🧪 Locks: \(storeManager.completedLockCount) | Pro: \(storeManager.purchasedPro ? "Yes" : "No")")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.gray)

            HStack(spacing: 12) {
                Button(action: {
                    storeManager.simulatePurchase()
                    devAlertMessage = "✅ Pro unlocked"; showDevAlert = true
                }) { debugTag("Buy Pro", .green) }

                Button(action: {
                    storeManager.debugResetPurchase()
                    devAlertMessage = "✅ Reset to new user"; showDevAlert = true
                }) { debugTag("Reset All", .orange) }

                Button(action: {
                    storeManager.debugSetLockCompleted()
                    devAlertMessage = "✅ Set 1 lock completed\nNext lock will show Paywall"; showDevAlert = true
                }) { debugTag("Use Free", .yellow) }
            }

            HStack(spacing: 12) {
                Button(action: {
                    lockManager.debugAddTime(seconds: 900)
                    devAlertMessage = "✅ +15 min\nTotal: \(lockManager.formatTotalTime(lockManager.totalLockedSeconds))"; showDevAlert = true
                }) { debugTag("+15min", .cyan) }

                Button(action: {
                    lockManager.debugResetTime()
                    devAlertMessage = "✅ Time reset to 0"; showDevAlert = true
                }) { debugTag("Reset Time", .red) }
            }
        }
        .padding(.bottom, 10)
    }

    private func debugTag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2))
    }
    #endif

    // MARK: - Shield 界面（锁定中）

    private var shieldView: some View {
        VStack(spacing: 32) {
            Spacer()
            Text(lockManager.formatTime(lockManager.remainingSeconds))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(currentTaunt)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()

            // Quiet exit: the lock keeps running, but Schedule/AI stay reachable.
            Button(action: { showFullShield = false }) {
                Text("MANAGE SCHEDULE & AI →")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.7))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            .padding(.bottom, 16)

            Text("// NO UNLOCK BUTTON")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
                .padding(.bottom, 20)

            #if DEBUG
            Button(action: {
                AppBlocker.shared.stopBlocking()
                lockManager.debugSkipLock()
            }) {
                Text("🧪 DEV: Skip Lock")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red.opacity(0.6))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
            }
            .padding(.bottom, 20)
            #endif
        }
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in
            currentTaunt = tauntingMessages.randomElement() ?? "Stay focused."
        }
    }

    // MARK: - 时长选择器

    @State private var customDays: Int = 0
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 30
    @State private var showCustomPicker: Bool = false

    private var durationPickerSheet: some View {
        VStack(spacing: 0) {
            Text("SELECT DURATION")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.top, 24).padding(.bottom, 16)

            if !showCustomPicker {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(durationOptions.enumerated()), id: \.offset) { _, option in
                            Button(action: {
                                if option.value == -1 {
                                    showCustomPicker = true
                                } else {
                                    selectedDuration = option.value
                                    showDurationPicker = false
                                }
                            }) {
                                HStack {
                                    Text(option.label)
                                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if selectedDuration == option.value && option.value != -1 {
                                        Text("✓")
                                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                    }
                                }
                                .padding(.horizontal, 24).padding(.vertical, 16)
                            }
                        }
                        Spacer().frame(height: 16)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Text("CUSTOM DURATION")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)

                    HStack(spacing: 16) {
                        customWheel(title: "DAYS", range: 0..<30, selection: $customDays)
                        customWheel(title: "HOURS", range: 0..<24, selection: $customHours)
                        customWheel(title: "MINUTES", range: 0..<60, selection: $customMinutes)
                    }
                    .frame(maxWidth: .infinity)

                    Button(action: {
                        var totalSeconds = (customDays * 86400) + (customHours * 3600) + (customMinutes * 60)
                        guard totalSeconds > 0 else { return }
                        let minDurationSeconds = 15 * 60
                        if totalSeconds < minDurationSeconds {
                            totalSeconds = minDurationSeconds
                            minDurationNoticeText = "Minimum duration is 15 minutes.\nAdjusted to 15m."
                            showMinDurationNotice = true
                        }
                        selectedDuration = totalSeconds
                        showDurationPicker = false
                        showCustomPicker = false
                    }) {
                        Text("CONFIRM")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                    }
                    .padding(.horizontal, 24)

                    Button(action: { showCustomPicker = false }) {
                        Text("BACK")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color.black)
        .presentationDetents([.large])
    }

    private func customWheel(title: String, range: Range<Int>, selection: Binding<Int>) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.gray)
            Picker(title, selection: selection) {
                ForEach(range, id: \.self) { v in
                    Text("\(v)")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundColor(.white).tag(v)
                }
            }
            .pickerStyle(.wheel).frame(height: 150)
        }
    }

    // MARK: - 辅助方法

    private var appsSelectedText: String {
        let appCount = familyControls.selectedApps.applicationTokens.count
        let categoryCount = familyControls.selectedApps.categoryTokens.count
        let total = appCount + categoryCount
        if total == 0 { return "None selected" }
        var parts: [String] = []
        if appCount > 0 { parts.append("\(appCount) app\(appCount > 1 ? "s" : "")") }
        if categoryCount > 0 { parts.append("\(categoryCount) categor\(categoryCount > 1 ? "ies" : "y")") }
        return parts.joined(separator: " + ") + " selected"
    }

    private var hasSelectionToBlock: Bool {
        !familyControls.selectedApps.applicationTokens.isEmpty ||
        !familyControls.selectedApps.categoryTokens.isEmpty
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 && minutes > 0 { return "\(hours)h \(minutes)m" }
        else if hours > 0 { return "\(hours)h" }
        else { return "\(minutes)m" }
    }

    // MARK: - Automation refresh

    private func refreshAutomation() {
        // 清掉"锁定完成"通知留下的角标
        UNUserNotificationCenter.current().setBadgeCount(0)
        // Defensive: if no manual/AI lock is active, make sure no stale manual
        // shield lingers (e.g. from a cross-midnight or multi-day lock whose
        // process was killed before its timer could clear it).
        if !lockManager.isLocked {
            AppBlocker.shared.stopBlocking()
        }
        Automation.reconcileAll()
    }

    // MARK: - Paywall routing

    private func presentProPaywall() {
        paywallIntent = .unlockPro
        showPaywall = true
    }

    private func handlePaywallSuccess() {
        switch paywallIntent {
        case .manualLock: startLock()
        case .unlockPro: break // Feature unlocked; user can proceed.
        }
    }

    // MARK: - Manual lock flow

    private func handleLockPress() {
        guard familyControls.isAuthorized else {
            Task {
                do {
                    try await familyControls.requestAuthorization()
                    if familyControls.isAuthorized { proceedWithLock() }
                } catch {
                    errorMessage = "Screen Time access is required.\nPlease enable it in Settings > Screen Time."
                    showErrorAlert = true
                }
            }
            return
        }
        proceedWithLock()
    }

    private func proceedWithLock() {
        if storeManager.canStartLock {
            startLock()
        } else {
            paywallIntent = .manualLock
            showPaywall = true
        }
    }

    private func startLock() {
        if performLock(selection: familyControls.selectedApps, duration: selectedDuration) {
            UserDefaults.standard.set("manual", forKey: "activeLockSource")
        }
    }

    // MARK: - AI challenge flow

    private func startAIChallenge() {
        habitEngine.pendingChallenge = false
        // Never let an AI nudge hijack/reset a lock that is already running.
        guard !lockManager.isLocked else {
            errorMessage = "A lock is already running.\nIt ends at \(lockManager.lockEndDate.map { Self.endTimeFormatter.string(from: $0) } ?? "—")."
            showErrorAlert = true
            return
        }
        let sel = habitEngine.watchedSelection
        guard !SelectionStore.isEmpty(sel) else {
            selectedMode = .ai
            return
        }
        let duration = habitEngine.config.lockDurationSeconds

        // AI 模式有自己的 3 次免费试用，与手动锁的次数互相独立
        guard storeManager.canUseAI else {
            presentProPaywall()
            return
        }

        guard familyControls.isAuthorized else {
            Task {
                do {
                    try await familyControls.requestAuthorization()
                    if familyControls.isAuthorized { startAILock(selection: sel, duration: duration) }
                } catch {
                    errorMessage = "Screen Time access is required.\nPlease enable it in Settings > Screen Time."
                    showErrorAlert = true
                }
            }
            return
        }

        startAILock(selection: sel, duration: duration)
    }

    private func startAILock(selection: FamilyActivitySelection, duration: Int) {
        // 只有锁真正启动成功才消耗试用次数、打上来源标记
        if performLock(selection: selection, duration: duration) {
            storeManager.recordAIUse()
            UserDefaults.standard.set("ai", forKey: "activeLockSource")
        }
    }

    // MARK: - Shared lock starter

    @discardableResult
    private func performLock(selection: FamilyActivitySelection, duration: Int) -> Bool {
        do {
            try AppBlocker.shared.startBlocking(apps: selection, duration: TimeInterval(duration))
            lockManager.startLock(duration: duration)
            return true
        } catch {
            errorMessage = "Start lock failed:\n\(error.localizedDescription)"
            showErrorAlert = true
            print("❌ Lock start failed: \(error)")
            return false
        }
    }

    private func requestAuthorization() {
        Task {
            do {
                try await familyControls.requestAuthorization()
            } catch {
                print("❌ Authorization failed: \(error)")
            }
        }
    }
}

// MARK: - Paywall 视图

struct PaywallView: View {
    @StateObject private var storeManager = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var dismissAfterAlert = false

    var onPurchaseSuccess: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 16) {
                    Text("🎉").font(.system(size: 48))
                    Text("GO PRO")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("UNLIMITED LOCKS · SCHEDULES · AI MODE")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(spacing: 24) {
                    Text("ONE TIME. FOREVER.")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    VStack(spacing: 8) {
                        Text(storeManager.product?.displayPrice ?? "$2.99")
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("NO SUBSCRIPTION")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                Button(action: purchase) {
                    if storeManager.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .frame(maxWidth: .infinity).padding(.vertical, 20).background(Color.white)
                    } else {
                        Text("UNLOCK FOREVER")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 20).background(Color.white)
                    }
                }
                .padding(.horizontal, 24)
                .disabled(storeManager.isLoading)

                Button(action: restore) {
                    Text("RESTORE PURCHASE")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
                .padding(.top, 16)
                .disabled(storeManager.isLoading)

                Button(action: { dismiss() }) {
                    Text("MAYBE LATER")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
                .padding(.top, 12).padding(.bottom, 40)
            }
            .onAppear {
                if storeManager.product == nil {
                    Task { await storeManager.loadProducts() }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {
                    if dismissAfterAlert { dismiss() }
                }
            } message: { Text(alertMessage) }
        }
    }

    private func purchase() {
        Task {
            do {
                let success = try await storeManager.purchase()
                if success {
                    dismiss()
                    onPurchaseSuccess()
                }
            } catch {
                alertTitle = "PURCHASE FAILED"
                alertMessage = error.localizedDescription
                dismissAfterAlert = false
                showAlert = true
            }
        }
    }

    private func restore() {
        Task {
            do {
                try await storeManager.restorePurchases()
                if storeManager.purchasedPro {
                    alertTitle = "RESTORED"
                    alertMessage = "Your purchase has been restored successfully."
                    dismissAfterAlert = true
                } else {
                    alertTitle = "NOTHING TO RESTORE"
                    alertMessage = "No previous purchase was found for this Apple ID."
                    dismissAfterAlert = false
                }
                showAlert = true
            } catch {
                alertTitle = "RESTORE FAILED"
                alertMessage = error.localizedDescription
                dismissAfterAlert = false
                showAlert = true
            }
        }
    }
}

#Preview {
    ContentView()
}
