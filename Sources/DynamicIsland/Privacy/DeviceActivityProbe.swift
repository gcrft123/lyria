import CoreAudio
import CoreMediaIO

/// Reads whether the camera or microphone is in use *by any process* on the
/// system, via the public "is running somewhere" hardware properties.
///
/// These are pure status reads — they never open a stream, so they don't turn
/// on the camera light, capture a single frame/sample, or require any
/// camera/microphone TCC permission. Cheap enough to call on a poll timer.
enum DeviceActivityProbe {

    // MARK: Microphone (CoreAudio)

    /// True if any input-capable audio device is currently running.
    static func isMicrophoneActive() -> Bool {
        audioInputDevices().contains(where: audioDeviceIsRunning)
    }

    private static func audioInputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.filter { audioDeviceHasInput($0) && audioDeviceIsRealCapture($0) }
    }

    /// True only for genuine hardware capture devices. Excludes aggregate and
    /// tap/virtual devices — the mechanism behind system-audio taps (our own
    /// rhythm glow) and screen-recording-with-audio — which expose a running
    /// input stream that would otherwise masquerade as live microphone use and
    /// light the orange indicator for what is really just screen/system audio.
    private static func audioDeviceIsRealCapture(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr
        else { return true }   // unknown transport → don't suppress a possible real mic
        switch transport {
        case kAudioDeviceTransportTypeAggregate,
             kAudioDeviceTransportTypeVirtual:
            return false
        default:
            return true
        }
    }

    /// True if the device exposes at least one input channel, so we never
    /// mistake plain speaker playback (an output device running) for mic use.
    private static func audioDeviceHasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return false }

        let data = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, data) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            data.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func audioDeviceIsRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    // MARK: Camera (CoreMediaIO)

    /// True if any video device (camera) is currently running.
    static func isCameraActive() -> Bool {
        cameraDevices().contains(where: cameraDeviceIsRunning)
    }

    private static func cameraDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func cameraDeviceIsRunning(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var running: UInt32 = 0
        var used: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running) == noErr
        else { return false }
        return running != 0
    }
}
