import Foundation

public struct Chip: Equatable, Sendable {
    public enum Kind: Int, Sendable { case base, pro, max, ultra }

    public var generation: Int
    public var kind: Kind

    public init(generation: Int, kind: Kind) {
        self.generation = generation
        self.kind = kind
    }

    public init(brandString: String) {
        let words = brandString.split(separator: " ")
        guard let index = words.firstIndex(where: { $0.hasPrefix("M") && Int($0.dropFirst()) != nil }) else {
            self.init(generation: 0, kind: .base)
            return
        }
        let kind: Kind
        switch words.dropFirst(index + 1).first {
        case "Pro": kind = .pro
        case "Max": kind = .max
        case "Ultra": kind = .ultra
        default: kind = .base
        }
        self.init(generation: Int(words[index].dropFirst()) ?? 0, kind: kind)
    }
}

public struct MachineProfile: Equatable, Sendable {
    public enum PowerSource: Sendable { case ac, battery }

    public var memoryBytes: UInt64
    public var workingSetBytes: UInt64
    public var chip: Chip
    public var gpuCores: Int?
    public var powerSource: PowerSource
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState
    public var appleIntelligenceAvailable: Bool

    public init(
        memoryBytes: UInt64,
        workingSetBytes: UInt64,
        chip: Chip,
        gpuCores: Int?,
        powerSource: PowerSource,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState,
        appleIntelligenceAvailable: Bool
    ) {
        self.memoryBytes = memoryBytes
        self.workingSetBytes = workingSetBytes
        self.chip = chip
        self.gpuCores = gpuCores
        self.powerSource = powerSource
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.appleIntelligenceAvailable = appleIntelligenceAvailable
    }
}

public struct ModelRung: Equatable, Sendable {
    public var name: String
    public var quant: String
    public var downloadGB: Double
    public var activeGB: Double
    public var compactActiveGB: Double?
    public var repo: String
    public var files: [String]

    public var id: String { "\(name)-\(quant)" }
    public var warmGB: Double { downloadGB }

    init(name: String, quant: String, downloadGB: Double, activeGB: Double, compactActiveGB: Double? = nil, repo: String? = nil, files: [String]? = nil) {
        self.name = name
        self.quant = quant
        self.downloadGB = downloadGB
        self.activeGB = activeGB
        self.compactActiveGB = compactActiveGB
        self.repo = repo ?? "unsloth/\(name)-GGUF"
        self.files = files ?? ["\(name)-\(quant).gguf", "mmproj-F16.gguf"]
    }

    public static let holo31_4B_Q4KM = ModelRung(
        name: "Holo-3.1-4B", quant: "Q4_K_M", downloadGB: 3.74, activeGB: 5.9, compactActiveGB: 4.6,
        repo: "mradermacher/Holo-3.1-4B-GGUF", files: ["Holo-3.1-4B.Q4_K_M.gguf", "Holo-3.1-4B.mmproj-f16.gguf"]
    )
    public static let guiOwl15_2B_Q4KM = ModelRung(
        name: "GUI-Owl-1.5-2B", quant: "Q4_K_M", downloadGB: 1.93, activeGB: 3.0,
        repo: "mradermacher/GUI-Owl-1.5-2B-Instruct-GGUF",
        files: ["GUI-Owl-1.5-2B-Instruct.Q4_K_M.gguf", "GUI-Owl-1.5-2B-Instruct.mmproj-f16.gguf"]
    )

    public static let qwen35_0_8B_Q4KM = ModelRung(name: "Qwen3.5-0.8B", quant: "Q4_K_M", downloadGB: 0.73, activeGB: 0.73)
    public static let qwen35_2B_UDQ4KXL = ModelRung(name: "Qwen3.5-2B", quant: "UD-Q4_K_XL", downloadGB: 2.0, activeGB: 3.0)
    public static let qwen35_4B_UDQ4KXL = ModelRung(name: "Qwen3.5-4B", quant: "UD-Q4_K_XL", downloadGB: 3.6, activeGB: 5.9, compactActiveGB: 4.6)
    public static let qwen35_9B_UDQ4KXL = ModelRung(name: "Qwen3.5-9B", quant: "UD-Q4_K_XL", downloadGB: 6.9, activeGB: 9.2)
    public static let qwen35_9B_UDQ6KXL = ModelRung(name: "Qwen3.5-9B", quant: "UD-Q6_K_XL", downloadGB: 9.7, activeGB: 12.0)
    public static let qwen36_35B_UDIQ4XS = ModelRung(name: "Qwen3.6-35B-A3B", quant: "UD-IQ4_XS", downloadGB: 18.6, activeGB: 20.8)
    public static let qwen36_35B_UDQ4KXL = ModelRung(name: "Qwen3.6-35B-A3B", quant: "UD-Q4_K_XL", downloadGB: 23.3, activeGB: 25.4)
    public static let qwen36_35B_UDQ6K = ModelRung(name: "Qwen3.6-35B-A3B", quant: "UD-Q6_K", downloadGB: 30.2, activeGB: 32.3)
    public static let qwen36_35B_Q80 = ModelRung(name: "Qwen3.6-35B-A3B", quant: "Q8_0", downloadGB: 37.8, activeGB: 39.9)
    public static let qwen38_27B_UDIQ4XS = ModelRung(name: "Qwen3.8-27B", quant: "UD-IQ4_XS", downloadGB: 15.2, activeGB: 18.1)
    public static let qwen38_27B_UDQ4KXL = ModelRung(name: "Qwen3.8-27B", quant: "UD-Q4_K_XL", downloadGB: 18.5, activeGB: 21.4)
    public static let qwen38_27B_UDQ5KXL = ModelRung(name: "Qwen3.8-27B", quant: "UD-Q5_K_XL", downloadGB: 21.8, activeGB: 24.7)
    public static let qwen38_27B_UDQ6K = ModelRung(name: "Qwen3.8-27B", quant: "UD-Q6_K", downloadGB: 22.9, activeGB: 25.8)
    public static let qwen38_27B_Q80 = ModelRung(name: "Qwen3.8-27B", quant: "Q8_0", downloadGB: 30.0, activeGB: 32.9)
}

