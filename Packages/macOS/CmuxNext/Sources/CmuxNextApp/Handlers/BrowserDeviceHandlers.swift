import AppKit
import CmuxNextActions
import CmuxNextBrowser
import CmuxNextCompat

/// `browserDevice` (Emulate Device…): Chrome's device toolbar devices for
/// both engines, from one list (`BrowserDevices`: Chrome 154's DevTools list,
/// newer built-in devices, and the person's custom devices in
/// `browser-devices.json` next to cmux.json).
///
/// | argument | effect |
/// | --- | --- |
/// | none | shows the device menu (from the toolbar's More button) |
/// | `device: <title>` | emulates that device (exact title, else case- and space-insensitive) |
/// | `device: none` | stops emulating |
/// | `device: rotate` | the device's next orientation (Chrome's rotate button) |
/// | `orientation` | `portrait`, `landscape`, `unfolded-portrait`, `unfolded-landscape` (Chrome's mode names work too) |
enum BrowserDeviceHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("browserDevice", run: { invocation in
            let entry = try context.page(invocation)
            guard let tab = entry.tab as? any BrowserDeviceEmulating else {
                throw ActionFailure(message: MiscHandlerStrings.noBrowser)
            }
            let devices = BrowserDevices.load(customFile: customFile(context.services))
            let orientation = try invocation["orientation"]?.stringValue.map(Self.orientation)
            guard let name = invocation["device"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                if let orientation, let current = tab.deviceEmulation {
                    guard current.device.orientations.contains(orientation) else {
                        throw ActionFailure(message: DeviceStrings.noOrientation(device: current.device.title, orientation: orientation,
                                                                                 available: current.device.orientations))
                    }
                    return tab.setDeviceEmulation(BrowserDeviceEmulation(device: current.device, orientation: orientation))
                }
                // A script or agent gets the list; only a person gets the menu.
                guard invocation.origin == .user else {
                    throw ActionFailure(message: DeviceStrings.available(devices.all.map(\.title)))
                }
                let menu = Self.menu(devices: devices, current: tab.deviceEmulation, target: ActionTargetRef(kind: .tab, id: entry.tab.id.rawValue),
                                     registry: registry, services: context.services)
                return entry.chrome.toolbarButtons.present(menu, from: .overflow)
            }
            switch name.lowercased() {
            case "none", "off":
                tab.setDeviceEmulation(nil)
            case "rotate":
                guard let current = tab.deviceEmulation else { throw ActionFailure(message: DeviceStrings.notEmulating) }
                tab.setDeviceEmulation(current.rotated)
            default:
                guard let device = devices.device(named: name) else {
                    throw ActionFailure(message: DeviceStrings.unknownDevice(name) + "\n" + DeviceStrings.available(devices.all.map(\.title)),
                                        isNotFound: true)
                }
                if let orientation, !device.orientations.contains(orientation) {
                    throw ActionFailure(message: DeviceStrings.noOrientation(device: device.title, orientation: orientation,
                                                                             available: device.orientations))
                }
                tab.setDeviceEmulation(BrowserDeviceEmulation(device: device, orientation: orientation))
            }
        })
    }

    /// `browser-devices.json` beside the settings file (cmux.json).
    static func customFile(_ services: AppServices) -> URL? {
        services.settings?.file.url.deletingLastPathComponent().appendingPathComponent(BrowserDevices.customFileName)
    }

    private static func orientation(_ value: String) throws -> BrowserDeviceOrientation {
        switch value.lowercased() {
        case "portrait", "vertical": .vertical
        case "landscape", "horizontal": .horizontal
        case "unfolded-portrait", "vertical-spanned", "spanned-portrait": .verticalSpanned
        case "unfolded-landscape", "horizontal-spanned", "spanned-landscape": .horizontalSpanned
        default: throw ActionFailure(message: DeviceStrings.unknownOrientation(value))
        }
    }

    /// Chrome's device menu: No Device, the orientations of the current
    /// device, then the default-visible devices by Chrome's categories, the
    /// custom devices, every device under All Devices, and Edit Custom
    /// Devices…. Each row runs `browserDevice`.
    static func menu(devices: BrowserDevices, current: BrowserDeviceEmulation?, target: ActionTargetRef,
                     registry: ActionRegistry, services: AppServices) -> NSMenu {
        let menu = NSMenu()
        func run(_ arguments: [String: ActionValue]) -> ActionMenuClosure {
            ActionMenuClosure { [weak registry] in
                registry?.perform("browserDevice", invocation: ActionInvocation(target: target, arguments: arguments, origin: .user))
            }
        }
        func add(_ title: String, to menu: NSMenu, checked: Bool = false, toolTip: String? = nil, _ closure: ActionMenuClosure) {
            let item = NSMenuItem(title: title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
            item.target = closure
            item.representedObject = closure
            item.state = checked ? .on : .off
            item.toolTip = toolTip
            menu.addItem(item)
        }
        func addDevices(_ list: [BrowserDevice], to menu: NSMenu) {
            for device in list {
                let size = device.screen.vertical
                add(device.title, to: menu, checked: current?.device == device,
                    toolTip: DeviceStrings.details(width: size.width, height: size.height, ratio: device.screen.devicePixelRatio),
                    run(["device": .string(device.title)]))
            }
        }
        add(DeviceStrings.noDevice, to: menu, checked: current == nil, run(["device": .string("none")]))
        if let current, current.device.orientations.count > 1 {
            menu.addItem(.separator())
            for orientation in current.device.orientations {
                add(DeviceStrings.orientation(orientation), to: menu, checked: orientation == current.orientation,
                    run(["device": .string(current.device.title), "orientation": .string(orientation.rawValue)]))
            }
        }
        for category in BrowserDevice.Category.allCases {
            let list = devices.builtIn(category, defaultVisibleOnly: true)
            guard !list.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: DeviceStrings.category(category)))
            addDevices(list, to: menu)
        }
        if !devices.custom.isEmpty {
            menu.addItem(.sectionHeader(title: DeviceStrings.custom))
            addDevices(devices.custom, to: menu)
        }
        menu.addItem(.separator())
        let all = NSMenu()
        for category in BrowserDevice.Category.allCases {
            let list = devices.builtIn(category, defaultVisibleOnly: false)
            guard !list.isEmpty else { continue }
            all.addItem(.sectionHeader(title: DeviceStrings.category(category)))
            addDevices(list, to: all)
        }
        let allItem = NSMenuItem(title: DeviceStrings.allDevices, action: nil, keyEquivalent: "")
        allItem.submenu = all
        menu.addItem(allItem)
        if let file = customFile(services) {
            add(DeviceStrings.editCustom, to: menu, toolTip: devices.customError, ActionMenuClosure {
                if !FileManager.default.fileExists(atPath: file.path) {
                    try? Data("{\n \"devices\": []\n}\n".utf8).write(to: file, options: .withoutOverwriting)
                }
                NSWorkspace.shared.openInBackground(file)
            })
        }
        return menu
    }
}

