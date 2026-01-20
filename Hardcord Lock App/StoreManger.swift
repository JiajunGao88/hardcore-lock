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
    private let freeLockLimit = 1
    
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
        print("🔒 已完成锁定次数: \(completedLockCount)")
    }
    
    deinit {
        updateListenerTask?.cancel()
    }
    
    // MARK: - 加载产品
    
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [productId])
            product = products.first
            print("✅ 产品加载成功: \(product?.displayName ?? "无")")
        } catch {
            print("❌ 产品加载失败: \(error)")
        }
    }
    
    // MARK: - 购买
    
    func purchase() async throws -> Bool {
        guard let product = product else {
            print("❌ 产品未找到")
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
            print("✅ 购买成功!")
            return true
            
        case .userCancelled:
            print("⚠️ 用户取消购买")
            return false
            
        case .pending:
            print("⏳ 购买待处理")
            return false
            
        @unknown default:
            return false
        }
    }
    
    // MARK: - 恢复购买
    
    func restorePurchases() async throws {
        isLoading = true
        defer { isLoading = false }
        
        try await AppStore.sync()
        await updatePurchaseStatus()
        print("✅ 恢复购买完成")
    }
    
    // MARK: - 检查购买状态
    
    func updatePurchaseStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if transaction.productID == productId {
                    purchasedPro = true
                    UserDefaults.standard.set(true, forKey: "purchasedPro")
                    print("✅ Pro 已购买")
                    return
                }
            }
        }
        // 如果没有找到有效购买，但本地有记录，保持状态
        // 这样即使离线也能使用
    }
    
    // MARK: - 开发测试用：模拟购买
    
    #if DEBUG
    func simulatePurchase() {
        purchasedPro = true
        UserDefaults.standard.set(true, forKey: "purchasedPro")
        UserDefaults.standard.synchronize()
        print("🧪 模拟购买成功（仅开发模式）")
    }
    
    func debugResetPurchase() {
        purchasedPro = false
        completedLockCount = 0
        UserDefaults.standard.set(false, forKey: "purchasedPro")
        UserDefaults.standard.set(0, forKey: "completedLockCount")
        UserDefaults.standard.synchronize()
        print("🧪 购买状态和锁定次数已重置（仅开发模式）")
    }
    
    func debugSetLockCompleted() {
        completedLockCount = 1
        UserDefaults.standard.set(1, forKey: "completedLockCount")
        UserDefaults.standard.synchronize()
        print("🧪 已设置为完成1次锁定（仅开发模式）")
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
            return "产品未找到"
        case .verificationFailed:
            return "验证失败"
        }
    }
}
