import AppKit

extension AppDelegate {
    /// Routes adjacent surface navigation and surface/workspace reordering through
    /// the main-window context selected for the key event.
    func handleAdjacentNavigationShortcut(event: NSEvent) -> Bool {
        let routedTabs = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager
            ?? tabManager
        for action: KeyboardShortcutSettings.Action in [.nextSurface, .prevSurface]
        where matchConfiguredShortcut(event: event, action: action) {
            stepTabOrWorkspace(action, tabManager: routedTabs, event: event)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceLeft) {
            if performFocusedDockShortcut(
                .moveSurface(offset: -1),
                action: .moveSurfaceLeft,
                event: event
            ) {
                return true
            }
            routedTabs?.selectedWorkspace?.moveSelectedSurface(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveSurfaceRight) {
            if performFocusedDockShortcut(
                .moveSurface(offset: 1),
                action: .moveSurfaceRight,
                event: event
            ) {
                return true
            }
            routedTabs?.selectedWorkspace?.moveSelectedSurface(by: 1)
            return true
        }
        for movement in SurfacePaneMovement.allCases
        where matchesSurfacePaneMovementShortcut(event: event, movement: movement) {
            // Repeats may traverse existing panes but must not recursively create splits.
            if !performSurfacePaneMovement(
                movement,
                tabManager: routedTabs,
                preferredWindow: event.window,
                allowMissingDestinationSplit: !event.isARepeat
            ) {
                NSSound.beep()
            }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceUp) {
            if moveFocusedCloudMachine(by: -1, event: event) { return true }
            routedTabs?.moveSelectedWorkspace(by: -1)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .moveWorkspaceDown) {
            if moveFocusedCloudMachine(by: 1, event: event) { return true }
            routedTabs?.moveSelectedWorkspace(by: 1)
            return true
        }
        return false
    }

    /// Previous/Next from a key (``TabManager/stepTabOrWorkspace(forward:dock:)``), with the Dock
    /// that owns keyboard focus, if any.
    func stepTabOrWorkspace(_ action: KeyboardShortcutSettings.Action, tabManager: TabManager?, event: NSEvent) {
        // Each action is named at its own gate call (tests/test_dock_shortcut_routing_guard.py).
        let window = event.window
        let dock: DockSplitStore?
        switch action {
        case .nextSurface:
            dock = focusedDockStoreForShortcut(action: .nextSurface, preferredWindow: window)
        case .prevSurface:
            dock = focusedDockStoreForShortcut(action: .prevSurface, preferredWindow: window)
        case .nextSurfaceAlternate:
            dock = focusedDockStoreForShortcut(action: .nextSurfaceAlternate, preferredWindow: window)
        case .prevSurfaceAlternate:
            dock = focusedDockStoreForShortcut(action: .prevSurfaceAlternate, preferredWindow: window)
        default:
            assertionFailure("Not a surface step: \(action.rawValue)")
            return
        }
        let forward = action == .nextSurface || action == .nextSurfaceAlternate
        tabManager?.stepTabOrWorkspace(forward: forward, dock: dock)
    }

    /// Reuses the configured workspace reorder keys when a Cloud machine
    /// header owns keyboard focus. Text fields keep their existing key routing.
    func moveFocusedCloudMachine(by offset: Int, event: NSEvent) -> Bool {
        guard let outline = (event.window ?? NSApp.keyWindow)?.firstResponder as? CloudTreeNSOutlineView else { return false }
        return outline.onMoveMachine?(offset) == true
    }

    /// Applies the shared Dock-focus gate used by shortcuts, the command
    /// palette, and the View menu.
    @discardableResult
    func performSurfacePaneMovement(
        _ movement: SurfacePaneMovement,
        tabManager: TabManager?,
        preferredWindow: NSWindow?,
        allowMissingDestinationSplit: Bool = true
    ) -> Bool {
        if let dock = focusedDockStoreForShortcut(
            action: movement.shortcutAction,
            preferredWindow: preferredWindow
        ) {
            return dock.performShortcutCommand(
                .moveSurfaceToPane(
                    movement,
                    allowMissingDestinationSplit:
                        allowMissingDestinationSplit
                )
            )
        }
        return tabManager?.selectedWorkspace?.moveFocusedSurface(
            to: movement,
            allowMissingDestinationSplit: allowMissingDestinationSplit
        ) == true
    }

    private func matchesSurfacePaneMovementShortcut(
        event: NSEvent,
        movement: SurfacePaneMovement
    ) -> Bool {
        let configuredShortcut = KeyboardShortcutSettings.shortcut(
            for: movement.shortcutAction
        )
        let configuredKey =
            configuredShortcut.secondStroke?.key ??
            configuredShortcut.firstStroke.key
        let arrowRoute: (glyph: String, keyCode: UInt16) = switch configuredKey {
        case "→": ("→", 124)
        case "↑": ("↑", 126)
        case "↓": ("↓", 125)
        default: ("←", 123)
        }
        return matchConfiguredDirectionalShortcut(
            event: event,
            action: movement.shortcutAction,
            arrowGlyph: arrowRoute.glyph,
            arrowKeyCode: arrowRoute.keyCode
        )
    }
}
