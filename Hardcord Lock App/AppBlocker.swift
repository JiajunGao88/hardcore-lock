//
//  AppBlocker.swift
//  Hardcord Lock App
//

import DeviceActivity
import ManagedSettings
import FamilyControls
import Foundation

final class AppBlocker {
    static let shared = AppBlocker()
    
    private let center = DeviceActivityCenter()
    private let store = ManagedSettingsStore()
    
    private init() {}
    
    // MARK: - 开始屏蔽
    
    func startBlocking(apps: FamilyActivitySelection, duration: TimeInterval) throws {
        
        let minSeconds: TimeInterval = 15 * 60
        guard duration >= minSeconds else {
            throw AppBlockerError.intervalTooShort(minMinutes: 15)
        }
        
        print("🚫 开始屏蔽 Apps...")
        
        // 创建活动名称
        let activityName = DeviceActivityName("HardcoreLock")
        
        // 计算结束时间
        let now = Date()
        let endDate = now.addingTimeInterval(duration)
        
        // 创建调度
        let calendar = Calendar.current
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        let endComponents = calendar.dateComponents([.hour, .minute, .second], from: endDate)
        
        let schedule = DeviceActivitySchedule(
            intervalStart: startComponents,
            intervalEnd: endComponents,
            repeats: false
        )
        
        // 开始监控
        try center.startMonitoring(activityName, during: schedule)
        
        // 应用屏蔽
        store.shield.applications = apps.applicationTokens
        store.shield.applicationCategories = .specific(apps.categoryTokens)
        store.shield.webDomainCategories = .specific(apps.categoryTokens)
        
        print("✅ Apps 已屏蔽，持续 \(Int(duration)) 秒")
    }
    
    // MARK: - 停止屏蔽（仅供内部使用，不暴露给用户）
    
    func stopBlocking() {
        let activityName = DeviceActivityName("HardcoreLock")
        center.stopMonitoring([activityName])
        
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomainCategories = nil
        
        print("🔓 屏蔽已解除")
    }
}

enum AppBlockerError: LocalizedError {
    case intervalTooShort(minMinutes: Int)

    var errorDescription: String? {
        switch self {
        case .intervalTooShort(let minMinutes):
            return "Minimum duration is \(minMinutes) minutes."
        }
    }
}