public enum MemoryBudget: CaseIterable, Sendable {
    case nothing
    case upTo2GB
    case keepMainReady
}

public enum Lane: Hashable, Sendable {
    case interactive
    case deep
    case helper
}

public enum Helper: Equatable, Sendable {
    case appleFoundationModels
    case model(ModelRung)
}

public struct Recommendation: Equatable, Sendable {
    public var interactive: ModelRung
    public var deep: ModelRung?
    public var helper: Helper
    public var resident: [Lane]
    public var idleMemoryGB: Double
}

public struct ModelOffer: Equatable, Sendable {
    public enum Size: CaseIterable, Sendable { case recommended, small }
    public enum Blocker: Equatable, Sendable {
        case memory
        case disk(neededGB: Double)
    }

    public var size: Size
    public var rung: ModelRung
    public var blocker: Blocker?
}

public enum ModelFit {
    public static let fitShare = 0.75

    public static let interactiveLadder: [ModelRung] = [
        .qwen35_2B_UDQ4KXL, .qwen35_4B_UDQ4KXL, .qwen35_9B_UDQ4KXL, .qwen35_9B_UDQ6KXL,
        .qwen36_35B_UDIQ4XS, .qwen36_35B_UDQ4KXL, .qwen36_35B_UDQ6K, .qwen36_35B_Q80,
    ]

    public static let deepLadder: [ModelRung] = [
        .qwen38_27B_UDIQ4XS, .qwen38_27B_UDQ5KXL, .qwen38_27B_UDQ6K, .qwen38_27B_Q80,
    ]

    private static let tiers = [8, 16, 24, 32, 48, 64, 96]

    public static let diskHeadroomGB = 2.0

    public static let lineup: [ModelRung] = [.holo31_4B_Q4KM, .guiOwl15_2B_Q4KM]

    public static func offers(profile: MachineProfile, freeDiskBytes: Int64) -> [ModelOffer] {
        zip(ModelOffer.Size.allCases, lineup).map { size, rung in
            let needed = rung.downloadGB + diskHeadroomGB
            let blocker: ModelOffer.Blocker? = if !fits(rung, on: profile) {
                .memory
            } else if needed * 1e9 > Double(freeDiskBytes) {
                .disk(neededGB: needed)
            } else {
                nil
            }
            return ModelOffer(size: size, rung: rung, blocker: blocker)
        }
    }

    public static func recommended(_ offers: [ModelOffer]) -> ModelOffer? {
        offers.first { $0.blocker == nil }
    }

    public static func recommend(profile: MachineProfile, budget: MemoryBudget) -> Recommendation {
        let tier = memoryTier(profile.memoryBytes)
        let isBase = profile.chip.kind == .base

        var start: Int
        switch tier {
        case 8: start = 1
        case 16: start = profile.chip.generation >= 3 ? 2 : 1
        case 24: start = 3
        case 32: start = 4
        case 48: start = 5
        case 64: start = 6
        default: start = 7
        }
        if isBase && tier >= 24 { start -= 1 }
        let interactive = stepDown(interactiveLadder, from: start, profile: profile, tier: tier) ?? interactiveLadder[0]

        var deep: ModelRung?
        if tier >= 32 && !isBase {
            deep = stepDown(deepLadder, from: tiers.firstIndex(of: tier)! - 3, profile: profile, tier: tier)
        }

        let helper: Helper = profile.appleIntelligenceAvailable ? .appleFoundationModels : .model(.qwen35_0_8B_Q4KM)
        var helperGB = 0.0
        if case .model(let model) = helper { helperGB = model.warmGB }

        var resident: [Lane] = []
        var idleMemoryGB = 0.0
        switch budget {
        case .nothing:
            break
        case .upTo2GB:
            resident = [.helper]
            idleMemoryGB = helperGB
        case .keepMainReady:
            resident = [.interactive]
            idleMemoryGB = interactive.warmGB
            if let deep, tier >= 96 {
                resident.append(.deep)
                idleMemoryGB += deep.warmGB
            }
        }

        return Recommendation(interactive: interactive, deep: deep, helper: helper, resident: resident, idleMemoryGB: idleMemoryGB)
    }

    public static func fits(_ model: ModelRung, on profile: MachineProfile) -> Bool {
        fits(model, on: profile, tier: memoryTier(profile.memoryBytes))
    }

    private static func fits(_ model: ModelRung, on profile: MachineProfile, tier: Int) -> Bool {
        let active = tier == 8 ? model.compactActiveGB ?? model.activeGB : model.activeGB
        return active * 1e9 <= fitShare * Double(profile.workingSetBytes)
    }

    private static func stepDown(_ ladder: [ModelRung], from start: Int, profile: MachineProfile, tier: Int) -> ModelRung? {
        ladder[...start].last { fits($0, on: profile, tier: tier) }
    }

    private static func memoryTier(_ bytes: UInt64) -> Int {
        let gib = Double(bytes) / Double(1 << 30)
        return tiers.last { Double($0) <= gib + 0.5 } ?? tiers[0]
    }
}
