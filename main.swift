import CoreAudio
import Foundation
import os

// EarPods USB-C enumerate at hardware volume 1.0, and CoreAudio's device id
// changes on every reconnect. The stable key is the USB-audio UID, which
// embeds the serial number. This agent restores only that output device.

private let preferenceSuite = "com.earpods-volume"
private let logSubsystem = "com.earpods-volume"
private let earPodsModelUID = "EarPods :05AC:110B"
private let earPodsManufacturer = "Apple, Inc."
private let earPodsUIDPrefix = "AppleUSBAudioEngine:Apple, Inc.:EarPods:"
private let virtualMainVolumeSelector: AudioObjectPropertySelector = 0x766D7663 // 'vmvc'
private let volumeEpsilon: Float = 0.005
private let readbackEpsilon: Float = 0.02
private let restoreDelay: TimeInterval = 0.45
private let postRestoreSettle: TimeInterval = 0.75
private let observeOnlySettle: TimeInterval = 1.2
private let readyRetryDelay: TimeInterval = 0.4
private let maxAutomaticReapplies = 2

func formatVolume(_ value: Float) -> String {
    var text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    while text.hasSuffix("0"), text.contains(".") {
        text.removeLast()
    }
    if text.hasSuffix(".") {
        text.append("0")
    }
    return text
}

func approximatelyEqual(_ lhs: Float, _ rhs: Float, epsilon: Float = volumeEpsilon) -> Bool {
    abs(lhs - rhs) <= epsilon
}

func hardwareNudge(forTest volume: Float) -> Float {
    CoreAudioDevices.hardwareNudge(for: volume)
}

func isAutomaticMaximum(_ volume: Float) -> Bool {
    volume >= 0.999
}

func isEarPodsOutputUID(_ uid: String) -> Bool {
    guard uid.hasPrefix(earPodsUIDPrefix) else { return false }
    let rest = uid.dropFirst(earPodsUIDPrefix.count)
    guard let colon = rest.lastIndex(of: ":") else { return false }
    let serial = rest[..<colon]
    let stream = rest[rest.index(after: colon)...]
    return !serial.isEmpty && stream == "1"
}

func isEarPodsOutput(
    transport: UInt32,
    modelUID: String,
    manufacturer: String,
    deviceUID: String,
    virtualVolumeSettable: Bool
) -> Bool {
    virtualVolumeSettable
        && transport == kAudioDeviceTransportTypeUSB
        && modelUID == earPodsModelUID
        && manufacturer == earPodsManufacturer
        && isEarPodsOutputUID(deviceUID)
}

protocol VolumeStoring: AnyObject {
    func volume(for uid: String) -> Float?
    func setVolume(_ volume: Float, for uid: String)
}

final class MemoryVolumeStore: VolumeStoring, @unchecked Sendable {
    var values: [String: Float] = [:]

    func volume(for uid: String) -> Float? {
        values[uid]
    }

    func setVolume(_ volume: Float, for uid: String) {
        values[uid] = min(1, max(0, volume))
    }
}

final class UserDefaultsVolumeStore: VolumeStoring, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func volume(for uid: String) -> Float? {
        guard defaults.object(forKey: uid) != nil else { return nil }
        return defaults.float(forKey: uid)
    }

    func setVolume(_ volume: Float, for uid: String) {
        defaults.set(Double(min(1, max(0, volume))), forKey: uid)
        defaults.synchronize()
    }
}

enum Appearance {
    case hotplug
    case alreadyPresent
}

enum TimerPhase {
    case restore
    case finish
}

struct Apply {
    enum Kind {
        case restore
        case reapply
    }

    var kind: Kind
    var volume: Float
}

struct ScheduledTimer {
    var phase: TimerPhase
    var delay: TimeInterval
}

struct Effect {
    var logs: [String] = []
    var apply: Apply?
    var schedule: ScheduledTimer?
    var cancelTimer = false
}

final class EarPodsVolumePolicy: @unchecked Sendable {
    private let store: VolumeStoring
    private var sessions: [String: Session] = [:]
    private var hardwareSuppress: [String: [Float]] = [:]
    private var hardwareSuppressDeadline: [String: Date] = [:]

    init(store: VolumeStoring) {
        self.store = store
    }

    func volume(for uid: String) -> Float? {
        store.volume(for: uid)
    }

