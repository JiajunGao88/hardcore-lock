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
    
    private var updateListenerTask: Task<Void, Error>?
    
    private init() {
        // 从 UserDefaults 读取购买状态
        purchasedPro = UserDefaults.standard.bool(forKey: "purchasedPro")
        
        updateListenerTask = listenForTransactions()
        Task {
            await loadProducts()
            await updatePurchaseStatus()
        }
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
        print("🧪 模拟购买成功（仅开发模式）")
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
