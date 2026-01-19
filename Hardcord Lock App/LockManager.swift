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
        lockEndTime = Date().addingTimeInterval(TimeInterval(duration))
        
        // 保存锁定结束时间
        UserDefaults.standard.set(lockEndTime, forKey: "lockEndTime")
        UserDefaults.standard.synchronize()
        
        // 启动显示更新计时器
        startDisplayTimer()
        
        // 安排本地通知（在锁定结束时）
        scheduleNotification(in: duration)
        
        print("🔒 锁定开始，时长: \(duration) 秒")
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
            remainingSeconds = Int(savedEndTime.timeIntervalSince(now))
            startDisplayTimer()
            print("🔒 恢复未完成的锁定，剩余: \(remainingSeconds) 秒")
        } else {
            // 锁定已结束
            endLock()
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
        
        // 计算实际锁定时间并累加
        if let endTime = lockEndTime {
            let lockedDuration = Int(endTime.timeIntervalSinceNow) * -1
            totalLockedSeconds += max(0, lockedDuration)
            UserDefaults.standard.set(totalLockedSeconds, forKey: "totalLockedSeconds")
        }
        
        isLocked = false
        remainingSeconds = 0
        lockEndTime = nil
        UserDefaults.standard.removeObject(forKey: "lockEndTime")
        UserDefaults.standard.synchronize()
        
        print("🔓 锁定结束！累计锁定: \(totalLockedSeconds) 秒")
    }
    
    // MARK: - 本地通知
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ 通知权限已授予")
            } else if let error = error {
                print("❌ 通知权限请求失败: \(error)")
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
                print("❌ 通知安排失败: \(error)")
            } else {
                print("✅ 通知已安排")
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
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        
        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
