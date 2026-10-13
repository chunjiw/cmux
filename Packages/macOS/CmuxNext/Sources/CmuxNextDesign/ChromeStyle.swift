public import CoreGraphics

/// `appearance.chromeStyle` in cmux.json: one easy string for the window's
/// whole look (Lawrence 2026-10-12, "need to be easy string"). Each style is
/// a bundle of DEFAULTS for the finer knobs: the curved main pane, how panes
/// are told apart (`layout.paneSeparation`), the sidebar's edge line
/// (`sidebar.border`) and its surface (`appearance.sidebarSurface`). A key
/// set in cmux.json still wins over its style, and a Debug Settings tunable
/// wins over both.
///
/// - `default`: today's defaults; nothing changes.
/// - `card`: the curved main pane on one color, a line only between panes.
/// - `card-outlined`: the curved main pane, each pane outlined.
/// - `flat`: no card, one color, edge to edge, a line only between panes.
/// - `flat-sidebar-line`: `flat` plus a hairline on the sidebar's edge.
/// - `bare`: no card, one color, no pane lines anywhere.
/// - `panes`: no card, every pane its own outlined rounded card with gaps.
/// - `two-tone`: the curved main pane with a soft separate sidebar shade.
public nonisolated enum ChromeStyle: String, Sendable, CaseIterable, Codable {
    case `default`
    case card
    case cardOutlined = "card-outlined"
    case flat
    case flatSidebarLine = "flat-sidebar-line"
    case bare
    case panes
    case twoTone = "two-tone"

    /// The camel-case name of this style in action ids
    /// (`appearance.chromeStyle.<name>`).
    public var actionName: String {
        switch self {
        case .default: "default"
        case .card: "card"
        case .cardOutlined: "cardOutlined"
        case .flat: "flat"
        case .flatSidebarLine: "flatSidebarLine"
        case .bare: "bare"
        case .panes: "panes"
        case .twoTone: "twoTone"
        }
    }

    /// Whether the workspace content is the curved main pane; nil keeps the
    /// tunable's default.
    public var curvedMainPane: Bool? {
        switch self {
        case .default: nil
        case .card, .cardOutlined, .twoTone: true
        case .flat, .flatSidebarLine, .bare, .panes: false
        }
    }

    /// The pane separation when cmux.json sets none; nil keeps the rule of
    /// `Metrics.defaultPaneSeparation`.
    public var paneSeparation: PaneSeparation? {
        switch self {
        case .default: nil
        case .card, .flat, .flatSidebarLine, .twoTone: .dividers
        case .cardOutlined, .panes: .borders
        case .bare: PaneSeparation.none
        }
    }

    /// Whether the sidebar's edge line shows at rest when `sidebar.border`
    /// is unset.
    public var sidebarBorder: Bool {
        self == .flatSidebarLine
    }

    /// The sidebar surface when `appearance.sidebarSurface` is unset; nil
    /// keeps its default.
    public var sidebarSurface: SidebarSurface? {
        switch self {
        case .default: nil
        case .twoTone: .separate
        case .card, .cardOutlined, .flat, .flatSidebarLine, .bare, .panes: .same
        }
    }

    /// Share of the separate shade a shared surface keeps when no line parts
    /// the sidebar from the main pane: every style but `default` is one
    /// color, with no tonal step.
    public var borderlessStep: CGFloat {
        self == .default ? SidebarSurface.borderlessStep : 0
    }

    /// The separate surface's shade, softer than the tunable's default; nil
    /// keeps the tunable's.
    public func separateShade(isDark: Bool) -> CGFloat? {
        guard self == .twoTone else { return nil }
        return isDark ? 0.12 : 0.02
    }
}
