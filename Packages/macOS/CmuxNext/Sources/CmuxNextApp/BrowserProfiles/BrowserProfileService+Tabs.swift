import CmuxNextActions
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Moving and duplicating a tab into another browser profile. A page's
/// session state (cookies, logins, storage, back/forward history) belongs to
/// its profile's store, so only the URL goes to the target; a move keeps the
/// tab and reloads its page there, a duplicate opens a new tab (data-model.md 5).
extension BrowserProfileService {
    /// Moves `tab` to `profile` in place: the record names it (`frontend-browser-tab-profile-v1`), then the page
    /// is re-made in its store (`recreatePage`). Another machine's tab or an older daemon: the old reopen.
    func move(_ tab: TabModel, in pane: PaneModel, to profile: String, notice: String?) {
        let daemon = services.machines.daemon(forTab: tab)
        guard daemon.isLocal, daemon.supports(DaemonCapabilities.shared.frontendBrowserTabProfile) else {
            return reopen(tab, in: pane, profile: profile, closingOriginal: true, notice: notice)
        }
        let (key, surface, cache, url) = (tab.id, tab.surface, services.cache, URL(string: currentURL(of: tab)) ?? StaticURL.blank.url)
        services.registry.track(Task { @MainActor [weak self] in
            if let failed = await daemon.failure("set-frontend-browser-tab-profile", {
                try await $0.setFrontendBrowserTabProfile(surface, profileID: profile)
            }) { return failed }
            // The page's store comes from the record: wait for the mirror to show it.
            guard await ObservedCondition(owner: "BrowserProfileService.move", deadline: .seconds(5)).wait({
                (cache.tabModel(key)?.snapshot.browserProfileID ?? BrowserProfileRecord.defaultID) == profile
            }), let self else { return "set-frontend-browser-tab-profile: the moved tab was not reported back" }
            if let notice { cache.browserTabs.setNotice(notice, forKey: key) }  // the new page shows it
            cache.recreatePage(key, in: book.engineProfile(for: profile), url: url)
            refreshPresentation()
            return nil
        })
    }

    /// Reopens `tab`'s current URL in `profile` on the same engine in the
    /// same pane, then (when `closingOriginal`) closes the original once the
    /// new tab exists, so a pane never empties.
    func reopen(_ tab: TabModel, in pane: PaneModel, profile: String, closingOriginal: Bool, notice: String?) {
        let url = currentURL(of: tab)
        let originalID = tab.id
        let registry = services.registry
        let close: @MainActor (SurfaceID) -> Void = { _ in
            guard closingOriginal else { return }
            registry.perform("closeTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: originalID)))
        }
        if let controller = services.paneController(for: pane) {
            controller.newBrowserTab(url: URL(string: url), inherited: tab.browserEngine, profile: profile, notice: notice, then: close)
            return
        }
        // The pane is not on screen: create the tab there directly.
        let browserTabs = services.cache.browserTabs
        guard case .open(let choice) = browserTabs.resolve(requested: nil, inherited: tab.browserEngine) else { return }
        services.registry.track(Task {
            do {
                let surface = try await browserTabs.open(choice, in: pane, url: url, profile: profile, notice: notice)
                close(surface)
                return nil
            } catch {
                return "new-frontend-browser-tab: \(error)"
            }
        })
    }

    /// The URL a reopened copy starts on: the live page's, else the record's.
    func currentURL(of tab: TabModel) -> String {
        services.cache.existingBrowser(tab.id)?.tab.state.url?.absoluteString
            ?? services.cache.browserTabs.lastURL(for: tab)
            ?? BrowserNewTabPage.blankURL
    }

    /// Checks that `tab` can move to `profile`: a normal browser tab in
    /// another profile.
    func requireMovable(_ tab: TabModel, to profile: String, allowSame: Bool) throws {
        guard tab.kind == .browser, tab.isFrontendOwned else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.notBrowserTab) }
        guard !services.cache.browserTabs.isIncognitoTab(tab.id) else { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.incognitoTab) }
        if !allowSame, profileID(ofTab: tab) == profile { throw ActionFailure.invalidTarget(BrowserProfileAppStrings.alreadyInProfile) }
    }
}