    func armHardwareSuppress(uid: String, volumes: [Float]) {
        var values = hardwareSuppress[uid] ?? []
        values.append(contentsOf: volumes)
        hardwareSuppress[uid] = values
        hardwareSuppressDeadline[uid] = Date().addingTimeInterval(2)
    }

    func appeared(uid: String, volume: Float, appearance: Appearance) -> Effect {
        var effect = Effect()
        let storedValue = store.volume(for: uid)
        effect.logs.append("EarPods connected")
        effect.logs.append("EarPods UID: \(uid)")
        effect.logs.append("Current system volume: \(formatVolume(volume))")
        effect.logs.append("Stored user volume: \(storedValue.map(formatVolume) ?? "none")")

        let storedIsUserMaximum = storedValue.map(isAutomaticMaximum) ?? false
        let automaticMax = isAutomaticMaximum(volume) && !storedIsUserMaximum
        if appearance == .alreadyPresent && !isAutomaticMaximum(volume) {
            if storedValue == nil || !approximatelyEqual(storedValue ?? volume, volume) {
                if let storedValue, !approximatelyEqual(storedValue, volume) {
                    effect.logs.append(
                        "EarPods user volume changed: \(formatVolume(storedValue)) → \(formatVolume(volume))"
                    )
                }
                store.setVolume(volume, for: uid)
                effect.logs.append("Saved user volume: \(formatVolume(volume))")
            }
            sessions[uid] = nil
            return effect
        }

        if automaticMax {
            effect.logs.append("EarPods automatic initialization volume: 1.0")
        }

        sessions[uid] = Session(
            connectVolume: volume,
            latestVolume: volume,
            settling: true,
            reapplies: 0,
            suppressValue: nil,
            storedAtConnect: storedValue,
            didRestore: false,
            didLogAutomatic: automaticMax
        )

        if storedValue != nil {
            effect.schedule = ScheduledTimer(phase: .restore, delay: restoreDelay)
        } else {
            effect.schedule = ScheduledTimer(phase: .finish, delay: observeOnlySettle)
        }
        return effect
    }

    func volumeChanged(uid: String, volume: Float) -> Effect {
        if isHardwareSuppressed(uid: uid, volume: volume) {
            return Effect()
        }
        guard var session = sessions[uid] else {
            return saveUserChange(uid: uid, volume: volume, previous: store.volume(for: uid))
        }
        session.latestVolume = volume

        if let suppress = session.suppressValue, approximatelyEqual(suppress, volume) {
            session.suppressValue = nil
            sessions[uid] = session
            return Effect()
        }

        if session.settling {
            if isAutomaticMaximum(volume),
               let target = session.storedAtConnect,
               !isAutomaticMaximum(target) {
                var effect = Effect()
                if !session.didLogAutomatic {
                    effect.logs.append("EarPods automatic initialization volume: 1.0")
                    session.didLogAutomatic = true
                } else if session.didRestore {
                    effect.logs.append("EarPods automatic initialization volume: 1.0")
                }
                if session.didRestore, session.reapplies < maxAutomaticReapplies {
                    session.reapplies += 1
                    session.suppressValue = target
                    effect.apply = Apply(kind: .reapply, volume: target)
                }
                sessions[uid] = session
                return effect
            }

            if session.storedAtConnect == nil,
               !approximatelyEqual(volume, session.connectVolume),
               !isAutomaticMaximum(volume) {
                session.settling = false
                sessions[uid] = session
                var effect = saveUserChange(uid: uid, volume: volume, previous: session.connectVolume)
                effect.cancelTimer = true
                return effect
            }

            sessions[uid] = session
            return Effect()
        }

        sessions[uid] = session
        return saveUserChange(
            uid: uid,
            volume: volume,
            previous: store.volume(for: uid) ?? session.connectVolume
        )
    }

    func restorePhase(uid: String) -> Effect {
        guard var session = sessions[uid], session.settling, !session.didRestore else { return Effect() }
        guard let target = store.volume(for: uid) ?? session.storedAtConnect else { return Effect() }
        session.didRestore = true
        session.suppressValue = target
        sessions[uid] = session
        return Effect(
            apply: Apply(kind: .restore, volume: target),
            schedule: ScheduledTimer(phase: .finish, delay: postRestoreSettle)
        )
    }

