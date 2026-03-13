//
//  ContentView.swift
//  Hardcord Lock App
//

import SwiftUI
import FamilyControls

struct ContentView: View {
    @StateObject private var storeManager = StoreManager.shared
    @StateObject private var familyControls = FamilyControlsManager.shared
    @StateObject private var lockManager = LockManager.shared
    
    @State private var showPaywall = false
    @State private var showAppPicker = false
    @State private var showDurationPicker = false
    @State private var selectedDuration: Int = 900 // 15分钟
    @State private var showDevAlert = false
    @State private var devAlertMessage = ""
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var showMinDurationNotice = false
    @State private var minDurationNoticeText = ""

    // 嘲讽文案
    private let tauntingMessages = [
        "Don't be weak.",
        "Touch grass.",
        "Stay focused.",
        "No escape.",
        "You chose this.",
        "Embrace the void.",
        "Discipline is freedom.",
        "The phone can wait.",
        "Be present.",
        "Resist the urge.",
        "You're stronger than this.",
        "Focus on what matters.",
        "Time is precious.",
        "Break the addiction.",
        "Control yourself.",
        "This too shall pass.",
        "Breathe.",
        "Stay hard.",
        "No excuses.",
        "Commit."
    ]
    
    @State private var currentTaunt: String = "Stay focused."
    
    // 时长选项（包含 OTHER）
    private let durationOptions: [(label: String, value: Int)] = [
        ("15m", 900),
        ("30m", 1800),
        ("1h", 3600),
        ("3h", 10800),
        ("6h", 21600),
        ("12h", 43200),
        ("OTHER", -1)  // -1 表示自定义
    ]
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if lockManager.isLocked {
                shieldView
            } else {
                mainContent
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(onPurchaseSuccess: startLock)
        }
        .familyActivityPicker(
            isPresented: $showAppPicker,
            selection: $familyControls.selectedApps
        )
        .sheet(isPresented: $showDurationPicker) {
            durationPickerSheet
                .onDisappear {
                    // 每次关闭 sheet 时复位，避免下次直接停留在自定义页
                    showCustomPicker = false
                }
        }
        .onAppear {
            currentTaunt = tauntingMessages.randomElement() ?? "Stay focused."
            familyControls.refreshAuthorizationStatus()
            if !familyControls.isAuthorized {
                requestAuthorization()
            }
        }
        .alert("DEV", isPresented: $showDevAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(devAlertMessage)
        }
        .alert("ERROR", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("NOTICE", isPresented: $showMinDurationNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(minDurationNoticeText)
        }
    }
    
    // MARK: - 主界面
    
    private var mainContent: some View {
        VStack(spacing: 0) {
            // 顶部标题
            VStack(alignment: .leading, spacing: 0) {
                Text("FIFTEEN")
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 60)
            .padding(.horizontal, 24)
            
            // 累计锁定时间 - 显示为小时数
            VStack(alignment: .leading, spacing: 4) {
                Text("TIME SAVED")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(.gray)
                Text(lockManager.formatTotalTime(lockManager.totalLockedSeconds))
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 32)
            .padding(.horizontal, 24)
            
            Spacer()
            
            // 选择区域
            VStack(spacing: 16) {
                // 选择 Apps
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
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)
                
                // 选择时长
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
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)
            }
            
            Spacer()
            
            // LOCK 按钮
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

            // 免费次数提示（极简、等宽、灰）
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
            
            // 底部文案
            Text("NO ESCAPE. NO REFUNDS.")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
                .padding(.top, 10)
                .padding(.bottom, 40)
            
            
            #if DEBUG
            // Debug 按钮组
            VStack(spacing: 8) {
                Text("🧪 Locks: \(storeManager.completedLockCount) | Pro: \(storeManager.purchasedPro ? "Yes" : "No")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                
                HStack(spacing: 12) {
                    Button(action: {
                        storeManager.simulatePurchase()
                        devAlertMessage = "✅ Pro unlocked"
                        showDevAlert = true
                    }) {
                        Text("Buy Pro")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                    }
                    
                    Button(action: {
                        storeManager.debugResetPurchase()
                        devAlertMessage = "✅ Reset to new user"
                        showDevAlert = true
                    }) {
                        Text("Reset All")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                    }
                    
                    Button(action: {
                        storeManager.debugSetLockCompleted()
                        devAlertMessage = "✅ Set 1 lock completed\nNext lock will show Paywall"
                        showDevAlert = true
                    }) {
                        Text("Use Free")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.yellow.opacity(0.2))
                    }
                }
                
                HStack(spacing: 12) {
                    Button(action: {
                        lockManager.debugAddTime(seconds: 900)
                        devAlertMessage = "✅ +15 min\nTotal: \(lockManager.formatTotalTime(lockManager.totalLockedSeconds))"
                        showDevAlert = true
                    }) {
                        Text("+15min")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.2))
                    }
                    
