//
//  FamilyControlsManager.swift
//  Hardcord Lock App
//

import Foundation
import FamilyControls
import ManagedSettings
import Combine

@MainActor
final class FamilyControlsManager: ObservableObject {
    static let shared = FamilyControlsManager()
    
    @Published var isAuthorized: Bool = false
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection()
    
    private let center = AuthorizationCenter.shared
    
    // UserDefaults key for authorization state
    private let authorizationKey = "screenTimeAuthorized"
    
    private init() {
        // Read cached authorization state from UserDefaults first
        let cachedAuth = UserDefaults.standard.bool(forKey: authorizationKey)
        
        // Then check actual authorization status
        checkAuthorizationStatus()
        
        // If previously authorized but current check fails (possibly Preview mode issue), use cached value
        if cachedAuth && !isAuthorized {
            // Verify actual status again
            if center.authorizationStatus == .approved {
                isAuthorized = true
            } else {
                // On real device, if previously authorized, might just be delayed status read
                // Keep cached status to avoid frequent authorization button display
                isAuthorized = cachedAuth
                print("⚠️ Using cached authorization status: \(cachedAuth)")
            }
        }
    }
    
    func checkAuthorizationStatus() {
        switch center.authorizationStatus {
        case .approved, .approvedWithDataAccess:
            isAuthorized = true
            // Cache authorization status
            UserDefaults.standard.set(true, forKey: authorizationKey)
            print("✅ Screen Time authorized")
        case .denied:
            isAuthorized = false
            UserDefaults.standard.set(false, forKey: authorizationKey)
            print("❌ Screen Time authorization denied")
        case .notDetermined:
            // Only set to false if no cache exists
            if !UserDefaults.standard.bool(forKey: authorizationKey) {
                isAuthorized = false
            }
            print("⏳ Screen Time authorization pending")
        @unknown default:
            isAuthorized = false
        }
        UserDefaults.standard.synchronize()
    }
    
    func requestAuthorization() async throws {
        print("📱 Requesting Screen Time authorization...")
        try await center.requestAuthorization(for: .individual)
        
        // Update status after authorization
        checkAuthorizationStatus()
        
        // Ensure authorization status is saved
        if center.authorizationStatus == .approved {
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: authorizationKey)
            UserDefaults.standard.synchronize()
            print("✅ Screen Time authorized and cached")
        }
    }
    
    // MARK: - Force refresh authorization status
    func refreshAuthorizationStatus() {
        let status = center.authorizationStatus
        switch status {
        case .approved, .approvedWithDataAccess:
            isAuthorized = true
            UserDefaults.standard.set(true, forKey: authorizationKey)
        case .denied:
            isAuthorized = false
            UserDefaults.standard.set(false, forKey: authorizationKey)
        case .notDetermined:
            // Keep current status
            break
        @unknown default:
            break
        }
        UserDefaults.standard.synchronize()
        print("🔄 Authorization status refreshed: \(status), isAuthorized: \(isAuthorized)")
    }
    
    // MARK: - Debug: Reset authorization cache
    #if DEBUG
    func debugResetAuthCache() {
        UserDefaults.standard.removeObject(forKey: authorizationKey)
        UserDefaults.standard.synchronize()
        checkAuthorizationStatus()
        print("🧪 DEBUG: Authorization cache reset")
    }
    #endif
}
