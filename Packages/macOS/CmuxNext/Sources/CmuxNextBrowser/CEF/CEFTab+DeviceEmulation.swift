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
    /// is created (`attach`) and when the page area changes size (the fit scale).
    func applyDeviceEmulation() {
        guard let browserID, !isClosed else { return }
        let emulation = deviceEmulation
        guard emulation != nil || deviceEmulationApplied else { return }
        let available = (container as BrowserPageViewportProviding).pageViewportFrame.size
        let scale = emulation.map { $0.fitScale(in: available) } ?? 1
        deviceEmulationScale = scale
        deviceEmulationApplied = emulation != nil
        let runtime = runtime
        let previous = deviceEmulationTask
        deviceEmulationTask = Task {
            await previous?.value
            for (method, params) in await CEFDeviceEmulation.calls(emulation, scale: scale, browser: browserID, runtime: runtime) {
                do {
                    _ = try await runtime.devTools(browserID, method: method, params: params)
                } catch {
                    runtime.logger.error("device emulation \(method, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The page area changed size: refit a device that no longer fits (or now fits better).
    func deviceEmulationViewDidResize() {
        guard let emulation = deviceEmulation else { return }
        let available = (container as BrowserPageViewportProviding).pageViewportFrame.size
        guard abs(emulation.fitScale(in: available) - (deviceEmulationScale ?? 0)) > 0.001 else { return }
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

    private static func version(browser: Int32, runtime: CEFRuntime) async -> String {
        if let chromeVersion { return chromeVersion }
        let json = try? await runtime.devTools(browser, method: "Runtime.evaluate",
                                               params: ["expression": "navigator.userAgent", "returnByValue": true])
        guard let json, case .string(let agent)? = try? CEFDevToolsResult.evaluation(json),
              let range = agent.range(of: #"Chrome/[0-9.]+"#, options: .regularExpression) else { return "" }
        let version = String(agent[range].dropFirst("Chrome/".count))
        chromeVersion = version
        return version
    }
}
