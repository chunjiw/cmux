// Window styles (`appearance.chromeStyle`, `ChromeStyle`): one palette
// action per style, every title starting with "Window Style:" so typing it
// lists them all. Titles live in SettingsActions.xcstrings. Settings
// changes with no object: no context menu; MCP leaves them to the person.

nonisolated enum ChromeStyleActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            style("default", t("action.appearance.chromeStyle.default", "Window Style: Default"), symbol: "macwindow",
                  keywords: ["default", "reset"]),
            style("card", t("action.appearance.chromeStyle.card", "Window Style: Card"), symbol: "rectangle.inset.filled",
                  keywords: ["card", "rounded", "curved", "dividers", "minimal"]),
            style("cardOutlined", t("action.appearance.chromeStyle.cardOutlined", "Window Style: Card with Outlines"),
                  symbol: "rectangle.split.2x1", keywords: ["card", "outlined", "outline", "borders"], cli: "card-outlined"),
            style("flat", t("action.appearance.chromeStyle.flat", "Window Style: Flat"), symbol: "rectangle",
                  keywords: ["flat", "edge", "dividers", "minimal"]),
            style("flatSidebarLine", t("action.appearance.chromeStyle.flatSidebarLine", "Window Style: Flat with Sidebar Line"),
                  symbol: "sidebar.left", keywords: ["flat", "sidebar", "line", "border"], cli: "flat-sidebar-line"),
            style("bare", t("action.appearance.chromeStyle.bare", "Window Style: Bare"), symbol: "rectangle.dashed",
                  keywords: ["bare", "no lines", "borderless", "seamless", "minimal"]),
            style("panes", t("action.appearance.chromeStyle.panes", "Window Style: Panes"), symbol: "square.grid.2x2",
                  keywords: ["panes", "cards", "outlined", "gaps", "borders"]),
            style("twoTone", t("action.appearance.chromeStyle.twoTone", "Window Style: Two-Tone"), symbol: "rectangle.lefthalf.filled",
                  keywords: ["two-tone", "shade", "sidebar", "background", "card"], cli: "two-tone"),
        ]
    }

    /// `appearance.chromeStyle.<name>`; the CLI verb is
    /// `settings window-style-<value>`.
    private static func style(_ name: String, _ title: String, symbol: String, keywords: [String],
                              cli: String? = nil) -> ActionDescriptor {
        ActionDescriptor(
            id: ActionID(rawValue: "appearance.chromeStyle.\(name)"), title: title,
            keywords: ["window", "style", "chrome", "appearance", "look"] + keywords, category: .settings, symbol: symbol,
            surfaces: [.palette], cliName: "settings window-style-\(cli ?? name)",
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .noObject, mcpExemption: .systemChange)
        )
    }

    private static func t(_ key: StaticString, _ english: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: english, table: "SettingsActions", bundle: .module)
    }
}
