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
    @State private var confirmLock = false
    @State private var showDevAlert = false
    @State private var devAlertMessage = ""
    @State private var errorMessage: String?
    /// Fullscreen countdown is the default face of an active lock; the user can
    /// step out to manage Schedule/AI and come back. Reset when a lock starts.
    @State private var showFullShield = true
    /// Snapshot of AppGroup.isConfigured (a filesystem call) taken on foreground.
    @State private var appGroupOK = true
    @State private var preventUninstall = HardcoreSettings.preventUninstall
    /// Bumped when a lock starts — drives the heavy haptic.
    @State private var lockStartedCount = 0

    enum PaywallIntent {
        case manualLock
        case unlockPro
        /// The user accepted an AI nudge but had no trials left. Carry the
        /// request through the paywall so buying Pro actually starts the lock
        /// they asked for — the nudge is the only AI entry point, so dropping it
        /// would leave a paying user with no way to get their lock.
        case aiChallenge(FamilyActivitySelection, Int)
    }

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

    private let durationPresets: [(label: String, value: Int)] = [
        ("15m", 900), ("30m", 1800), ("1h", 3600),
        ("3h", 10800), ("6h", 21600), ("12h", 43200)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if lockManager.isLocked && showFullShield {
                shieldView
                    .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: lockManager.isLocked && showFullShield)
        // Every system control (sheets, alerts, menus, wheels, the app picker)
        // must render dark: in light mode they showed white-on-white.
        .preferredColorScheme(.dark)
        .tint(.white)
        .sensoryFeedback(.impact(weight: .heavy), trigger: lockStartedCount)
        .sheet(isPresented: $showPaywall) {
            PaywallView(onPurchaseSuccess: handlePaywallSuccess)
        }
        .familyActivityPicker(
            isPresented: $showAppPicker,
            selection: $familyControls.selectedApps
        )
        .sheet(isPresented: $showDurationPicker) {
            DurationPickerSheet(selectedDuration: $selectedDuration, presets: durationPresets)
        }
        .confirmationDialog(lockConfirmTitle, isPresented: $confirmLock, titleVisibility: .visible) {
            Button("LOCK NOW", role: .destructive, action: proceedWithLock)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends around \(UIFormat.time.string(from: Date().addingTimeInterval(TimeInterval(selectedDuration)))). There is no unlock button.")
        }
        .onAppear {
            currentTaunt = tauntingMessages.randomElement() ?? "Stay focused."
            // Ask once on first launch. After a denial, the banner explains and
            // offers to ask again — no surprise prompts on every launch.
            if !familyControls.hasResolvedStatus { requestAuthorization() }
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
        .alert("ERROR", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Main screen (with mode switch)

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            healthBanners
            ModePickerBar(mode: $selectedMode)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Group {
                switch selectedMode {
                case .now:
                    if lockManager.isLocked { lockedNowContent } else { idleNowContent }
                case .schedule:
                    ScheduleModeView(requestPaywall: { presentProPaywall() })
                case .ai:
                    AIModeView(requestPaywall: { presentProPaywall() })
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("FIFTEEN")
                .font(Theme.mono(30, .bold))
                .foregroundColor(.white)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TIME SAVED")
                    .font(Theme.mono(10, .medium))
                    .foregroundColor(Theme.secondary)
                Text(UIFormat.duration(lockManager.totalLockedSeconds))
                    .font(Theme.mono(20, .bold))
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.top, 12)
        .padding(.horizontal, Theme.gutter)
    }

    /// Problems that make blocking silently not work, said out loud.
    @ViewBuilder
    private var healthBanners: some View {
        let authProblem = familyControls.hasResolvedStatus && !familyControls.isAuthorized
        if authProblem || !appGroupOK {
            VStack(spacing: 8) {
                if authProblem {
                    NoticeBanner(
                        text: lockManager.isLocked
                            ? "SCREEN TIME ACCESS WAS TURNED OFF. Your lock is no longer being enforced."
                            : "Screen Time access is off — nothing can be blocked until you allow it.",
                        isError: true,
                        actionTitle: "ALLOW"
                    ) { requestAuthorization() }
                }
                if !appGroupOK {
                    NoticeBanner(text: "Setup problem: the App Group isn't configured, so schedules and AI can't run in the background.",
                                 isError: true)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 12)
        }
    }

    // MARK: - NOW mode

    /// NOW tab while a lock is running: the pickers and LOCK button make no
    /// sense (the manual store is busy), so show a clean countdown card instead.
    private var lockedNowContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 14) {
                Text("LOCK RUNNING")
                    .font(Theme.mono(11, .medium))
                    .foregroundColor(Theme.secondary)
                countdownText(size: 44)
                ProgressBar(value: lockProgress)
                    .padding(.horizontal, 32)
                if let end = lockManager.lockEndDate {
                    Text("ENDS AT \(UIFormat.time.string(from: end).uppercased())")
                        .font(Theme.mono(12))
                        .foregroundColor(Theme.secondary)
                }
                Button { showFullShield = true } label: {
                    Text("FULLSCREEN")
                        .font(Theme.mono(11, .bold))
                        .foregroundColor(Theme.secondary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 40)
                }
                .buttonStyle(OutlineButtonStyle())
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .padding(.horizontal, Theme.gutter)

            Spacer()

            Text("SCHEDULE & AI STAY AVAILABLE ABOVE")
                .font(Theme.mono(10))
                .foregroundColor(Theme.tertiary)
                .padding(.bottom, 24)
        }
    }

    private var idleNowContent: some View {
        ScrollView {
            VStack(spacing: 12) {
                Button { showAppPicker = true } label: {
                    PickerRow(label: "APPS TO BLOCK", value: appsSelectedText, placeholder: !hasSelectionToBlock)
                }
                .buttonStyle(OutlineButtonStyle())

                Button { showDurationPicker = true } label: {
                    PickerRow(label: "DURATION", value: UIFormat.duration(selectedDuration))
                }
                .buttonStyle(OutlineButtonStyle())

                uninstallRow

                #if DEBUG
                debugControls
                #endif
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) { lockBar }
    }

    private var lockBar: some View {
        VStack(spacing: 8) {
            Button("LOCK") { confirmLock = true }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!hasSelectionToBlock)

            Group {
                if !hasSelectionToBlock {
                    Text("PICK APPS TO BLOCK FIRST")
                } else if storeManager.purchasedPro {
                    Text("PRO · UNLIMITED")
                } else {
                    Text("FREE LOCKS LEFT: \(storeManager.freeLocksRemaining)/\(storeManager.freeLockLimitValue)")
                }
            }
            .font(Theme.mono(10))
            .foregroundColor(Theme.tertiary)

            Text("NO ESCAPE. NO REFUNDS.")
                .font(Theme.mono(10))
                .foregroundColor(Theme.tertiary.opacity(0.7))
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.black)
    }

    /// Any schedule blocking right now? Then deletion protection can't be
    /// switched off — its store would drop it on the next reconcile.
    private var anyScheduleBlocking: Bool {
        scheduleManager.schedules.contains { scheduleManager.status($0) == .blocking }
    }

    private var uninstallRow: some View {
        OutlineRow {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BLOCK APP DELETION")
                        .font(Theme.mono(13, .bold))
                        .foregroundColor(.white)
                    Text(anyScheduleBlocking && preventUninstall
                         ? "Locked on while a schedule is blocking."
                         : "While a block is on, no app can be deleted — not even FIFTEEN.")
                        .font(Theme.mono(11))
                        .foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Block app deletion", isOn: Binding(
                    get: { preventUninstall },
                    set: { value in
                        // Enforced here too, not only via .disabled: accessibility
                        // actions can still reach a disabled control.
                        guard value || !anyScheduleBlocking else { return }
                        HardcoreSettings.preventUninstall = value
                        preventUninstall = value
                    }
                ))
                .labelsHidden()
                .toggleStyle(BrutalToggleStyle())
                .disabled(anyScheduleBlocking && preventUninstall)
            }
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
                    devAlertMessage = "✅ Set 3 locks completed\nNext lock will show Paywall"; showDevAlert = true
                }) { debugTag("Use Free", .yellow) }
            }

            HStack(spacing: 12) {
                Button(action: {
                    lockManager.debugAddTime(seconds: 900)
                    devAlertMessage = "✅ +15 min"; showDevAlert = true
                }) { debugTag("+15min", .cyan) }

                Button(action: {
                    lockManager.debugResetTime()
                    devAlertMessage = "✅ Time reset to 0"; showDevAlert = true
                }) { debugTag("Reset Time", .red) }
            }

            if let beat = Heartbeat.last {
                Text("ext: \(beat.event) @ \(UIFormat.time.string(from: beat.at))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .padding(.top, 8)
    }

    private func debugTag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.2))
    }
    #endif

    // MARK: - Shield (fullscreen, while locked)

    private var lockProgress: Double {
        guard lockManager.lockDuration > 0 else { return 0 }
        return 1 - Double(lockManager.remainingSeconds) / Double(lockManager.lockDuration)
    }

    private func countdownText(size: CGFloat) -> some View {
        Text(lockManager.formatTime(lockManager.remainingSeconds))
            .font(Theme.mono(size, .bold))
            .foregroundColor(.white)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
            .animation(.easeOut(duration: 0.2), value: lockManager.remainingSeconds)
            .accessibilityLabel("Time remaining \(UIFormat.duration(lockManager.remainingSeconds))")
    }

    private var shieldView: some View {
        VStack(spacing: 0) {
            Spacer()

            countdownText(size: 56)
                .padding(.horizontal, Theme.gutter)

            ProgressBar(value: lockProgress)
                .frame(width: 200)
                .padding(.top, 20)

            if let end = lockManager.lockEndDate {
                Text("ENDS AT \(UIFormat.time.string(from: end).uppercased())")
                    .font(Theme.mono(12))
                    .foregroundColor(Theme.tertiary)
                    .padding(.top, 12)
            }

            Text(currentTaunt)
                .font(Theme.mono(16, .medium))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .id(currentTaunt)
                .transition(.opacity)

            Spacer()

            // Quiet exit: the lock keeps running, but Schedule/AI stay reachable.
            Button { showFullShield = false } label: {
                Text("MANAGE SCHEDULE & AI →")
                    .font(Theme.mono(11, .medium))
                    .foregroundColor(Theme.secondary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
            }
            .buttonStyle(OutlineButtonStyle())
            .padding(.bottom, 16)

            Text("// NO UNLOCK BUTTON")
                .font(Theme.mono(10))
                .foregroundColor(Theme.tertiary.opacity(0.6))
                .padding(.bottom, 20)

            #if DEBUG
            Button(action: { lockManager.debugSkipLock() }) {
                Text("🧪 DEV: Skip Lock")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red.opacity(0.6))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.red.opacity(0.1))
            }
            .padding(.bottom, 20)
            #endif
        }
        .onReceive(AppClock.everyTenSeconds) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                currentTaunt = tauntingMessages.randomElement() ?? "Stay focused."
            }
        }
    }

    // MARK: - Helpers

    /// "2 apps + 1 category" — the selection without the word "selected".
    private var selectionSummary: String {
        let s = familyControls.selectedApps
        let apps = s.applicationTokens.count
        let cats = s.categoryTokens.count
        let webs = s.webDomainTokens.count
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps > 1 ? "s" : "")") }
        if cats > 0 { parts.append("\(cats) categor\(cats > 1 ? "ies" : "y")") }
        if webs > 0 { parts.append("\(webs) site\(webs > 1 ? "s" : "")") }
        return parts.joined(separator: " + ")
    }

    private var appsSelectedText: String {
        hasSelectionToBlock ? selectionSummary : "None selected"
    }

    private var hasSelectionToBlock: Bool {
        !SelectionStore.isEmpty(familyControls.selectedApps)
    }

    private var lockConfirmTitle: String {
        "Lock \(selectionSummary) for \(UIFormat.duration(selectedDuration))?"
    }

    // MARK: - Automation refresh

    private func refreshAutomation() {
        // 清掉"锁定完成"通知留下的角标
        UNUserNotificationCenter.current().setBadgeCount(0)
        familyControls.refreshAuthorizationStatus()
        appGroupOK = AppGroup.isConfigured
        // Finish (credit + unshield) a lock that ended while we were away. The
        // tamper-resistant clock decides — a moved system clock doesn't count.
        lockManager.refresh()
        // Defensive: no lock on record → no manual shield should linger (e.g. a
        // pre-v4 lock whose process was killed before it could clear itself).
        if ManualLockStore.load() == nil {
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
        // Feature unlocked — re-run automation so schedules/AI that the trial
        // gates were holding back take effect without waiting for a foreground.
        case .unlockPro: refreshAutomation()
        case .aiChallenge(let selection, let duration):
            refreshAutomation()
            startAILock(selection: selection, duration: duration)
        }
    }

    // MARK: - Manual lock flow

    /// Runs after the user confirms the lock dialog.
    private func proceedWithLock() {
        guard familyControls.isAuthorized else {
            Task {
                do {
                    try await familyControls.requestAuthorization()
                    if familyControls.isAuthorized { proceedWithLock() }
                } catch {
                    errorMessage = "Screen Time access is required.\nEnable it in Settings > Screen Time."
                }
            }
            return
        }
        if storeManager.canStartLock {
            startLock()
        } else {
            paywallIntent = .manualLock
            showPaywall = true
        }
    }

    private func startLock() {
        performLock(selection: familyControls.selectedApps, duration: selectedDuration, source: "manual")
    }

    // MARK: - AI challenge flow

    private func startAIChallenge() {
        // Self-guarding: onAppear and the scenePhase handler can both see the
        // same pending request, and only the first may act on it.
        guard habitEngine.pendingChallenge else { return }
        habitEngine.pendingChallenge = false
        // Never let an AI nudge hijack/reset a lock that is already running.
        guard !lockManager.isLocked else {
            errorMessage = "A lock is already running.\nIt ends at \(lockManager.lockEndDate.map { UIFormat.time.string(from: $0) } ?? "—")."
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
            // Carry the request through the paywall (see PaywallIntent) instead
            // of dropping it: pendingChallenge is already consumed by now.
            paywallIntent = .aiChallenge(sel, duration)
            showPaywall = true
            return
        }

        guard familyControls.isAuthorized else {
            Task {
                do {
                    try await familyControls.requestAuthorization()
                    if familyControls.isAuthorized { startAILock(selection: sel, duration: duration) }
                } catch {
                    errorMessage = "Screen Time access is required.\nEnable it in Settings > Screen Time."
                }
            }
            return
        }

        startAILock(selection: sel, duration: duration)
    }

    private func startAILock(selection: FamilyActivitySelection, duration: Int) {
        // 只有锁真正启动成功才消耗试用次数
        if performLock(selection: selection, duration: duration, source: "ai") {
            storeManager.recordAIUse()
        }
    }

    // MARK: - Shared lock starter

    @discardableResult
    private func performLock(selection: FamilyActivitySelection, duration: Int, source: String) -> Bool {
        do {
            let record = try AppBlocker.shared.startBlocking(apps: selection, duration: TimeInterval(duration), source: source)
            lockManager.startLock(record)
            showFullShield = true
            lockStartedCount += 1
            return true
        } catch {
            errorMessage = "Couldn't start the lock:\n\(error.localizedDescription)"
            return false
        }
    }

    private func requestAuthorization() {
        Task {
            do {
                try await familyControls.requestAuthorization()
            } catch {
                errorMessage = "Screen Time access is required.\nEnable it in Settings > Screen Time."
            }
        }
    }
}

