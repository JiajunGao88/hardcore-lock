//
//  LockManager.swift
//  Hardcord Lock App
//

import Foundation
import Combine
import UserNotifications

@MainActor
final class LockManager: ObservableObject {
    static let shared = LockManager()
    
    @Published var isLocked: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var totalLockedSeconds: Int = 0
    
    private var timer: Timer?
    private var lockEndTime: Date?
    private var lockStartTime: Date?  // 新增：记录锁定开始时间
    private var displayUpdateTimer: Timer?
    
    private init() {
        // 从 UserDefaults 读取累计锁定时间
        totalLockedSeconds = UserDefaults.standard.integer(forKey: "totalLockedSeconds")
        
        // 检查是否有未完成的锁定
        checkPendingLock()
        
        // 请求通知权限
        requestNotificationPermission()
    }
    
    // MARK: - 开始锁定
    
    func startLock(duration: Int) {
        isLocked = true
        remainingSeconds = duration
        lockStartTime = Date()  // 记录开始时间
        lockEndTime = Date().addingTimeInterval(TimeInterval(duration))
        
        // 保存锁定开始和结束时间
        UserDefaults.standard.set(lockStartTime, forKey: "lockStartTime")
        UserDefaults.standard.set(lockEndTime, forKey: "lockEndTime")
        UserDefaults.standard.synchronize()
        
        // 启动显示更新计时器
        startDisplayTimer()
        
        // 安排本地通知（在锁定结束时）
        scheduleNotification(in: duration)
        
        print("🔒 Lock started, duration: \(duration) seconds")
    }
    
    // MARK: - 检查未完成的锁定
    
    private func checkPendingLock() {
        guard let savedEndTime = UserDefaults.standard.object(forKey: "lockEndTime") as? Date else {
            return
        }
        
        let now = Date()
        if savedEndTime > now {
            // 锁定仍在进行中
            isLocked = true
            lockEndTime = savedEndTime
            lockStartTime = UserDefaults.standard.object(forKey: "lockStartTime") as? Date
            remainingSeconds = Int(savedEndTime.timeIntervalSince(now))
            startDisplayTimer()
            print("🔒 Resuming lock, remaining: \(remainingSeconds) seconds")
        } else {
            // 锁定已结束，计算并累加时间
            if let savedStartTime = UserDefaults.standard.object(forKey: "lockStartTime") as? Date {
                let lockedDuration = Int(savedEndTime.timeIntervalSince(savedStartTime))
                if lockedDuration > 0 {
                    totalLockedSeconds += lockedDuration
                    UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
                    print("🔓 Detected completed lock, added time: \(lockedDuration) seconds")

                    // 记录完成一次锁定（用于免费试用计数）
                    Task { @MainActor in
                        StoreManager.shared.recordCompletedLock()
                    }
                }
            }
            // 解除可能残留的屏蔽（处理跨天/多天锁在进程被杀后扩展未能清除的情况）
            AppBlocker.shared.stopBlocking()
            // 清理锁定状态
            clearLockState()
        }
    }
    
    // MARK: - 显示更新计时器（每秒更新 UI）
    
    private func startDisplayTimer() {
        displayUpdateTimer?.invalidate()
        displayUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateDisplay()
            }
        }
    }
    
    private func updateDisplay() {
        guard let endTime = lockEndTime else {
            endLock()
            return
        }
        
        let now = Date()
        let remaining = Int(endTime.timeIntervalSince(now))
        
        if remaining > 0 {
            remainingSeconds = remaining
        } else {
            endLock()
        }
    }
    
    // MARK: - 结束锁定
    
    private func endLock() {
        displayUpdateTimer?.invalidate()
        displayUpdateTimer = nil

        // 立即解除屏蔽（前台结束时不依赖扩展的 intervalDidEnd，后者可能延迟）
        AppBlocker.shared.stopBlocking()

        // 计算实际锁定时间并累加
        if let startTime = lockStartTime, let endTime = lockEndTime {
            // 使用开始时间和结束时间计算实际锁定时长
            let lockedDuration = Int(endTime.timeIntervalSince(startTime))
            if lockedDuration > 0 {
                totalLockedSeconds += lockedDuration
                UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
                print("✅ Lock duration: \(lockedDuration) seconds, total: \(totalLockedSeconds) seconds")
                
                // 记录完成一次锁定（用于免费试用计数）
                Task { @MainActor in
                    StoreManager.shared.recordCompletedLock()
                }
            }
        }
        
        isLocked = false
        remainingSeconds = 0
        clearLockState()
        
        print("🔓 Lock ended! Total: \(totalLockedSeconds) seconds (\(formatTotalTime(totalLockedSeconds)))")
    }
    
    // MARK: - 清理锁定状态
    
    private func clearLockState() {
        lockEndTime = nil
        lockStartTime = nil
        UserDefaults.standard.removeObject(forKey: "lockEndTime")
        UserDefaults.standard.removeObject(forKey: "lockStartTime")
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - 本地通知
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            } else if let error = error {
                print("❌ Notification permission failed: \(error)")
            }
        }
    }
    
    private func scheduleNotification(in seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = "LOCK COMPLETE"
        content.body = "Your focus session has ended."
        content.sound = .default
        content.badge = NSNumber(value: 1)
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: "lockComplete", content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Notification scheduling failed: \(error)")
            } else {
                print("✅ Notification scheduled")
            }
        }
    }
    
    // MARK: - 格式化时间
    
    func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    func formatTotalTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return "\(minutes)m"
    }
    
    // MARK: - Debug functions (development only)
    #if DEBUG
    func debugAddTime(seconds: Int) {
        totalLockedSeconds += seconds
        UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
        print("🧪 DEBUG: Added \(seconds) seconds, total: \(totalLockedSeconds) seconds")
    }
    
    func debugResetTime() {
        totalLockedSeconds = 0
        UserDefaults.standard.set(0, forKey: "totalLockedSeconds")
        print("🧪 DEBUG: Reset total time to 0")
    }
    
    func debugSkipLock() {
        displayUpdateTimer?.invalidate()
        displayUpdateTimer = nil

        // 跳过锁定也要立即解除屏蔽，否则应用会一直锁到原定结束时间
        AppBlocker.shared.stopBlocking()

        // Calculate locked time and add to total
        if let startTime = lockStartTime {
            let lockedDuration = Int(Date().timeIntervalSince(startTime))
            if lockedDuration > 0 {
                totalLockedSeconds += lockedDuration
                UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
                print("🧪 DEBUG: This lock \(lockedDuration) seconds, total: \(totalLockedSeconds) seconds")
            }
        }
        
        // Record completed lock
        Task { @MainActor in
            StoreManager.shared.recordCompletedLock()
        }
        
        isLocked = false
        remainingSeconds = 0
        clearLockState()
        
        print("🧪 DEBUG: Lock skipped")
    }
    #endif
}
