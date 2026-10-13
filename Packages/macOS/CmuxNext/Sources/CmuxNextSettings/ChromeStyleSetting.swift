public import CmuxNextDesign

/// `appearance.chromeStyle` in cmux.json (`ChromeStyle`): one string for the
/// window's look, whose values supply the defaults of the curved main pane,
/// `layout.paneSeparation`, `sidebar.border` and `appearance.sidebarSurface`.
/// A key set in the file still wins over its style. A missing key is
/// `default`; a bad value is `default` plus a diagnostic.
public nonisolated struct ChromeStyleSetting: Sendable {
    public static let configPath = ["appearance", "chromeStyle"]
    public static let fallback: ChromeStyle = .default

    public init() {}

    /// The palette action that switches to `style`.
    public static func actionID(_ style: ChromeStyle) -> String { "appearance.chromeStyle.\(style.actionName)" }

    /// The file value for `style`: the default removes the key.
    public static func fileValue(_ style: ChromeStyle) -> JSONValue? {
        style == fallback ? nil : .string(style.rawValue)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ChromeStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let style = ChromeStyle(rawValue: text) else {
            let choices = ChromeStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return style
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .appearance, group: group,
            title: SettingsText.keyed("settings.appearance.chromeStyle", "Window Style"),
            help: SettingsText.keyed("settings.appearance.chromeStyle.help",
                                     "The look of the window: whether panes sit in one rounded card, and where lines are drawn. Separation, Sidebar Background and the sidebar border still win when you set them."),
            summary: SettingsText.keyed("settings.appearance.chromeStyle.summary", "Card, lines and sidebar background"),
            kind: .choice(ChromeStyle.allCases.map { SettingChoice($0.rawValue, title($0)) }),
            default: .string(fallback.rawValue),
            keywords: ["window", "style", "chrome", "card", "flat", "border", "borders", "lines", "divider", "outline",
                       "seam", "sidebar", "two-tone", "minimal", "bare"]
        )
    }

    static func title(_ style: ChromeStyle) -> SettingText {
        switch style {
        case .default: SettingsText.keyed("settings.choice.chromeStyle.default", "Default")
        case .card: SettingsText.keyed("settings.choice.chromeStyle.card", "Card")
        case .cardOutlined: SettingsText.keyed("settings.choice.chromeStyle.cardOutlined", "Card with Outlines")
        case .flat: SettingsText.keyed("settings.choice.chromeStyle.flat", "Flat")
        case .flatSidebarLine: SettingsText.keyed("settings.choice.chromeStyle.flatSidebarLine", "Flat with Sidebar Line")
        case .bare: SettingsText.keyed("settings.choice.chromeStyle.bare", "Bare")
        case .panes: SettingsText.keyed("settings.choice.chromeStyle.panes", "Panes")
        case .twoTone: SettingsText.keyed("settings.choice.chromeStyle.twoTone", "Two-Tone")
        }
    }
}

extension SettingsApplier {
    /// Copies `appearance.chromeStyle` into `design`, writing only a change.
    static func applyChromeStyle(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        if design.chromeStyle != snapshot.chromeStyle { design.chromeStyle = snapshot.chromeStyle }
    }
}
