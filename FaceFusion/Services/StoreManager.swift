//
//  StoreManager.swift
//  FaceFusion
//
//  StoreKit 2 owns the purchase state for the app.  The same product IDs are
//  used by the iOS and macOS targets so an entitlement bought on either target
//  can be recognised by the other one later.
//

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class StoreManager {
    static let shared = StoreManager()

    enum ProductID {
        static let monthly = "com.lisenhuang.morphiqo.pro.monthly"
        static let annual = "com.lisenhuang.morphiqo.pro.annual"
        static let lifetime = "com.lisenhuang.morphiqo.pro.lifetime"
    }

    /// The App Store Connect subscription group used by SubscriptionStoreView.
    static let subscriptionGroupID = "22293440"

    static let productIDs = [
        ProductID.monthly,
        ProductID.annual,
        ProductID.lifetime
    ]

    private(set) var products: [Product] = []
    private(set) var isPro = false
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    var lifetimeProduct: Product? {
        products.first { $0.id == ProductID.lifetime }
    }

    init() {
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }

        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            products = try await Product.products(for: Self.productIDs)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var active = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil,
                  Self.productIDs.contains(transaction.productID) else {
                continue
            }
            active = true
            break
        }

        isPro = active
    }

    func purchase(_ product: Product) async {
        errorMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await handle(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func listenForTransactions() async {
        for await update in Transaction.updates {
            await handle(update)
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
        await refreshEntitlements()
    }
}