    func restoreFailed(uid: String) {
        guard var session = sessions[uid] else { return }
        session.didRestore = false
        session.suppressValue = nil
        sessions[uid] = session
    }

    func finishPhase(uid: String) -> Effect {
        guard var session = sessions[uid], session.settling else { return Effect() }
        session.settling = false
        session.suppressValue = nil
        sessions[uid] = session
        if store.volume(for: uid) == nil, !isAutomaticMaximum(session.latestVolume) {
            return saveUserChange(uid: uid, volume: session.latestVolume, previous: nil)
        }
        return Effect()
    }

    func disappeared(uid: String) {
        sessions[uid] = nil
        hardwareSuppress[uid] = nil
        hardwareSuppressDeadline[uid] = nil
    }

    private func isHardwareSuppressed(uid: String, volume: Float) -> Bool {
        guard let deadline = hardwareSuppressDeadline[uid], deadline > Date() else {
            hardwareSuppress[uid] = nil
            hardwareSuppressDeadline[uid] = nil
            return false
        }
        return hardwareSuppress[uid]?.contains { approximatelyEqual($0, volume) } == true
    }

    private func saveUserChange(uid: String, volume: Float, previous: Float?) -> Effect {
        if let previous, approximatelyEqual(previous, volume) {
            return Effect()
        }
        if let existing = store.volume(for: uid), approximatelyEqual(existing, volume) {
            return Effect()
        }
        let prior = previous ?? store.volume(for: uid)
        store.setVolume(volume, for: uid)
        var effect = Effect()
        if let prior, !approximatelyEqual(prior, volume) {
            effect.logs.append("EarPods user volume changed: \(formatVolume(prior)) → \(formatVolume(volume))")
        }
        effect.logs.append("Saved user volume: \(formatVolume(volume))")
        return effect
    }
}

private struct Session {
    var connectVolume: Float
    var latestVolume: Float
    var settling: Bool
    var reapplies: Int
    var suppressValue: Float?
    var storedAtConnect: Float?
    var didRestore: Bool
    var didLogAutomatic: Bool
}

struct DeviceFacts {
    var id: AudioDeviceID
    var transport: UInt32
    var modelUID: String
    var manufacturer: String
    var uid: String
    var virtualVolumeSettable: Bool
}

enum CoreAudioDevices {
    static func earPodsOutputs() -> [DeviceFacts] {
        allDevices().filter {
            isEarPodsOutput(
                transport: $0.transport,
                modelUID: $0.modelUID,
                manufacturer: $0.manufacturer,
                deviceUID: $0.uid,
                virtualVolumeSettable: true
            ) || (
                $0.transport == kAudioDeviceTransportTypeUSB
                    && $0.modelUID == earPodsModelUID
                    && $0.manufacturer == earPodsManufacturer
                    && isEarPodsOutputUID($0.uid)
            )
        }
    }

    static func allDevices() -> [DeviceFacts] {
        deviceIDs().compactMap(facts(for:))
    }

    static func virtualVolume(_ id: AudioDeviceID) -> Float? {
        floatValue(id, selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain)
            ?? floatValue(id, selector: kAudioDevicePropertyVolumeScalar, element: 1)
    }

    static func hardwareNudge(for volume: Float) -> Float {
        let clamped = min(1, max(0, volume))
        if clamped > 0.05 {
            return clamped - 0.02
        }
        return min(1, clamped + 0.02)
    }

