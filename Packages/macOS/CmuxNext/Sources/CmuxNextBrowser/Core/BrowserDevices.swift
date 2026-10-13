public import Foundation

/// One emulated device, in Chrome DevTools' own JSON format (JSONV1, the
/// format of `EmulatedDevices.ts` and of Chrome's custom device setting), so
/// a Chrome device or a Chrome custom-device export reads unchanged.
///
/// The built-in list is one data file shared by both engines and the agent
/// action (`Resources/EmulatedDevices.json`): Chrome 154's list, verbatim and
/// in Chrome's order (`scripts/cmux-next/import-chrome-devices.py`), then
/// newer devices Chrome does not list yet (`origin` "cmux", each with its
/// spec `sources`). Custom devices come from `browser-devices.json` next to
/// cmux.json (`BrowserDevices.load(customFile:)`).
public nonisolated struct BrowserDevice: Codable, Hashable, Sendable {
    public var title: String
    /// phone, tablet, notebook, desktop, foldable, smart-display, unknown.
    public var type: String
    /// Chrome's sort key (then the title).
    public var order: Double?
    public var showByDefault: Bool?
    public var screen: Screen
    /// "touch" and "mobile"; none when missing (Chrome's default).
    public var capabilities: [String]?
    /// "%s" stands for the browser's Chrome version (Chrome patches it the same way).
    public var userAgent: String
    public var userAgentMetadata: UserAgentMetadata?
    public var modes: [Mode]?
    public var dualScreen: Bool?
    public var foldableScreen: Bool?
    /// "chrome" (Chrome's list), "cmux" (a newer device cmux adds), or nil (a custom device).
    public var origin: String?
    /// Where a cmux-added device's numbers come from.
    public var sources: [String]?

    public nonisolated struct Screen: Codable, Hashable, Sendable {
        public var vertical: Orientation
        public var horizontal: Orientation
        public var verticalSpanned: Orientation?
        public var horizontalSpanned: Orientation?
        public var devicePixelRatio: Double

        enum CodingKeys: String, CodingKey {
            case vertical, horizontal
            case verticalSpanned = "vertical-spanned"
            case horizontalSpanned = "horizontal-spanned"
            case devicePixelRatio = "device-pixel-ratio"
        }
    }

    public nonisolated struct Orientation: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var hinge: Hinge?
    }

    /// A foldable's fold or a dual screen's gap, in CSS px of the spanned screen.
    public nonisolated struct Hinge: Codable, Hashable, Sendable {
        public var width: Int
        public var height: Int
        public var x: Int
        public var y: Int
    }

    public nonisolated struct Mode: Codable, Hashable, Sendable {
        public var title: String
        public var orientation: String
        public var safeAreaInsets: Insets?

        enum CodingKeys: String, CodingKey {
            case title, orientation
            case safeAreaInsets = "safe-area-insets"
        }
    }

    public nonisolated struct Insets: Codable, Hashable, Sendable {
        public var left: Int
        public var top: Int
        public var right: Int
        public var bottom: Int
    }

    /// The `Emulation.setUserAgentOverride` metadata (client hints).
    public nonisolated struct UserAgentMetadata: Codable, Hashable, Sendable {
        public var platform: String
        public var platformVersion: String
        public var architecture: String
        public var model: String
        public var mobile: Bool
    }

    enum CodingKeys: String, CodingKey {
        case title, type, order, screen, capabilities, modes, origin, sources
        case showByDefault = "show-by-default"
        case userAgent = "user-agent"
        case userAgentMetadata = "user-agent-metadata"
        case dualScreen = "dual-screen"
        case foldableScreen = "foldable-screen"
    }

    public var touch: Bool { capabilities?.contains("touch") == true }
    public var mobile: Bool { capabilities?.contains("mobile") == true }

    /// Chrome's device categories, in Chrome's menu order (`deviceCategory`).
    public enum Category: String, CaseIterable, Sendable {
        case mobile, foldable, tabletDesktop, smartDisplay
    }

    public var category: Category {
        if type == "foldable" || foldableScreen == true || dualScreen == true { return .foldable }
        if type == "smart-display" { return .smartDisplay }
        if ["tablet", "notebook", "desktop"].contains(type) { return .tabletDesktop }
        return .mobile
    }

    /// The orientations this device has, in Chrome's mode order; a device
    /// without modes has vertical and horizontal (Chrome's default).
    public var orientations: [BrowserDeviceOrientation] {
        let names = modes.map { $0.map(\.orientation) } ?? ["vertical", "horizontal"]
        var seen: [BrowserDeviceOrientation] = []
        for name in names {
            guard let orientation = BrowserDeviceOrientation(rawValue: name), !seen.contains(orientation),
                  size(orientation) != nil else { continue }
            seen.append(orientation)
        }
        return seen
    }

    /// The CSS size of the screen in `orientation`, nil when the device has none.
    public func size(_ orientation: BrowserDeviceOrientation) -> Orientation? {
        switch orientation {
        case .vertical: screen.vertical
        case .horizontal: screen.horizontal
        case .verticalSpanned: screen.verticalSpanned
        case .horizontalSpanned: screen.horizontalSpanned
        }
    }

    /// The user agent with Chrome's version in place of "%s", as DevTools
    /// patches it (`patchUserAgentWithChromeVersion`: the second "%s" is
    /// "<major>.0.100.0"). An empty version leaves the string as it is.
    public func userAgent(chromeVersion: String) -> String {
        guard !chromeVersion.isEmpty, userAgent.contains("%s") else { return userAgent }
        let major = chromeVersion.split(separator: ".").first.map(String.init) ?? chromeVersion
        var result = userAgent
        for value in [chromeVersion, "\(major).0.100.0"] {
            guard let range = result.range(of: "%s") else { break }
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    /// A device that can be emulated: Chrome's limits (sizes 50...9999,
    /// device pixel ratio up to 10 as DevTools' editor allows).
    var isValid: Bool {
        let sizes = [screen.vertical, screen.horizontal] + [screen.verticalSpanned, screen.horizontalSpanned].compactMap(\.self)
        return !title.isEmpty && screen.devicePixelRatio > 0 && screen.devicePixelRatio <= 10
            && sizes.allSatisfy { (50...9999).contains($0.width) && (50...9999).contains($0.height) }
    }
}

/// Chrome's mode orientations; the spanned ones are a foldable's open screen.
public nonisolated enum BrowserDeviceOrientation: String, CaseIterable, Codable, Hashable, Sendable {
    case vertical, horizontal
    case verticalSpanned = "vertical-spanned"
    case horizontalSpanned = "horizontal-spanned"

    public var isPortrait: Bool { self == .vertical || self == .verticalSpanned }
    public var isSpanned: Bool { self == .verticalSpanned || self == .horizontalSpanned }
}

/// A device and orientation applied to one tab.
public nonisolated struct BrowserDeviceEmulation: Hashable, Sendable {
    public var device: BrowserDevice
    public var orientation: BrowserDeviceOrientation

    public init(device: BrowserDevice, orientation: BrowserDeviceOrientation? = nil) {
        self.device = device
        self.orientation = orientation.flatMap { device.orientations.contains($0) ? $0 : nil }
            ?? device.orientations.first ?? .vertical
    }

    /// The CSS viewport size.
    public var size: CGSize {
        let size = device.size(orientation) ?? device.screen.vertical
        return CGSize(width: size.width, height: size.height)
    }

    /// The hinge of a spanned (open) foldable, nil otherwise.
    public var hinge: BrowserDevice.Hinge? { orientation.isSpanned ? device.size(orientation)?.hinge : nil }

    /// The next orientation (Chrome's rotate button).
    public var rotated: BrowserDeviceEmulation {
        let all = device.orientations
        guard let index = all.firstIndex(of: orientation), all.count > 1 else { return self }
        return BrowserDeviceEmulation(device: device, orientation: all[(index + 1) % all.count])
    }

    /// The scale that fits the device in `available` points (at most 1),
    /// as Chrome's device mode fits a device bigger than its view.
    /// Whole percent, rounded down, as Chrome's `calculateFitScale`.
    public func fitScale(in available: CGSize) -> CGFloat {
        guard available.width > 0, available.height > 0 else { return 1 }
        let scale = min(1, available.width / size.width, available.height / size.height)
        return max(0.01, (scale * 100).rounded(.down) / 100)
    }
}

/// The device list: the built-in devices, then the person's custom devices.
public nonisolated struct BrowserDevices: Sendable {
    public let builtIn: [BrowserDevice]
    public let custom: [BrowserDevice]
    /// Why the custom file did not read, if it did not.
    public let customError: String?

    /// The custom device file's name, next to cmux.json.
    public static let customFileName = "browser-devices.json"

    /// The built-in list from the module's data file.
    public static var builtInDevices: [BrowserDevice] { builtInFile.devices }

    /// The Chrome version an Android device's user agent names in a WebKit
    /// tab: the reduced form of the Chromium the list comes from ("154.0.0.0").
    static var chromeVersionForWebKit: String {
        builtInFile.chrome?.chromium.flatMap { $0.isEmpty ? nil : "\($0).0.0.0" } ?? ""
    }

    private static let builtInFile: DataFile = {
        guard let url = Bundle.module.url(forResource: "EmulatedDevices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var file = try? JSONDecoder().decode(DataFile.self, from: data) else { return DataFile(devices: []) }
        file.devices = file.devices.filter(\.isValid)
        return file
    }()

    struct DataFile: Decodable {
        var devices: [BrowserDevice]
        var chrome: Chrome?

        struct Chrome: Decodable {
            var chromium: String?
        }
    }

    /// Reads the built-in list and `customFile` (a JSON array of Chrome
    /// JSONV1 devices, or `{"devices": [...]}`). As Chrome, a device that does
    /// not read or is out of range is left out alone; `customError` says
    /// which. A missing file is no custom devices.
    public static func load(customFile: URL?) -> BrowserDevices {
        var custom: [BrowserDevice] = []
        var problems: [String] = []
        if let customFile, let data = try? Data(contentsOf: customFile) {
            let top = try? JSONSerialization.jsonObject(with: data)
            let entries = (top as? [Any]) ?? ((top as? [String: Any])?["devices"] as? [Any])
            if let entries {
                for (index, entry) in entries.enumerated() {
                    do {
                        let json = try JSONSerialization.data(withJSONObject: entry)
                        var device = try JSONDecoder().decode(BrowserDevice.self, from: json)
                        device.origin = nil
                        guard device.isValid else {
                            problems.append("#\(index + 1) \(device.title): sizes must be 50...9999, pixel ratio up to 10")
                            continue
                        }
                        custom.append(device)
                    } catch {
                        problems.append("#\(index + 1): \(error)")
                    }
                }
            } else {
                problems.append("not a JSON array of devices or {\"devices\": [...]}")
            }
        }
        return BrowserDevices(builtIn: builtInDevices, custom: custom, customError: problems.isEmpty ? nil : problems.joined(separator: "\n"))
    }

    public var all: [BrowserDevice] { custom + builtIn }

    /// Built-in devices of `category` in Chrome's order (order, then title).
    public func builtIn(_ category: BrowserDevice.Category, defaultVisibleOnly: Bool) -> [BrowserDevice] {
        builtIn.filter { $0.category == category && (!defaultVisibleOnly || $0.showByDefault != false) }
            .sorted { lhs, rhs in
                let (a, b) = (lhs.order ?? 0, rhs.order ?? 0)
                return a != b ? a < b : lhs.title < rhs.title
            }
    }

    /// The device named `name`: an exact title first (custom devices win),
    /// then a case- and space-insensitive match.
    public func device(named name: String) -> BrowserDevice? {
        if let exact = all.first(where: { $0.title == name }) { return exact }
        let key = Self.key(name)
        return all.first { Self.key($0.title) == key }
    }

    private static func key(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" }
    }
}

/// A tab whose engine can emulate a device. Chromium takes DevTools'
/// `Emulation.*` (as Chrome's device mode); WebKit gets the closest it has
/// (view size, scale factor, user agent).
@MainActor
public protocol BrowserDeviceEmulating: AnyObject {
    /// The device the tab emulates, nil for none.
    var deviceEmulation: BrowserDeviceEmulation? { get }
    /// Applies `emulation` (nil stops emulating) and keeps it across navigations.
    func setDeviceEmulation(_ emulation: BrowserDeviceEmulation?)
}
