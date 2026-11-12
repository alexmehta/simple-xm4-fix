import AppKit
import CoreAudio
import ServiceManagement

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

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, fallback: T) -> T {
        var addr = address(selector, scope)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, to value: T) -> Bool {
        var addr = address(selector, scope)
        var value = value
        return withUnsafeMutablePointer(to: &value) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        get(object, selector, fallback: Unmanaged<CFString>?.none)?.takeRetainedValue() as String? ?? ""
    }

    static func devices() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(AudioDevice.init)
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
    let isBuiltIn: Bool

    init(_ id: AudioDeviceID) {
        self.id = id
        name = HAL.string(id, kAudioObjectPropertyName)
        uid = HAL.string(id, kAudioDevicePropertyDeviceUID)
        isBuiltIn = HAL.get(id, kAudioDevicePropertyTransportType, fallback: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
    }

    var isHeadset: Bool { name.localizedCaseInsensitiveContains(Config.headsetKeyword) }

    var isMuted: Bool {
        get { HAL.get(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, fallback: UInt32(0)) != 0 }
        nonmutating set { HAL.set(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, to: UInt32(newValue ? 1 : 0)) }
    }

    func handles(_ direction: Direction) -> Bool {
        var addr = HAL.address(kAudioDevicePropertyStreams, direction.scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    @discardableResult
    func makeDefault(_ direction: Direction) -> Bool {
        HAL.set(HAL.system, direction.defaultSelector, to: id)
    }
}

extension [AudioDevice] {
    func current(_ direction: Direction) -> AudioDevice? {
        let id = HAL.get(HAL.system, direction.defaultSelector, fallback: AudioDeviceID(kAudioObjectUnknown))
        return first { $0.id == id }
    }

    func builtIn(_ direction: Direction) -> AudioDevice? {
        let candidates = filter { $0.isBuiltIn && $0.handles(direction) }
        return candidates.first { $0.uid.hasPrefix("BuiltIn") } ?? candidates.first
    }
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
        refreshIcon()

        HAL.observe([kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice]) { [weak self] in
            Task { @MainActor in self?.refreshIcon() }
        }

        let trigger: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoRelease else { return }
                await self.release()
            }
        }
        let triggers: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        observers = triggers.map { center, name in center.addObserver(forName: name, object: nil, queue: .main, using: trigger) }
    }

    private func refreshIcon() {
        let symbol = busy ? "iphone.and.arrow.forward" : HAL.devices().contains(where: \.isHeadset) ? "headphones.circle.fill" : "headphones"
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
            releaseNow()
        }
    }

    @objc private func releaseNow() { Task { await release() } }

    @objc private func toggleAutoRelease() { autoRelease.toggle() }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            try service.status == .enabled ? service.unregister() : service.register()
        } catch {
            status = "Open at Login failed: \(error.localizedDescription)"
            refreshIcon()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    private func showMenu() {
        let devices = HAL.devices()
        let headset = devices.first(where: \.isHeadset)
        let menu = NSMenu()
        [
            "\(headset?.name ?? Config.headsetKeyword) — \(headset == nil ? "not connected" : "connected")",
            "Output: \(devices.current(.output)?.name ?? "—")",
            "Input: \(devices.current(.input)?.name ?? "—")",
            status,
        ].filter { !$0.isEmpty }.forEach { menu.addItem(withTitle: $0, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Release to iPhone", action: #selector(releaseNow), keyEquivalent: "").target = self
        [
            ("Auto-release when Mac locks or sleeps", #selector(toggleAutoRelease), autoRelease),
            ("Open at Login", #selector(toggleOpenAtLogin), SMAppService.mainApp.status == .enabled),
        ].forEach { title, action, isOn in
            let toggle = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            toggle.target = self
            toggle.state = isOn ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp

        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func release() async {
        guard !busy else { return }
        busy = true
        refreshIcon()
        defer {
            busy = false
            refreshIcon()
        }
        let devices = HAL.devices()
        var steps: [String] = []

        if devices.current(.input)?.isHeadset == true, let mic = devices.builtIn(.input), mic.makeDefault(.input) {
            steps.append("mic → \(mic.name)")
        }
        if let headset = devices.current(.output), headset.isHeadset, let speakers = devices.builtIn(.output) {
            let wasMuted = speakers.isMuted
            speakers.isMuted = true
            speakers.makeDefault(.output)
            try? await Task.sleep(for: Config.hold)
            headset.makeDefault(.output)
            try? await Task.sleep(for: Config.settle)
            speakers.isMuted = wasMuted
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
