import Foundation
import IOKit
import IOKit.ps
import Metal
import PerryBrain

extension MachineProfile {
    static func current() -> MachineProfile {
        let info = ProcessInfo.processInfo
        var appleIntelligence = false
        if #available(macOS 26, *) { appleIntelligence = AppleFoundationModelProvider.isAvailable }
        return MachineProfile(
            memoryBytes: info.physicalMemory,
            workingSetBytes: MTLCreateSystemDefaultDevice().map { UInt64($0.recommendedMaxWorkingSetSize) } ?? 0,
            chip: Chip(brandString: sysctlString("machdep.cpu.brand_string") ?? ""),
            gpuCores: gpuCoreCount(),
            powerSource: onBattery() ? .battery : .ac,
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalState: info.thermalState,
            appleIntelligenceAvailable: appleIntelligence
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func gpuCoreCount() -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? Int
    }

    private static func onBattery() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String? == kIOPSBatteryPowerValue
    }
}

final class MemoryPressureMonitor {
    enum Level { case normal, warning, critical }

    private let source: DispatchSourceMemoryPressure

    init(queue: DispatchQueue = .main, handler: @escaping (Level) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [source] in
            let event = source.data
            handler(event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
