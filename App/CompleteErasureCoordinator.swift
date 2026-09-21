import Foundation

enum PerryErasureCategory: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case tasks
    case history
    case memory
    case approvals
    case preferences
    case providerKeychain
    case oauthState
    case routines
    case temporaryMedia
    case caches
    case cuaArtifacts

    static var keychain: Self { .providerKeychain }
    static var oauth: Self { .oauthState }
    static var tempMedia: Self { .temporaryMedia }
    static var cua: Self { .cuaArtifacts }
}

struct PerryErasureItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    let category: PerryErasureCategory
    let identifier: String

    init(category: PerryErasureCategory, identifier: String) {
        self.category = category
        self.identifier = identifier
    }

    var id: String {
        "\(category.rawValue):\(identifier)"
    }
}

enum PerryErasureOperation: String, Codable, Equatable, Hashable, Sendable {
    case inventory
    case erase
}

struct PerryErasureFailure: Codable, Equatable, Hashable, Sendable, LocalizedError {
    let category: PerryErasureCategory
    let operation: PerryErasureOperation
    let reason: String

    var errorDescription: String? {
        "\(operation.rawValue.capitalized) failed for \(category.rawValue): \(reason)"
    }
}

struct PerryErasureAdapterError: Error, Equatable, Sendable, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

protocol PerryDataEraser: Sendable {
    var category: PerryErasureCategory { get }
    func inventory() async throws -> [PerryErasureItem]
    func erase() async throws
}

protocol PerryOwnedDataSweeper: Sendable {
    func inventory() async throws -> [String]
    func erase() async throws
}

struct PerryOwnedDataSweepFailure: Equatable, Sendable, LocalizedError {
    let operation: PerryErasureOperation
    let reason: String

    var errorDescription: String? {
        "\(operation.rawValue.capitalized) failed for Perry-owned storage: \(reason)"
    }
}

struct PerryClosureEraser: PerryDataEraser {
    let category: PerryErasureCategory
    private let inventoryOperation: @Sendable () async throws -> [PerryErasureItem]
    private let eraseOperation: @Sendable () async throws -> Void

    init(
        category: PerryErasureCategory,
        inventory: @escaping @Sendable () async throws -> [PerryErasureItem],
        erase: @escaping @Sendable () async throws -> Void
    ) {
        self.category = category
        inventoryOperation = inventory
        eraseOperation = erase
    }

    func inventory() async throws -> [PerryErasureItem] {
        try await inventoryOperation()
    }

    func erase() async throws {
        try await eraseOperation()
    }
}

struct PerryErasureInventory: Equatable, Sendable {
    let items: [PerryErasureItem]
    let failures: [PerryErasureFailure]

    init(
        items: [PerryErasureItem] = [],
        failures: [PerryErasureFailure] = []
    ) {
        self.items = Array(Set(items)).sorted { $0.id < $1.id }
        self.failures = Array(Set(failures)).sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            if $0.operation.rawValue != $1.operation.rawValue {
                return $0.operation.rawValue < $1.operation.rawValue
            }
            return $0.reason < $1.reason
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var isReliable: Bool { failures.isEmpty }
    var hasResidualItems: Bool { !items.isEmpty }

    func items(in category: PerryErasureCategory) -> [PerryErasureItem] {
        items.filter { $0.category == category }
    }

    subscript(category: PerryErasureCategory) -> [PerryErasureItem] {
        items(in: category)
    }
}

enum PerryErasureStatus: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

struct PerryErasureReport: Equatable, Sendable {
    let requestedCategories: Set<PerryErasureCategory>
    let preEraseInventory: PerryErasureInventory
    let postEraseInventory: PerryErasureInventory
    let failures: [PerryErasureFailure]
    let residualOwnedPaths: [String]
    let ownedDataFailures: [PerryOwnedDataSweepFailure]

    var residualItems: [PerryErasureItem] {
        postEraseInventory.items.filter { requestedCategories.contains($0.category) }
    }

    var allResidualItems: [PerryErasureItem] {
        postEraseInventory.items
    }

    var hasResidualItems: Bool {
        !allResidualItems.isEmpty
    }

    var isSuccessful: Bool {
        failures.isEmpty && ownedDataFailures.isEmpty && residualItems.isEmpty && residualOwnedPaths.isEmpty
    }

    var success: Bool {
        isSuccessful
    }

    var isComplete: Bool {
        failures.isEmpty && ownedDataFailures.isEmpty && postEraseInventory.items.isEmpty && residualOwnedPaths.isEmpty
    }

    var status: PerryErasureStatus {
        isComplete ? .complete : .partial
    }

