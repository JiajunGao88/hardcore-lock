//
//  FamilyControlsManager.swift
//  Hardcord Lock App
//

import FamilyControls
import ManagedSettings
import Combine

@MainActor
final class FamilyControlsManager: ObservableObject {
    static let shared = FamilyControlsManager()
    
    @Published var isAuthorized: Bool = false
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection()
    
    private let center = AuthorizationCenter.shared
    
    private init() {
        checkAuthorizationStatus()
    }
    
    func checkAuthorizationStatus() {
        switch center.authorizationStatus {
        case .approved:
            isAuthorized = true
            print("✅ Screen Time 已授权")
        case .denied:
            isAuthorized = false
            print("❌ Screen Time 授权被拒绝")
        case .notDetermined:
            isAuthorized = false
            print("⏳ Screen Time 授权待确定")
        @unknown default:
            isAuthorized = false
        }
    }
    
    func requestAuthorization() async throws {
        print("📱 请求 Screen Time 授权...")
        try await center.requestAuthorization(for: .individual)
        checkAuthorizationStatus()
    }
}
