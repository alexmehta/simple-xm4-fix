import AppKit
import CoreAudio

enum Config {
    static let headsetKeyword = "WH-1000XM4"
    static let autoReleaseKey = "autoRelease"
    static let hold: Duration = .milliseconds(500)
    static let settle: Duration = .milliseconds(300)
}

enum Direction {
    case output, input

    var scope: AudioObjectPropertyScope { self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput }
    var defaultSelector: AudioObjectPropertySelector { self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice }
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, fallback: T) -> T {
        var addr = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, value: T) -> Bool {
        var addr = address(selector, scope)
        var value = value
        return withUnsafeMutablePointer(to: &value) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? (value?.takeRetainedValue() as String?) ?? "" : ""
    }

    static func hasStreams(_ device: AudioDeviceID, _ direction: Direction) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, direction.scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr && size > 0
    }

    static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(AudioDevice.init)
    }

    static func defaultDevice(_ direction: Direction) -> AudioDeviceID {
        scalar(system, direction.defaultSelector, fallback: AudioDeviceID(kAudioObjectUnknown))
    }

    @discardableResult
    static func setDefault(_ device: AudioDeviceID, _ direction: Direction) -> Bool {
        set(system, direction.defaultSelector, value: device)
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        return scalar(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, fallback: UInt32(0)) != 0
    }

    @discardableResult
    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        set(device, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
    }

    static func observe(_ selectors: [AudioObjectPropertySelector], _ handler: @escaping @Sendable () -> Void) {
        selectors.forEach {
            var addr = address($0)
            AudioObjectAddPropertyListenerBlock(system, &addr, .main) { _, _ in handler() }
        }
    }
}

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: UInt32
    let hasOutput: Bool
    let hasInput: Bool

    init(_ id: AudioDeviceID) {
        self.id = id
        name = HAL.string(id, kAudioObjectPropertyName)
        uid = HAL.string(id, kAudioDevicePropertyDeviceUID)
        transport = HAL.scalar(id, kAudioDevicePropertyTransportType, fallback: UInt32(0))
        hasOutput = HAL.hasStreams(id, .output)
        hasInput = HAL.hasStreams(id, .input)
    }

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isHeadset: Bool { name.localizedCaseInsensitiveContains(Config.headsetKeyword) }
    func handles(_ direction: Direction) -> Bool { direction == .output ? hasOutput : hasInput }
}

extension [AudioDevice] {
    func builtIn(_ direction: Direction) -> AudioDevice? {
        let candidates = filter { $0.isBuiltIn && $0.handles(direction) }
        return candidates.first { $0.uid.hasPrefix("BuiltIn") } ?? candidates.first
    }

    func name(of id: AudioDeviceID) -> String { first { $0.id == id }?.name ?? "—" }
}


@MainActor
final class StatusController: NSObject {
    private let item: NSStatusItem
    private var busy = false
    private var status = ""
    private var observers: [NSObjectProtocol] = []

    private var autoRelease: Bool {
        get { UserDefaults.standard.bool(forKey: Config.autoReleaseKey) }
        set { UserDefaults.standard.set(newValue, forKey: Config.autoReleaseKey) }
    }

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        reload()

        HAL.observe([kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice]) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        let trigger: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRelease else { return }
                await self.release()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification].map {
            workspace.addObserver(forName: $0, object: nil, queue: .main, using: trigger)
        } + [DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: trigger)]
    }

    private func reload() {
        let connected = HAL.devices().contains(where: \.isHeadset)
        let symbol = busy ? "iphone.and.arrow.forward" : connected ? "headphones.circle.fill" : "headphones"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "XM4 Switcher")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = ["Click to release \(Config.headsetKeyword) · right-click for options", status].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            Task { await release() }
        }
    }

    @objc private func releaseFromMenu() { Task { await release() } }

    @objc private func toggleAutoRelease() { autoRelease.toggle() }

    private func showMenu() {
        let devices = HAL.devices()
        let headset = devices.first(where: \.isHeadset)
        let info = [
            "\(headset?.name ?? Config.headsetKeyword) — \(headset == nil ? "not connected" : "connected")",
            "Output: \(devices.name(of: HAL.defaultDevice(.output)))",
            "Input: \(devices.name(of: HAL.defaultDevice(.input)))",
            status,
        ].filter { !$0.isEmpty }

        let menu = NSMenu()
        info.forEach { menu.addItem(NSMenuItem(title: $0, action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        let release = NSMenuItem(title: "Release to iPhone", action: #selector(releaseFromMenu), keyEquivalent: "")
        let auto = NSMenuItem(title: "Auto-release when Mac locks or sleeps", action: #selector(toggleAutoRelease), keyEquivalent: "")
        auto.state = autoRelease ? .on : .off
        [release, auto].forEach { $0.target = self; menu.addItem($0) }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func release() async {
        guard !busy else { return }
        busy = true
        reload()
        defer {
            busy = false
            reload()
        }
        let devices = HAL.devices()
        let headsetIDs = Set(devices.filter(\.isHeadset).map(\.id))
        let output = HAL.defaultDevice(.output)
        var steps: [String] = []

        if headsetIDs.contains(HAL.defaultDevice(.input)), let mic = devices.builtIn(.input), HAL.setDefault(mic.id, .input) {
            steps.append("mic → \(mic.name)")
        }
        if headsetIDs.contains(output), let speakers = devices.builtIn(.output) {
            let wasMuted = HAL.isMuted(speakers.id) ?? false
            HAL.setMuted(speakers.id, true)
            HAL.setDefault(speakers.id, .output)
            try? await Task.sleep(for: Config.hold)
            HAL.setDefault(output, .output)
            try? await Task.sleep(for: Config.settle)
            HAL.setMuted(speakers.id, wasMuted)
            steps.append("output bounced via \(speakers.name)")
        }
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        status = "Last release \(time): " + (steps.isEmpty ? "nothing to release" : steps.joined(separator: ", "))
    }
}

@main
@MainActor
enum XM4Switcher {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = StatusController()
        withExtendedLifetime(controller) { app.run() }
    }
}