    var summary: String {
        if isComplete {
            return "Perry data was erased."
        }
        if !residualItems.isEmpty {
            return "Perry data erasure is incomplete: \(residualItems.count) requested item\(residualItems.count == 1 ? "" : "s") remain."
        }
        if !failures.isEmpty {
            return "Perry data erasure is incomplete: \(failures.count) operation\(failures.count == 1 ? "" : "s") failed."
        }
        if !ownedDataFailures.isEmpty {
            return "Perry data erasure is incomplete: Perry could not verify all owned storage."
        }
        if !residualOwnedPaths.isEmpty {
            return "Perry data erasure is incomplete: \(residualOwnedPaths.count) owned storage path\(residualOwnedPaths.count == 1 ? "" : "s") remain."
        }
        if hasResidualItems {
            return "The requested Perry data was erased; other categories still contain data."
        }
        return "The requested Perry data was erased."
    }
}

actor CompleteErasureCoordinator {
    static let allCategories = Set(PerryErasureCategory.allCases)

    private let erasers: [PerryErasureCategory: any PerryDataEraser]
    private let ownedDataSweeper: (any PerryOwnedDataSweeper)?

    init(
        erasers: [any PerryDataEraser],
        ownedDataSweeper: (any PerryOwnedDataSweeper)? = nil
    ) {
        var indexed: [PerryErasureCategory: any PerryDataEraser] = [:]
        for eraser in erasers {
            precondition(indexed[eraser.category] == nil, "one eraser is required per Perry erasure category")
            indexed[eraser.category] = eraser
        }
        self.erasers = indexed
        self.ownedDataSweeper = ownedDataSweeper
    }

    func inventory() async -> PerryErasureInventory {
        await inventory(categories: Set(erasers.keys))
    }

    func inventory(categories: Set<PerryErasureCategory>) async -> PerryErasureInventory {
        await collectInventory(for: categories)
    }

    func erase() async -> PerryErasureReport {
        await erase(categories: Self.allCategories)
    }

    func erase(category: PerryErasureCategory) async -> PerryErasureReport {
        await erase(categories: [category])
    }

    func erase(_ categories: Set<PerryErasureCategory>) async -> PerryErasureReport {
        await erase(categories: categories)
    }

    func erase(categories: Set<PerryErasureCategory>) async -> PerryErasureReport {
        let preEraseInventory = await collectInventory(for: Set(erasers.keys))
        var failures = preEraseInventory.failures
        var ownedDataFailures: [PerryOwnedDataSweepFailure] = []

        for category in PerryErasureCategory.allCases where categories.contains(category) {
            guard let eraser = erasers[category] else {
                failures.append(
                    PerryErasureFailure(
                        category: category,
                        operation: .erase,
                        reason: "no eraser is registered"
                    )
                )
                continue
            }
            do {
                try await eraser.erase()
            } catch {
                failures.append(
                    PerryErasureFailure(
                        category: category,
                        operation: .erase,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        let isCompleteErasure = categories == Self.allCategories
        if isCompleteErasure, let ownedDataSweeper {
            do {
                try await ownedDataSweeper.erase()
            } catch {
                ownedDataFailures.append(
                    PerryOwnedDataSweepFailure(operation: .erase, reason: error.localizedDescription)
                )
            }
        }

        let postEraseInventory = await collectInventory(for: Set(erasers.keys))
        failures.append(contentsOf: postEraseInventory.failures)
        var residualOwnedPaths: [String] = []
        if isCompleteErasure, let ownedDataSweeper {
            do {
                residualOwnedPaths = try await ownedDataSweeper.inventory()
            } catch {
                ownedDataFailures.append(
                    PerryOwnedDataSweepFailure(operation: .inventory, reason: error.localizedDescription)
                )
            }
        }
        return PerryErasureReport(
            requestedCategories: categories,
            preEraseInventory: preEraseInventory,
            postEraseInventory: postEraseInventory,
            failures: failures,
            residualOwnedPaths: residualOwnedPaths,
            ownedDataFailures: ownedDataFailures
        )
    }

    private func collectInventory(for categories: Set<PerryErasureCategory>) async -> PerryErasureInventory {
        var items: [PerryErasureItem] = []
        var failures: [PerryErasureFailure] = []
        for category in PerryErasureCategory.allCases where categories.contains(category) {
            guard let eraser = erasers[category] else { continue }
            do {
                items.append(contentsOf: try await eraser.inventory())
            } catch {
                failures.append(
                    PerryErasureFailure(
                        category: category,
                        operation: .inventory,
                        reason: error.localizedDescription
                    )
                )
            }
        }
        return PerryErasureInventory(items: items, failures: failures)
    }
}
