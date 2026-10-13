import AppKit
import WebKit

/// Device emulation in WebKit, the closest WebKit has to Chrome's device
/// mode (what Safari's Responsive Design Mode sets): the page's viewport
/// size (the web view's size, `WebKitPageContainer.emulatedSize`), the
/// device pixel ratio (`_overrideDeviceScaleFactor` SPI, checked first) and
/// the user agent (`customUserAgent`).
///
/// WebKit on macOS cannot emulate the rest, so those fields do nothing in a
/// WebKit tab: client hints (`navigator.userAgentData`, Sec-CH-UA; WebKit has
/// neither), touch input and `(pointer: coarse)`/`(hover: none)`, the mobile
/// flag (meta viewport layout, overlay scrollbars, text autosizing), screen
/// orientation (`screen.orientation`, `screen.width`), and a foldable's
/// hinge (display feature, device posture).
extension WebKitTab: BrowserDeviceEmulating {
    public func setDeviceEmulation(_ emulation: BrowserDeviceEmulation?) {
        if deviceEmulation == nil, emulation != nil { userAgentBeforeEmulation = webView.customUserAgent }
        deviceEmulation = emulation
        let container = contentView as? WebKitPageContainer
        container?.emulatedSize = emulation?.size
        setOverrideDeviceScaleFactor(emulation.map { CGFloat($0.device.screen.devicePixelRatio) } ?? 0)
        if let emulation {
            let agent = emulation.device.userAgent(chromeVersion: BrowserDevices.chromeVersionForWebKit)
            webView.customUserAgent = agent.isEmpty ? userAgentBeforeEmulation : agent
        } else {
            webView.customUserAgent = userAgentBeforeEmulation
            userAgentBeforeEmulation = nil
        }
    }

    /// 0 clears the override (the window's backing scale again).
    private func setOverrideDeviceScaleFactor(_ factor: CGFloat) {
        guard webView.responds(to: NSSelectorFromString("_setOverrideDeviceScaleFactor:")) else { return }
        webView.setValue(factor, forKey: "overrideDeviceScaleFactor") // KVC finds _setOverrideDeviceScaleFactor:
    }
}