                    Button(action: {
                        lockManager.debugResetTime()
                        devAlertMessage = "✅ Time reset to 0"
                        showDevAlert = true
                    }) {
                        Text("Reset Time")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.2))
                    }
                }
            }
            .padding(.bottom, 10)
            #endif
        }
    }
    
    // MARK: - Shield 界面（锁定中）
    
    private var shieldView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // 倒计时 - 使用较小字体确保长时间也能显示在一行
            Text(lockManager.formatTime(lockManager.remainingSeconds))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            
            // 嘲讽文案
            Text(currentTaunt)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
            
            // 无解锁按钮 - 这是故意的
            Text("// NO UNLOCK BUTTON")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundColor(.gray.opacity(0.3))
                .padding(.bottom, 20)
            
            #if DEBUG
            // DEV 专用跳过按钮
            Button(action: {
                AppBlocker.shared.stopBlocking()
                lockManager.debugSkipLock()
            }) {
                Text("🧪 DEV: Skip Lock")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
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
            // 标题
            Text("SELECT DURATION")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.top, 24)
                .padding(.bottom, 16)
            
            if !showCustomPicker {
                // 预设选项：ScrollView 撑满高度，确保可滚动到 OTHER
                ScrollView {
                    VStack(spacing: 0) {
                        // 用 enumerated + index 做唯一 id，避免未来 value 重复导致行消失
                        ForEach(Array(durationOptions.enumerated()), id: \.offset) { _, option in
                            Button(action: {
                                if option.value == -1 {
                                    // 点击 OTHER，显示自定义选择器
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
                                .padding(.horizontal, 24)
                                .padding(.vertical, 16)
                            }
                        }
                        
                        // 给底部留一点空间，避免最后一行贴边（不会影响滚动）
                        Spacer().frame(height: 16)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                // 自定义滚轴选择器
                VStack(spacing: 16) {
                    Text("CUSTOM DURATION")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    
                    HStack(spacing: 16) {
                        // 天数
                        VStack(spacing: 8) {
                            Text("DAYS")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Picker("Days", selection: $customDays) {
                                ForEach(0..<30, id: \.self) { day in
                                    Text("\(day)")
                                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .tag(day)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 120)
                        }
                        
                        // 小时
                        VStack(spacing: 8) {
                            Text("HOURS")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Picker("Hours", selection: $customHours) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text("\(hour)")
                                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .tag(hour)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 120)
                        }
                        
                        // 分钟
                        VStack(spacing: 8) {
                            Text("MINUTES")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Picker("Minutes", selection: $customMinutes) {
                                ForEach(0..<60, id: \.self) { minute in
                                    Text("\(minute)")
                                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white)
                                        .tag(minute)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(height: 120)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    // 确认按钮
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
                    
                    // 返回按钮
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
    
    // MARK: - 辅助方法
    
    private var appsSelectedText: String {
        let appCount = familyControls.selectedApps.applicationTokens.count
        let categoryCount = familyControls.selectedApps.categoryTokens.count
        // 如果你后面也支持网站选择，再加上：
        // let domainCount = familyControls.selectedApps.webDomainTokens.count

        let total = appCount + categoryCount
        if total == 0 {
            return "None selected"
        }

        var parts: [String] = []
        if appCount > 0 {
            parts.append("\(appCount) app\(appCount > 1 ? "s" : "")")
        }
        if categoryCount > 0 {
            parts.append("\(categoryCount) categor\(categoryCount > 1 ? "ies" : "y")")
        }
        // if domainCount > 0 { parts.append("\(domainCount) domain\(domainCount > 1 ? "s" : "")") }

        return parts.joined(separator: " + ") + " selected"
    }
    
    private var hasSelectionToBlock: Bool {
        !familyControls.selectedApps.applicationTokens.isEmpty ||
        !familyControls.selectedApps.categoryTokens.isEmpty
        // 如果你未来也支持 web domain，可再加：
        // || !familyControls.selectedApps.webDomainTokens.isEmpty
    }
    
    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        
        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        } else if hours > 0 {
            return "\(hours)h"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func handleLockPress() {
        guard familyControls.isAuthorized else {
            Task {
                do {
                    try await familyControls.requestAuthorization()
                    if familyControls.isAuthorized {
                        proceedWithLock()
                    }
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
            showPaywall = true
        }
    }
    
    private func startLock() {
        do {
            try AppBlocker.shared.startBlocking(
                apps: familyControls.selectedApps,
                duration: TimeInterval(selectedDuration)
            )
            lockManager.startLock(duration: selectedDuration)
        } catch {
            errorMessage = "Start lock failed:\n\(error.localizedDescription)"
            showErrorAlert = true
            print("❌ Lock start failed: \(error)")
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
                    Text("🎉")
                        .font(.system(size: 48))
                    
                    Text("CONGRATS!")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text("YOU SURVIVED YOUR FIRST LOCK")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                VStack(spacing: 24) {
                    Text("NOW KEEP IT GOING.")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    VStack(spacing: 8) {
                        Text(storeManager.product?.displayPrice ?? "$2.99")
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        
                        Text("ONCE. FOREVER.")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
                
                Button(action: purchase) {
                    if storeManager.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color.white)
                    } else {
                        Text("UNLOCK FOREVER")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(Color.white)
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
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .onAppear {
                if storeManager.product == nil {
                    Task {
                        await storeManager.loadProducts()
                    }
                }
            }
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {
                    if dismissAfterAlert {
                        dismiss()
                    }
                }
            } message: {
                Text(alertMessage)
            }
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
                    showAlert = true
                }
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
