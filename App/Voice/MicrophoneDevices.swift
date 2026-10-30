import AudioToolbox
import AVFoundation
import CoreAudio

struct DictationInputDevice: Equatable, Identifiable, Sendable {
    let id: UInt32
    let name: String
    let isBuiltIn: Bool
}

enum MicrophoneDeviceSelector {
    static func select(on input: AVAudioInputNode, deviceID: AudioDeviceID? = nil) -> Bool {
        guard let audioUnit = input.audioUnit,
              let selectedDeviceID = deviceID ?? preferredDeviceID() else { return false }
        var selectedDevice = selectedDeviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedDevice,
            size
        ) == noErr
    }

    static func inputDevices() -> [AudioDeviceID] {
        let devices = allDevices()
        return devices.filter { inputChannelCount(for: $0) > 0 }
    }

    static func name(for deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
              let value else { return "" }
        return value.takeUnretainedValue() as String
    }

    static func isBuiltIn(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("built-in") || lowered.contains("internal") || lowered.contains("macbook")
    }

    static func preferredDeviceID() -> AudioDeviceID? {
        let devices = inputDevices()
        return devices.first { isBuiltIn(name: name(for: $0)) }
            ?? devices.first
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return 0 }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(pointer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }
}
