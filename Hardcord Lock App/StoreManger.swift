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
    @Published private(set) var purchasedPro: Bool = false
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
    
    /// 记录完成一次锁定
    func recordCompletedLock() {
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
                    purchasedPro = true
                    UserDefaults.standard.set(true, forKey: "purchasedPro")
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
        print("🧪 Simulated purchase (debug mode only)")
    }
    
    func debugResetPurchase() {
        purchasedPro = false
        completedLockCount = 0
        UserDefaults.standard.set(false, forKey: "purchasedPro")
        UserDefaults.standard.set(0, forKey: "completedLockCount")
        UserDefaults.standard.synchronize()
        print("🧪 Purchase and lock count reset (debug mode only)")
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