    static func setOutputVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        let clamped = min(1, max(0, volume))
        let virtual = setFloat(
            id,
            selector: virtualMainVolumeSelector,
            element: kAudioObjectPropertyElementMain,
            value: clamped
        )
        let left = setFloat(id, selector: kAudioDevicePropertyVolumeScalar, element: 1, value: clamped)
        let right = setFloat(id, selector: kAudioDevicePropertyVolumeScalar, element: 2, value: clamped)
        if let read = virtualVolume(id), approximatelyEqual(read, clamped, epsilon: readbackEpsilon) {
            return true
        }
        return virtual || left || right
    }

    // Settings already shows the stored scalar, but EarPods keep the USB feature
    // unit at 0 dB until a volume *change* is sent while the stream is open.
    // Writing the same value again does not produce that change.
    static func pushHardwareVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        let clamped = min(1, max(0, volume))
        _ = setOutputVolume(id, hardwareNudge(for: clamped))
        Thread.sleep(forTimeInterval: 0.04)
        return setOutputVolume(id, clamped)
    }

    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        return status == noErr ? ids : []
    }

    static func facts(for id: AudioDeviceID) -> DeviceFacts? {
        guard
            let transport = uintValue(id, selector: kAudioDevicePropertyTransportType),
            let modelUID = stringValue(id, selector: kAudioDevicePropertyModelUID),
            let manufacturer = stringValue(id, selector: kAudioObjectPropertyManufacturer),
            let uid = stringValue(id, selector: kAudioDevicePropertyDeviceUID)
        else {
            return nil
        }
        return DeviceFacts(
            id: id,
            transport: transport,
            modelUID: modelUID,
            manufacturer: manufacturer,
            uid: uid,
            virtualVolumeSettable: isVirtualVolumeSettable(id)
        )
    }

    static func isVirtualVolumeSettable(_ id: AudioDeviceID) -> Bool {
        var address = outputAddress(selector: virtualMainVolumeSelector, element: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func outputAddress(
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func globalAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func stringValue(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = globalAddress(selector: selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func uintValue(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = globalAddress(selector: selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func floatValue(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = outputAddress(selector: selector, element: element)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setFloat(
        _ id: AudioObjectID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement,
        value: Float
    ) -> Bool {
        var address = outputAddress(selector: selector, element: element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var stored = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &stored) == noErr
    }
}

final class AgentLog: @unchecked Sendable {
    private let logger = Logger(subsystem: logSubsystem, category: "volume")
    private let url: URL
    private let lock = NSLock()

    init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("EarPodsVolume.log")
    }

    func emit(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print(message)
        fflush(stdout)
        lock.lock()
        defer { lock.unlock() }
        let data = Data((message + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

final class Agent: @unchecked Sendable {
    private let policy: EarPodsVolumePolicy
    private let log: AgentLog
    private let queue = DispatchQueue(label: logSubsystem)
    private var tracked: [AudioDeviceID: String] = [:]
    private var volumeListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var timers: [String: DispatchWorkItem] = [:]
    private var readyRetries: [String: DispatchWorkItem] = [:]
    private var restoreAttempts: [String: Int] = [:]
    private var hardwareTimers: [String: DispatchWorkItem] = [:]
    private var playbackPushStarted: Set<String> = []

    init(store: VolumeStoring, log: AgentLog) {
        self.policy = EarPodsVolumePolicy(store: store)
        self.log = log
    }

    func start() -> Never {
        installSystemListener()
        queue.sync {
            self.rescan(appearance: .alreadyPresent)
        }
        log.emit("EarPods volume agent started")
        dispatchMain()
    }

    private func installSystemListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.queue.async {
                self.rescan(appearance: .hotplug)
            }
        }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    }

    private func rescan(appearance: Appearance) {
        let devices = CoreAudioDevices.earPodsOutputs()
        let liveIDs = Set(devices.map(\.id))

        for (id, uid) in tracked where !liveIDs.contains(id) {
            removeVolumeListener(id)
            tracked.removeValue(forKey: id)
            if !devices.contains(where: { $0.uid == uid }) {
                cancelTimer(uid)
                cancelHardwarePush(uid)
                readyRetries[uid]?.cancel()
                readyRetries[uid] = nil
                restoreAttempts[uid] = nil
                playbackPushStarted.remove(uid)
                policy.disappeared(uid: uid)
            }
        }

        for device in devices where tracked[device.id] == nil {
            guard let volume = CoreAudioDevices.virtualVolume(device.id) else {
                scheduleReadyRetry(device, appearance: appearance)
                continue
            }
            readyRetries[device.uid]?.cancel()
            readyRetries[device.uid] = nil
            tracked[device.id] = device.uid
            addVolumeListener(device.id)
            let effect = policy.appeared(uid: device.uid, volume: volume, appearance: appearance)
            perform(uid: device.uid, effect: effect, deviceID: device.id)
            handleRunning(deviceID: device.id)
        }
    }

    private func scheduleReadyRetry(_ device: DeviceFacts, appearance: Appearance) {
        guard readyRetries[device.uid] == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.readyRetries[device.uid] = nil
            guard self.tracked[device.id] == nil else { return }
            guard let volume = CoreAudioDevices.virtualVolume(device.id) else { return }
            guard CoreAudioDevices.facts(for: device.id)?.uid == device.uid else { return }
            self.tracked[device.id] = device.uid
            self.addVolumeListener(device.id)
            let effect = self.policy.appeared(uid: device.uid, volume: volume, appearance: appearance)
            self.perform(uid: device.uid, effect: effect, deviceID: device.id)
            self.handleRunning(deviceID: device.id)
        }
        readyRetries[device.uid] = item
        queue.asyncAfter(deadline: .now() + readyRetryDelay, execute: item)
    }

    private func addVolumeListener(_ id: AudioDeviceID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            let events = UnsafeBufferPointer(start: addresses, count: Int(count))
            let volumeChanged = events.contains {
                $0.mSelector == virtualMainVolumeSelector || $0.mSelector == kAudioDevicePropertyVolumeScalar
            }
            let runningChanged = events.contains {
                $0.mSelector == kAudioDevicePropertyDeviceIsRunningSomewhere
            }
            self.queue.async {
                if volumeChanged {
                    self.handleVolume(deviceID: id)
                }
                if runningChanged {
                    self.handleRunning(deviceID: id)
                }
            }
        }
        var virtual = AudioObjectPropertyAddress(
            mSelector: virtualMainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channel = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(id, &virtual, nil, block)
        AudioObjectAddPropertyListenerBlock(id, &channel, nil, block)
        AudioObjectAddPropertyListenerBlock(id, &running, nil, block)
        volumeListeners[id] = block
    }

    private func removeVolumeListener(_ id: AudioDeviceID) {
        guard let block = volumeListeners.removeValue(forKey: id) else { return }
        var virtual = AudioObjectPropertyAddress(
            mSelector: virtualMainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channel = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 1
        )
        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(id, &virtual, nil, block)
        AudioObjectRemovePropertyListenerBlock(id, &channel, nil, block)
        AudioObjectRemovePropertyListenerBlock(id, &running, nil, block)
    }

    private func handleVolume(deviceID: AudioDeviceID) {
        guard let uid = tracked[deviceID], let volume = CoreAudioDevices.virtualVolume(deviceID) else { return }
        let effect = policy.volumeChanged(uid: uid, volume: volume)
        perform(uid: uid, effect: effect, deviceID: deviceID)
    }

    private func perform(uid: String, effect: Effect, deviceID: AudioDeviceID?) {
        if effect.cancelTimer {
            cancelTimer(uid)
        }
        for line in effect.logs {
            log.emit(line)
        }
        if let apply = effect.apply {
            applyVolume(uid: uid, apply: apply, deviceID: deviceID, failedSchedule: effect.schedule)
        } else if let schedule = effect.schedule {
            scheduleTimer(uid: uid, schedule)
        }
    }

    private func applyVolume(uid: String, apply: Apply, deviceID: AudioDeviceID?, failedSchedule: ScheduledTimer?) {
        if apply.kind == .restore {
            log.emit("Restoring volume: \(formatVolume(apply.volume))")
        }
        let ok = deviceID.map { CoreAudioDevices.setOutputVolume($0, apply.volume) } ?? false
        if apply.kind == .restore {
            if ok {
                log.emit("Volume restoration completed")
                if let failedSchedule {
                    scheduleTimer(uid: uid, failedSchedule)
                }
            } else {
                policy.restoreFailed(uid: uid)
                let attempts = restoreAttempts[uid, default: 0]
                if attempts < 1 {
                    restoreAttempts[uid] = attempts + 1
                    scheduleTimer(uid: uid, ScheduledTimer(phase: .restore, delay: readyRetryDelay))
                } else {
                    log.emit("Volume restoration failed")
                    scheduleTimer(uid: uid, ScheduledTimer(phase: .finish, delay: postRestoreSettle))
                }
            }
        }
    }

    private func scheduleTimer(uid: String, _ schedule: ScheduledTimer) {
        timers[uid]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fire(uid: uid, phase: schedule.phase)
        }
        timers[uid] = item
        queue.asyncAfter(deadline: .now() + schedule.delay, execute: item)
    }

    private func fire(uid: String, phase: TimerPhase) {
        guard tracked.values.contains(uid) else { return }
        let deviceID = tracked.first(where: { $0.value == uid })?.key
        switch phase {
        case .restore:
            let effect = policy.restorePhase(uid: uid)
            perform(uid: uid, effect: effect, deviceID: deviceID)
        case .finish:
            restoreAttempts[uid] = nil
            let effect = policy.finishPhase(uid: uid)
            perform(uid: uid, effect: effect, deviceID: deviceID)
        }
    }

    private func cancelTimer(_ uid: String) {
        timers[uid]?.cancel()
        timers[uid] = nil
    }

    private func handleRunning(deviceID: AudioDeviceID) {
        guard let uid = tracked[deviceID] else { return }
        guard CoreAudioDevices.isRunningSomewhere(deviceID) else {
            cancelHardwarePush(uid)
            playbackPushStarted.remove(uid)
            return
        }
        guard !playbackPushStarted.contains(uid) else { return }
        playbackPushStarted.insert(uid)
        scheduleHardwarePush(uid: uid, deviceID: deviceID, followUp: true)
    }

    private func scheduleHardwarePush(uid: String, deviceID: AudioDeviceID, followUp: Bool) {
        hardwareTimers[uid]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.performHardwarePush(uid: uid, deviceID: deviceID, followUp: followUp)
        }
        hardwareTimers[uid] = item
        queue.asyncAfter(deadline: .now() + (followUp ? 0.05 : 0.4), execute: item)
    }

    private func performHardwarePush(uid: String, deviceID: AudioDeviceID, followUp: Bool) {
        hardwareTimers[uid] = nil
        guard tracked[deviceID] == uid, CoreAudioDevices.isRunningSomewhere(deviceID) else { return }
        guard let target = policy.volume(for: uid) else { return }
        if followUp {
            let current = CoreAudioDevices.virtualVolume(deviceID) ?? target
            log.emit("EarPods playback started")
            log.emit("Current system volume: \(formatVolume(current))")
            log.emit("Stored user volume: \(formatVolume(target))")
        }
        let nudge = CoreAudioDevices.hardwareNudge(for: target)
        policy.armHardwareSuppress(uid: uid, volumes: [nudge, target])
        log.emit("Pushing volume to hardware: \(formatVolume(target))")
        let ok = CoreAudioDevices.pushHardwareVolume(deviceID, target)
        log.emit(ok ? "Hardware volume push completed" : "Hardware volume push failed")
        if followUp {
            scheduleHardwarePush(uid: uid, deviceID: deviceID, followUp: false)
        }
    }

    private func cancelHardwarePush(_ uid: String) {
        hardwareTimers[uid]?.cancel()
        hardwareTimers[uid] = nil
    }
}

enum EarPodsSelfTest {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
            }
        }

        let earPodsUID = "AppleUSBAudioEngine:Apple, Inc.:EarPods:EXAMPLESN:1"
        expect(isEarPodsOutputUID(earPodsUID), "output uid")
        expect(!isEarPodsOutputUID("AppleUSBAudioEngine:Apple, Inc.:EarPods:EXAMPLESN:2"), "mic uid")
        expect(!isEarPodsOutputUID("AppleUSBAudioEngine:Apple, Inc.:EarPods:EXAMPLESN:11"), "stream 11")
        expect(
            isEarPodsOutput(
                transport: kAudioDeviceTransportTypeUSB,
                modelUID: earPodsModelUID,
                manufacturer: earPodsManufacturer,
                deviceUID: earPodsUID,
                virtualVolumeSettable: true
            ),
            "full identity"
        )
        expect(
            !isEarPodsOutput(
                transport: kAudioDeviceTransportTypeBuiltIn,
                modelUID: "Speaker",
                manufacturer: "Apple Inc.",
                deviceUID: "BuiltInSpeakerDevice",
                virtualVolumeSettable: true
            ),
            "built-in speakers"
        )
        expect(
            !isEarPodsOutput(
                transport: kAudioDeviceTransportTypeUSB,
                modelUID: earPodsModelUID,
                manufacturer: earPodsManufacturer,
                deviceUID: "AppleUSBAudioEngine:Apple, Inc.:EarPods:EXAMPLESN:2",
                virtualVolumeSettable: false
            ),
            "microphone"
        )

        let store = MemoryVolumeStore()
        store.setVolume(0.4, for: earPodsUID)
        let policy = EarPodsVolumePolicy(store: store)
        var logs: [String] = []

        let appeared = policy.appeared(uid: earPodsUID, volume: 1, appearance: .hotplug)
        logs.append(contentsOf: appeared.logs)
        expect(appeared.apply == nil, "connect must not apply before the device settles")
        expect(appeared.schedule?.phase == .restore, "connect schedules restore")
        expect(approximatelyEqual(store.volume(for: earPodsUID) ?? 0, 0.4), "connect must not replace 0.4 with 1.0")

        let earlyAutomatic = policy.volumeChanged(uid: earPodsUID, volume: 1)
        expect(earlyAutomatic.logs.isEmpty && earlyAutomatic.apply == nil, "initial 1.0 notification is not saved")
        expect(approximatelyEqual(store.volume(for: earPodsUID) ?? 0, 0.4), "early 1.0 keeps 0.4")

        let restore = policy.restorePhase(uid: earPodsUID)
        expect(restore.apply?.kind == .restore, "restore kind")
        expect(approximatelyEqual(restore.apply?.volume ?? 0, 0.4), "restore 0.4")
        logs.append("Restoring volume: \(formatVolume(restore.apply?.volume ?? -1))")
        logs.append("Volume restoration completed")
        expect(approximatelyEqual(store.volume(for: earPodsUID) ?? 0, 0.4), "restore does not rewrite storage")

        let echo = policy.volumeChanged(uid: earPodsUID, volume: 0.4)
        expect(echo.logs.isEmpty && echo.apply == nil, "restored value is not saved again")

        for attempt in 1...3 {
            let again = policy.volumeChanged(uid: earPodsUID, volume: 1)
            logs.append(contentsOf: again.logs)
            if attempt < 3 {
                expect(again.apply?.kind == .reapply, "reapply \(attempt)")
                expect(approximatelyEqual(again.apply?.volume ?? 0, 0.4), "reapply target \(attempt)")
                _ = policy.volumeChanged(uid: earPodsUID, volume: 0.4)
            } else {
                expect(again.apply == nil, "third automatic 1.0 is not applied again")
            }
            expect(approximatelyEqual(store.volume(for: earPodsUID) ?? 0, 0.4), "reapply \(attempt) keeps 0.4")
        }

        _ = policy.finishPhase(uid: earPodsUID)
        let user = policy.volumeChanged(uid: earPodsUID, volume: 0.65)
        logs.append(contentsOf: user.logs)
        expect(approximatelyEqual(store.volume(for: earPodsUID) ?? 0, 0.65), "user volume stored")

        let expected = [
            "EarPods connected",
            "EarPods UID: \(earPodsUID)",
            "Current system volume: 1.0",
            "Stored user volume: 0.4",
            "EarPods automatic initialization volume: 1.0",
            "Restoring volume: 0.4",
            "Volume restoration completed",
            "EarPods automatic initialization volume: 1.0",
            "EarPods automatic initialization volume: 1.0",
            "EarPods automatic initialization volume: 1.0",
            "EarPods user volume changed: 0.4 → 0.65",
            "Saved user volume: 0.65",
        ]
        if logs != expected {
            failures.append("log sequence\nexpected:\n\(expected.joined(separator: "\n"))\nactual:\n\(logs.joined(separator: "\n"))")
        }

        let fresh = MemoryVolumeStore()
        let freshPolicy = EarPodsVolumePolicy(store: fresh)
        let first = freshPolicy.appeared(uid: earPodsUID, volume: 1, appearance: .hotplug)
        expect(fresh.volume(for: earPodsUID) == nil, "first connect does not store 1.0")
        expect(first.logs.contains("EarPods automatic initialization volume: 1.0"), "first connect logs automatic 1.0")
        let stillMax = freshPolicy.volumeChanged(uid: earPodsUID, volume: 1)
        expect(stillMax.logs.isEmpty && fresh.volume(for: earPodsUID) == nil, "repeat 1.0 is not stored")
        let chosen = freshPolicy.volumeChanged(uid: earPodsUID, volume: 0.3)
        expect(chosen.logs == [
            "EarPods user volume changed: 1.0 → 0.3",
            "Saved user volume: 0.3",
        ], "first user volume")
        expect(approximatelyEqual(fresh.volume(for: earPodsUID) ?? 0, 0.3), "0.3 stored")

        let present = MemoryVolumeStore()
        let presentPolicy = EarPodsVolumePolicy(store: present)
        let adopted = presentPolicy.appeared(uid: earPodsUID, volume: 0.25, appearance: .alreadyPresent)
        expect(adopted.apply == nil && adopted.schedule == nil, "already present does not restore")
        expect(approximatelyEqual(present.volume(for: earPodsUID) ?? 0, 0.25), "already present adopts live volume")
        expect(adopted.logs.contains("Saved user volume: 0.25"), "already present saves")

        let speaker = presentPolicy.volumeChanged(uid: "BuiltInSpeakerDevice", volume: 0.8)
        expect(present.volume(for: earPodsUID).map { approximatelyEqual($0, 0.25) } == true, "other device does not replace EarPods volume")
        expect(approximatelyEqual(present.volume(for: "BuiltInSpeakerDevice") ?? 0, 0.8), "untracked uid is not an EarPods session")
        _ = speaker

        expect(formatVolume(1) == "1.0", "format 1")
        expect(formatVolume(0.4) == "0.4", "format 0.4")
        expect(formatVolume(0.65) == "0.65", "format 0.65")

        let pushStore = MemoryVolumeStore()
        pushStore.setVolume(0.4, for: earPodsUID)
        let pushPolicy = EarPodsVolumePolicy(store: pushStore)
        let nudge = CoreAudioDevices.hardwareNudge(for: 0.4)
        pushPolicy.armHardwareSuppress(uid: earPodsUID, volumes: [nudge, 0.4])
        let ignoredNudge = pushPolicy.volumeChanged(uid: earPodsUID, volume: nudge)
        expect(ignoredNudge.logs.isEmpty && ignoredNudge.apply == nil, "hardware nudge is not a user change")
        expect(approximatelyEqual(pushStore.volume(for: earPodsUID) ?? 0, 0.4), "nudge keeps stored 0.4")
        let ignoredTarget = pushPolicy.volumeChanged(uid: earPodsUID, volume: 0.4)
        expect(ignoredTarget.logs.isEmpty, "pushed target is not saved again")
        let afterPush = pushPolicy.volumeChanged(uid: earPodsUID, volume: 0.55)
        expect(afterPush.logs == [
            "EarPods user volume changed: 0.4 → 0.55",
            "Saved user volume: 0.55",
        ], "user change after hardware push is saved")
        expect(approximatelyEqual(hardwareNudge(forTest: 0.4), 0.38), "nudge steps down")
        return failures
    }
}

private func printDevices() {
    for device in CoreAudioDevices.allDevices() {
        let volume = CoreAudioDevices.virtualVolume(device.id).map(formatVolume) ?? "none"
        let match = isEarPodsOutput(
            transport: device.transport,
            modelUID: device.modelUID,
            manufacturer: device.manufacturer,
            deviceUID: device.uid,
            virtualVolumeSettable: device.virtualVolumeSettable
        )
        print("id=\(device.id) earpods=\(match) volume=\(volume) uid=\(device.uid) model=\(device.modelUID)")
    }
}

private func setVolume(uid: String, value: Float) -> Int32 {
    guard let device = CoreAudioDevices.allDevices().first(where: { $0.uid == uid }) else {
        fputs("device not found\n", stderr)
        return 1
    }
    let ok = CoreAudioDevices.setOutputVolume(device.id, value)
    let read = CoreAudioDevices.virtualVolume(device.id).map(formatVolume) ?? "none"
    print("set \(uid) ok=\(ok) volume=\(read)")
    return ok ? 0 : 1
}

@main
enum EarPodsVolumeMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--self-test") {
            let failures = EarPodsSelfTest.run()
            if failures.isEmpty {
                print("self-test ok")
                return
            }
            for failure in failures {
                fputs("FAIL \(failure)\n", stderr)
            }
            exit(1)
        }
        if arguments.contains("--get") {
            printDevices()
            return
        }
        if let set = arguments.firstIndex(of: "--set"), arguments.count >= set + 3 {
            guard let value = Float(arguments[set + 2]) else {
                fputs("volume must be a number\n", stderr)
                exit(1)
            }
            exit(setVolume(uid: arguments[set + 1], value: value))
        }

        guard let defaults = UserDefaults(suiteName: preferenceSuite) else {
            fputs("Unable to open preferences\n", stderr)
            exit(1)
        }
        let agent = Agent(store: UserDefaultsVolumeStore(defaults: defaults), log: AgentLog())
        agent.start()
    }
}
