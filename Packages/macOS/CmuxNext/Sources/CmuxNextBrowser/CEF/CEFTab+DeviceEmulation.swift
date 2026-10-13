import AppKit
import Foundation

extension CEFTab: BrowserDeviceEmulating {
    public func setDeviceEmulation(_ emulation: BrowserDeviceEmulation?) {
        deviceEmulation = emulation
        deviceEmulationScale = nil
        applyDeviceEmulation()
    }

    /// Sends the tab's emulation (or its reset) to the page; the overrides
    /// live in the browser-side DevTools session, so they hold across
    /// navigations, also cross-process ones. Called again when the browser
    /// is created (`attach`) and when the page area changes size (the fit
    /// scale). One worker sends the newest state only: a live resize that
    /// changes the scale on every frame does not queue a call set per frame.
    func applyDeviceEmulation() {
        guard let browserID, !isClosed else { return }
        guard deviceEmulation != nil || deviceEmulationApplied else { return }
        deviceEmulationDirty = true
        guard deviceEmulationTask == nil else { return }
        let runtime = runtime
        deviceEmulationTask = Task { [weak self] in
            while let self, self.deviceEmulationDirty, !self.isClosed {
                self.deviceEmulationDirty = false
                let emulation = self.deviceEmulation
                let scale = emulation.map { $0.fitScale(in: self.container.pageViewportFrame.size) } ?? 1
                self.deviceEmulationScale = scale
                self.deviceEmulationApplied = emulation != nil
                for (method, params) in await CEFDeviceEmulation.calls(emulation, scale: scale, browser: browserID, runtime: runtime) {
                    do {
                        _ = try await runtime.devTools(browserID, method: method, params: params)
                    } catch {
                        runtime.logger.error("device emulation \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            self?.deviceEmulationTask = nil
        }
    }

    /// The page area changed size: refit a device that no longer fits (or now fits better).
    func deviceEmulationViewDidResize() {
        guard let emulation = deviceEmulation else { return }
        guard emulation.fitScale(in: container.pageViewportFrame.size) != deviceEmulationScale else { return }
        applyDeviceEmulation()
    }
}

/// Chrome's device mode in DevTools protocol calls, the same calls Chrome's
/// DevTools front end sends (DeviceModeModel.calculateAndEmulate,
/// EmulationModel.updateTouch, MultitargetNetworkManager.setUserAgentOverride).
@MainActor
enum CEFDeviceEmulation {
    /// The browser's Chrome version as DevTools reads it (the "Chrome/x"
    /// token of the default user agent, read once before any override).
    private static var chromeVersion: String?

    static func calls(_ emulation: BrowserDeviceEmulation?, scale: CGFloat, browser: Int32,
                      runtime: CEFRuntime) async -> [(String, [String: Any])] {
        guard let emulation else {
            return [
                ("Emulation.clearDeviceMetricsOverride", [:]),
                ("Emulation.setUserAgentOverride", ["userAgent": ""]),
                ("Emulation.setTouchEmulationEnabled", ["enabled": false]),
                ("Emulation.setEmitTouchEventsForMouse", ["enabled": false]),
            ]
        }
        let version = await version(browser: browser, runtime: runtime)
        return calls(emulation, scale: scale, chromeVersion: version)
    }

    nonisolated static func calls(_ emulation: BrowserDeviceEmulation, scale: CGFloat,
                                  chromeVersion: String) -> [(String, [String: Any])] {
        let device = emulation.device
        let size = emulation.size
        let portrait = emulation.orientation.isPortrait
        var metrics: [String: Any] = [
            "width": Int(size.width), "height": Int(size.height),
            "deviceScaleFactor": device.screen.devicePixelRatio,
            "mobile": device.mobile, "scale": Double(scale),
            "screenWidth": Int(size.width), "screenHeight": Int(size.height),
            "positionX": 0, "positionY": 0,
            // The view keeps the pane's size (DevTools sends it too): without
            // it Chromium resizes the page's view to the device size.
            "dontSetVisibleSize": true,
            "screenOrientation": ["type": portrait ? "portraitPrimary" : "landscapePrimary", "angle": portrait ? 0 : 90],
        ]
        if let hinge = emulation.hinge {
            let vertical = emulation.orientation == .verticalSpanned
            metrics["displayFeature"] = [
                "orientation": vertical ? "vertical" : "horizontal",
                "offset": vertical ? hinge.x : hinge.y, "maskLength": vertical ? hinge.width : hinge.height,
            ]
            metrics["devicePosture"] = ["type": "folded"]
        } else {
            metrics["devicePosture"] = ["type": "continuous"]
        }
        var userAgent: [String: Any] = ["userAgent": device.userAgent(chromeVersion: chromeVersion)]
        // DevTools sends metadata only with a user agent (setUserAgentOverride).
        if let meta = device.userAgentMetadata, !device.userAgent.isEmpty {
            userAgent["userAgentMetadata"] = [
                "platform": meta.platform, "platformVersion": meta.platformVersion,
                "architecture": meta.architecture, "model": meta.model, "mobile": meta.mobile,
            ]
        }
        let touch = device.touch
        return [
            ("Emulation.setDeviceMetricsOverride", metrics),
            ("Emulation.setUserAgentOverride", userAgent),
            ("Emulation.setTouchEmulationEnabled", touch ? ["enabled": true, "maxTouchPoints": 1] : ["enabled": false]),
            ("Emulation.setEmitTouchEventsForMouse", ["enabled": touch, "configuration": device.mobile ? "mobile" : "desktop"]),
        ]
    }

    /// Chrome's reduced version ("154.0.0.0"): the default user agent from
    /// `Browser.getVersion` (not the page's, which a page can change), else
    /// the Chromium milestone the device list comes from. Never empty, so a
    /// device's "%s" is always replaced.
    private static func version(browser: Int32, runtime: CEFRuntime) async -> String {
        if let chromeVersion { return chromeVersion }
        if let json = try? await runtime.devTools(browser, method: "Browser.getVersion"),
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let agent = object["userAgent"] as? String,
           let range = agent.range(of: #"Chrome/[0-9.]+"#, options: .regularExpression) {
            let version = String(agent[range].dropFirst("Chrome/".count))
            chromeVersion = version
            return version
        }
        return BrowserDevices.chromeVersionForWebKit
    }
}
