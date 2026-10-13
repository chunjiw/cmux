import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockShortcutRoutingTests {
    @Test("Ctrl-Tab alternates target the focused Dock")
    @MainActor
    func controlTabAlternatesTargetFocusedDock() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                let mainPanelBefore = harness.mainWorkspace.focusedPanelId
                KeyboardShortcutSettings.setShortcut(.unbound, for: .nextSurface)
                KeyboardShortcutSettings.setShortcut(.unbound, for: .prevSurface)

                let next = DockRoutingStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                #expect(Self.dispatch(next, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)

                let previous = DockRoutingStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: true,
                    option: false,
                    control: true
                )
                #expect(Self.dispatch(previous, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)
                #expect(harness.mainWorkspace.focusedPanelId == mainPanelBefore)
            }
        }
    }

    @Test("Binding Ctrl-Tab to another action takes it from the surface step")
    @MainActor
    func controlTabBoundElsewhereDisplacesAlternate() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                _ = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)

                let controlTab = DockRoutingStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                KeyboardShortcutSettings.setShortcut(controlTab, for: .toggleTerminalCopyMode)

                #expect(KeyboardShortcutSettings.shortcut(for: .nextSurfaceAlternate).isUnbound)
                _ = Self.dispatch(controlTab, in: harness)
                #expect(harness.dock.focusedPanelId == firstPanel)
            }
        }
    }

    @Test("Unbinding the Ctrl-Tab alternate leaves Ctrl-Tab unhandled")
    @MainActor
    func unboundAlternateLeavesControlTabUnhandled() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                _ = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                KeyboardShortcutSettings.setShortcut(.unbound, for: .nextSurfaceAlternate)

                let controlTab = DockRoutingStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                #expect(!Self.dispatch(controlTab, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)
            }
        }
    }

    @Test("Rebinding the Ctrl-Tab alternate moves the surface step to the new key")
    @MainActor
    func reboundAlternateStepsOnItsNewKey() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let firstPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                let secondPanel = try #require(
                    harness.dock.newSurface(kind: .terminal, inPane: harness.rootPane, focus: true)
                )
                harness.dock.focusPanel(firstPanel)
                let customShortcut = Self.customShortcut(key: "y")
                KeyboardShortcutSettings.setShortcut(customShortcut, for: .nextSurfaceAlternate)

                let controlTab = DockRoutingStoredShortcut(
                    key: "\t",
                    command: false,
                    shift: false,
                    option: false,
                    control: true
                )
                #expect(!Self.dispatch(controlTab, in: harness))
                #expect(harness.dock.focusedPanelId == firstPanel)
                #expect(Self.dispatch(customShortcut, in: harness))
                #expect(harness.dock.focusedPanelId == secondPanel)
            }
        }
    }
}
