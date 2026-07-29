//
//  StoreManager.swift
//  Hardcord Lock App
//

import StoreKit

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()
    
    // 产品 ID - 需要在 App Store Connect 中创建
    private let productId = "com.hardcorelock.pro"
    
    @Published private(set) var product: Product?
    @Published private(set) var purchasedPro: Bool = false {
        didSet { TrialGate.setPro(purchasedPro) } // mirror to App Group for the monitor extension
    }
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var completedLockCount: Int = 0
    
    // 免费锁定次数
    private let freeLockLimit = 3

    var freeLockLimitValue: Int { freeLockLimit }
    
    var freeLocksRemaining: Int {
        max(0, freeLockLimit - completedLockCount)
    }
    
    private var updateListenerTask: Task<Void, Error>?
    
    private init() {
        // 从 UserDefaults 读取购买状态和锁定次数
        purchasedPro = UserDefaults.standard.bool(forKey: "purchasedPro")
        completedLockCount = UserDefaults.standard.integer(forKey: "completedLockCount")
        // didSet 在 init 赋值时不触发，手动镜像一次，保证扩展进程离线也能识别 Pro
        TrialGate.setPro(purchasedPro)
        
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await updatePurchaseStatus()
        }
    }
    
    // MARK: - 免费试用检查
    
    /// 是否还有免费锁定次数
    var hasFreeLockRemaining: Bool {
        return completedLockCount < freeLockLimit
    }
    
    /// 是否可以开始新的锁定（已购买或还有免费次数）
    var canStartLock: Bool {
        return purchasedPro || hasFreeLockRemaining
    }
    
    // MARK: - Schedule / AI 试用（每模式各 3 次，计数在 App Group，见 TrialGate）

    var scheduleTrialsRemaining: Int { TrialGate.scheduleUsesRemaining }
    var aiTrialsRemaining: Int { TrialGate.aiUsesRemaining }
    var canUseSchedule: Bool { purchasedPro || scheduleTrialsRemaining > 0 }
    var canUseAI: Bool { purchasedPro || aiTrialsRemaining > 0 }

    /// AI 挑战锁开始时消耗一次 AI 试用（Schedule 的消耗在监控扩展里,窗口真正触发时计）
    func recordAIUse() {
        guard !purchasedPro else { return }
        TrialGate.recordAIUse()
        objectWillChange.send()
    }

    /// 记录完成一次锁定
    func recordCompletedLock() {
        // AI 挑战锁在开始时已消耗 AI 试用，不占用手动（NOW）免费次数
        if UserDefaults.standard.string(forKey: "activeLockSource") == "ai" {
            UserDefaults.standard.removeObject(forKey: "activeLockSource")
            return
        }
        completedLockCount += 1
        UserDefaults.standard.set(completedLockCount, forKey: "completedLockCount")
        UserDefaults.standard.synchronize()
        print("🔒 Completed locks: \(completedLockCount)")
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    // MARK: - Load products
    
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [productId])
            product = products.first
            print("✅ Product loaded: \(product?.displayName ?? "none")")
        } catch {
            print("❌ Product load failed: \(error)")
        }
    }
    
    // MARK: - Purchase
    
    func purchase() async throws -> Bool {
        // 商品可能在启动时加载失败（网络波动、协议刚生效等），购买前重试一次
        if product == nil {
            await loadProducts()
        }
        guard let product = product else {
            print("❌ Product not found")
            throw StoreError.productNotFound
        }
        
        isLoading = true
        defer { isLoading = false }
        
        let result = try await product.purchase()
        
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await updatePurchaseStatus()
            print("✅ Purchase successful!")
            return true
            
        case .userCancelled:
            print("⚠️ User cancelled purchase")
            return false
            
        case .pending:
            print("⏳ Purchase pending")
            return false
            
        @unknown default:
            return false
        }
    }
    
    // MARK: - Restore purchases
    
    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        
        try await AppStore.sync()
        await updatePurchaseStatus()
        print("✅ Restore purchase completed")
    }
    
    // MARK: - Check purchase status
    
    func updatePurchaseStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == productId {
                    let wasPro = purchasedPro
                    purchasedPro = true
                    UserDefaults.standard.set(true, forKey: "purchasedPro")
                    // Becoming Pro lifts the trial gates, but nothing re-applies
                    // the shields those gates were suppressing — reconcile so an
                    // open schedule window starts blocking immediately.
                    if !wasPro { Automation.reconcileAll() }
                    print("✅ Pro purchased")
                    return
                }
            }
        }
        // If no valid purchase found but local record exists, keep status
        // This allows offline usage
    }
    
    // MARK: - Debug functions (development only)
    
    #if DEBUG
    func simulatePurchase() {
        purchasedPro = true
        UserDefaults.standard.set(true, forKey: "purchasedPro")
        UserDefaults.standard.synchronize()
        Automation.reconcileAll()
        print("🧪 Simulated purchase (debug mode only)")
    }
    
    func debugResetPurchase() {
        purchasedPro = false
        completedLockCount = 0
        UserDefaults.standard.set(false, forKey: "purchasedPro")
        UserDefaults.standard.set(0, forKey: "completedLockCount")
        AppGroup.defaults.removeObject(forKey: StoreKeys.scheduleTrialCount)
        AppGroup.defaults.removeObject(forKey: StoreKeys.aiTrialCount)
        UserDefaults.standard.synchronize()
        print("🧪 Purchase, lock count and mode trials reset (debug mode only)")
    }
    
    func debugSetLockCompleted() {
        completedLockCount = 3
        UserDefaults.standard.set(3, forKey: "completedLockCount")
        UserDefaults.standard.synchronize()
        print("🧪 Set to 3 completed locks (debug mode only)")
    }
    #endif
    
    // MARK: - 交易监听
    
    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.updatePurchaseStatus()
                }
            }
        }
    }
    
    // MARK: - 验证
    
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.verificationFailed
        case .verified(let safe):
            return safe
        }
    }
}

enum StoreError: Error, LocalizedError {
    case productNotFound
    case verificationFailed
    
    var errorDescription: String? {
        switch self {
        case .productNotFound:
            return "Product not found"
        case .verificationFailed:
            return "Verification failed"
        }
    }
}
