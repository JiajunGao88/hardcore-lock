//
//  FamilyControlsManager.swift
//  Hardcord Lock App
//
//  Screen Time authorization, reported honestly. v3 fell back to a cached
//  "authorized" flag when the system said otherwise — so after the user revoked
//  access in Settings, the app kept writing shields that the system silently
//  ignored, and locks "worked" without blocking anything.
//

import Foundation
import FamilyControls
import ManagedSettings
import Combine

@MainActor
final class FamilyControlsManager: ObservableObject {
    static let shared = FamilyControlsManager()

    @Published private(set) var isAuthorized: Bool = false
    /// True once the system has answered at least once with approved/denied.
    @Published private(set) var hasResolvedStatus: Bool = false
    @Published var selectedApps: FamilyActivitySelection = FamilyActivitySelection() {
        // 持久化手动模式的选择，重启后不用重新选（didSet 不在 init 赋值时触发）
        didSet { SelectionStore.save(selectedApps, forKey: StoreKeys.manualSelection) }
    }

    private let center = AuthorizationCenter.shared
    private var statusSubscription: AnyCancellable?

    private init() {
        // 回读上次保存的选择（init 里赋值不触发 didSet，不会造成重复写入）
        if let saved = SelectionStore.load(forKey: StoreKeys.manualSelection) {
            selectedApps = saved
        }
        apply(center.authorizationStatus)
        // The system publishes changes (including a revoke in Settings), so the
        // UI follows reality instead of polling.
        statusSubscription = center.$authorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.apply(status) }
    }

    private func apply(_ status: AuthorizationStatus) {
        switch status {
        case .approved, .approvedWithDataAccess:
            isAuthorized = true
            hasResolvedStatus = true
        case .denied:
            isAuthorized = false
            hasResolvedStatus = true
        case .notDetermined:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }
    }

    func refreshAuthorizationStatus() {
        apply(center.authorizationStatus)
    }

    func requestAuthorization() async throws {
        try await center.requestAuthorization(for: .individual)
        apply(center.authorizationStatus)
    }
}