// MARK: - Duration picker

private struct DurationPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDuration: Int
    let presets: [(label: String, value: Int)]

    @State private var showCustom = false
    @State private var detent: PresentationDetent = .medium
    @State private var customDays = 0
    @State private var customHours = 0
    @State private var customMinutes = 30

    private static let minSeconds = 15 * 60

    private var customSeconds: Int { customDays * 86_400 + customHours * 3600 + customMinutes * 60 }
    private var isCustomSelected: Bool { !presets.contains { $0.value == selectedDuration } }

    var body: some View {
        NavigationStack {
            Group {
                if showCustom { customPicker } else { presetGrid }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(showCustom ? "CUSTOM DURATION" : "DURATION")
                        .font(Theme.mono(15, .bold))
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(showCustom ? "BACK" : "CLOSE") {
                        if showCustom {
                            withAnimation { showCustom = false }
                            detent = .medium
                        } else {
                            dismiss()
                        }
                    }
                    .font(Theme.mono(13, .medium))
                    .foregroundColor(Theme.secondary)
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
    }

    private var presetGrid: some View {
        ScrollView {
            VStack(spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(presets, id: \.value) { option in
                        let selected = selectedDuration == option.value
                        Button {
                            selectedDuration = option.value
                            dismiss()
                        } label: {
                            Text(option.label)
                                .font(Theme.mono(20, .bold))
                                .foregroundColor(selected ? .black : .white)
                                .frame(maxWidth: .infinity, minHeight: 64)
                                .background(selected ? Color.white : Color.clear)
                        }
                        .buttonStyle(OutlineButtonStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }

                Button {
                    withAnimation { showCustom = true }
                    detent = .large
                } label: {
                    Text(isCustomSelected ? "CUSTOM · \(UIFormat.duration(selectedDuration).uppercased())" : "CUSTOM…")
                        .font(Theme.mono(15, .bold))
                        .foregroundColor(isCustomSelected ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(isCustomSelected ? Color.white : Color.clear)
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(Theme.gutter)
        }
    }

    private var customPicker: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                wheel(title: "DAYS", range: 0..<30, selection: $customDays)
                wheel(title: "HOURS", range: 0..<24, selection: $customHours)
                wheel(title: "MIN", range: 0..<60, selection: $customMinutes)
            }
            .frame(maxWidth: .infinity)

            // Said inline, not in an alert: an alert fired while the sheet
            // dismisses attaches to a view that is going away and never shows.
            Text(customSeconds < Self.minSeconds
                 ? "MINIMUM IS 15 MINUTES"
                 : "= \(UIFormat.duration(customSeconds).uppercased())")
                .font(Theme.mono(13, .medium))
                .foregroundColor(customSeconds < Self.minSeconds ? Theme.warning : Theme.secondary)

            Button("CONFIRM") {
                selectedDuration = customSeconds
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(customSeconds < Self.minSeconds)
        }
        .padding(Theme.gutter)
    }

    private func wheel(title: String, range: Range<Int>, selection: Binding<Int>) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Theme.mono(11, .medium))
                .foregroundColor(Theme.secondary)
            Picker(title, selection: selection) {
                ForEach(range, id: \.self) { v in
                    Text("\(v)")
                        .font(Theme.mono(22, .medium))
                        .foregroundColor(.white)
                        .tag(v)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 150)
            .clipped()
        }
    }
}

// MARK: - Paywall

struct PaywallView: View {
    @StateObject private var storeManager = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var dismissAfterAlert = false

    var onPurchaseSuccess: () -> Void

    private let features = [
        "UNLIMITED NOW LOCKS",
        "AUTOMATIC SCHEDULES",
        "AI PREDICT & PREVENT",
        "EVERY FUTURE UPDATE"
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 20) {
                    Text("FIFTEEN PRO")
                        .font(Theme.mono(30, .bold))
                        .foregroundColor(.white)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(features, id: \.self) { feature in
                            HStack(spacing: 12) {
                                Rectangle().fill(Color.white).frame(width: 8, height: 8)
                                Text(feature)
                                    .font(Theme.mono(14, .medium))
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter)

                Spacer()

                VStack(spacing: 6) {
                    Group {
                        if let price = storeManager.product?.displayPrice {
                            Text(price)
                                .font(Theme.mono(48, .bold))
                                .foregroundColor(.white)
                        } else {
                            ProgressView().tint(.white).frame(height: 57)
                        }
                    }
                    Text("ONE TIME · NO SUBSCRIPTION")
                        .font(Theme.mono(11, .medium))
                        .foregroundColor(Theme.secondary)
                }

                Spacer()

                Button(action: purchase) {
                    if storeManager.isLoading {
                        ProgressView().tint(.black)
                    } else {
                        Text("UNLOCK FOREVER")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(storeManager.isLoading)
                .padding(.horizontal, Theme.gutter)

                HStack(spacing: 24) {
                    Button("RESTORE PURCHASE", action: restore)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(storeManager.isLoading)
                    Button("MAYBE LATER") { dismiss() }
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
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
        .presentationBackground(Color.black)
        .presentationDragIndicator(.visible)
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