/// The device menu's and the action's text (BrowserDevices.xcstrings).
nonisolated enum DeviceStrings {
    static var noDevice: String { String(localized: "browserDevices.none", defaultValue: "No Device", table: "BrowserDevices", bundle: .module) }
    static var allDevices: String { String(localized: "browserDevices.all", defaultValue: "All Devices", table: "BrowserDevices", bundle: .module) }
    static var custom: String { String(localized: "browserDevices.custom", defaultValue: "Custom", table: "BrowserDevices", bundle: .module) }
    static var editCustom: String {
        String(localized: "browserDevices.editCustom", defaultValue: "Edit Custom Devices…", table: "BrowserDevices", bundle: .module)
    }
    static var notEmulating: String {
        String(localized: "browserDevices.notEmulating", defaultValue: "This page emulates no device.", table: "BrowserDevices", bundle: .module)
    }

    static func unknownDevice(_ name: String) -> String {
        String(localized: "browserDevices.unknown", defaultValue: "No device named “\(name)”. Run Emulate Device… to see the list.",
               table: "BrowserDevices", bundle: .module)
    }

    static func unknownOrientation(_ value: String) -> String {
        String(localized: "browserDevices.unknownOrientation",
               defaultValue: "Unknown orientation “\(value)”. Use portrait, landscape, unfolded-portrait or unfolded-landscape.",
               table: "BrowserDevices", bundle: .module)
    }

    /// Every device title, for a script or agent.
    static func available(_ titles: [String]) -> String {
        let list = titles.joined(separator: ", ")
        return String(localized: "browserDevices.available", defaultValue: "Devices: \(list)", table: "BrowserDevices", bundle: .module)
    }

    /// The orientation names the action takes, for a device's orientations.
    static func argumentName(_ orientation: BrowserDeviceOrientation) -> String {
        switch orientation {
        case .vertical: "portrait"
        case .horizontal: "landscape"
        case .verticalSpanned: "unfolded-portrait"
        case .horizontalSpanned: "unfolded-landscape"
        }
    }

    static func noOrientation(device: String, orientation: BrowserDeviceOrientation, available: [BrowserDeviceOrientation]) -> String {
        let name = argumentName(orientation)
        let list = available.map(argumentName).joined(separator: ", ")
        return String(localized: "browserDevices.noOrientation", defaultValue: "“\(device)” has no \(name) orientation. It has: \(list).",
                      table: "BrowserDevices", bundle: .module)
    }

    static func details(width: Int, height: Int, ratio: Double) -> String {
        let ratioText = ratio.formatted(.number.precision(.fractionLength(0...3)))
        return String(localized: "browserDevices.details", defaultValue: "\(width) × \(height), device pixel ratio \(ratioText)",
                      table: "BrowserDevices", bundle: .module)
    }

    static func category(_ category: BrowserDevice.Category) -> String {
        switch category {
        case .mobile: String(localized: "browserDevices.category.mobile", defaultValue: "Mobile", table: "BrowserDevices", bundle: .module)
        case .foldable: String(localized: "browserDevices.category.foldable", defaultValue: "Foldables", table: "BrowserDevices", bundle: .module)
        case .tabletDesktop:
            String(localized: "browserDevices.category.tabletDesktop", defaultValue: "Tablets & Desktops", table: "BrowserDevices", bundle: .module)
        case .smartDisplay:
            String(localized: "browserDevices.category.smartDisplay", defaultValue: "Smart Displays", table: "BrowserDevices", bundle: .module)
        }
    }

    static func orientation(_ orientation: BrowserDeviceOrientation) -> String {
        switch orientation {
        case .vertical: String(localized: "browserDevices.portrait", defaultValue: "Portrait", table: "BrowserDevices", bundle: .module)
        case .horizontal: String(localized: "browserDevices.landscape", defaultValue: "Landscape", table: "BrowserDevices", bundle: .module)
        case .verticalSpanned:
            String(localized: "browserDevices.unfoldedPortrait", defaultValue: "Unfolded, Portrait", table: "BrowserDevices", bundle: .module)
        case .horizontalSpanned:
            String(localized: "browserDevices.unfoldedLandscape", defaultValue: "Unfolded, Landscape", table: "BrowserDevices", bundle: .module)
        }
    }
}
