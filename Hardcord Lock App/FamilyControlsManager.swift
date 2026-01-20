//
//  FamilyControlsManager.swift
//  Hardcord Lock App
//

import FamilyControls
import ManagedSettings
import Combine
import Foundation

@MainActor
final class FamilyControlsManager: ObservableObject {
    static let shared = FamilyControlsManager()
    
    @Published var isAuthorized: Bool = false
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection()
    
    private let center = AuthorizationCenter.shared
    
    // UserDefaults key for authorization state
    private let authorizationKey = "screenTimeAuthorized"
    
    private init() {
        // 先从 UserDefaults 读取缓存的授权状态
        let cachedAuth = UserDefaults.standard.bool(forKey: authorizationKey)
        
        // 然后检查实际授权状态
        checkAuthorizationStatus()
        
        // 如果之前已授权但当前检测失败（可能是 Preview 模式问题），使用缓存值
        if cachedAuth && !isAuthorized {
            // 再次验证实际状态
            if center.authorizationStatus == .approved {
                isAuthorized = true
            } else {
                // 在真机上如果之前授权过，可能只是状态读取延迟
                // 保持 cachedAuth 状态，避免频繁显示授权按钮
                isAuthorized = cachedAuth
                print("⚠️ 使用缓存的授权状态: \(cachedAuth)")
            }
        }
    }
    
    func checkAuthorizationStatus() {
        switch center.authorizationStatus {
        case .approved:
            isAuthorized = true
            // 缓存授权状态
            UserDefaults.standard.set(true, forKey: authorizationKey)
            print("✅ Screen Time 已授权")
        case .denied:
            isAuthorized = false
            UserDefaults.standard.set(false, forKey: authorizationKey)
            print("❌ Screen Time 授权被拒绝")
        case .notDetermined:
            // 只有在没有缓存的情况下才设为 false
            if !UserDefaults.standard.bool(forKey: authorizationKey) {
                isAuthorized = false
            }
            print("⏳ Screen Time 授权待确定")
        @unknown default:
            isAuthorized = false
        }
        UserDefaults.standard.synchronize()
    }
    
    func requestAuthorization() async throws {
        print("📱 请求 Screen Time 授权...")
        try await center.requestAuthorization(for: .individual)
        
        // 授权成功后更新状态
        checkAuthorizationStatus()
        
        // 确保授权状态被保存
        if center.authorizationStatus == .approved {
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: authorizationKey)
            UserDefaults.standard.synchronize()
            print("✅ Screen Time 授权成功并已缓存")
        }
    }
    
    // MARK: - 强制刷新授权状态
    func refreshAuthorizationStatus() {
        let status = center.authorizationStatus
        switch status {
        case .approved:
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: authorizationKey)
        case .denied:
            isAuthorized = false
            UserDefaults.standard.set(false, forKey: authorizationKey)
        case .notDetermined:
            // 保持当前状态
            break
        @unknown default:
            break
        }
        UserDefaults.standard.synchronize()
        print("🔄 授权状态刷新: \(status), isAuthorized: \(isAuthorized)")
    }
    
    // MARK: - 调试用：重置授权缓存
    #if DEBUG
    func debugResetAuthCache() {
        UserDefaults.standard.removeObject(forKey: authorizationKey)
        UserDefaults.standard.synchronize()
        checkAuthorizationStatus()
        print("🧪 DEBUG: 授权缓存已重置")
    }
    #endif
}
