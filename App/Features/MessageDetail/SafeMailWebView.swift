import SwiftUI
import WebKit
import MailRendering

/// Only sanitized, in-memory documents enter this web view. No native JS bridge exists.
struct SafeMailWebView: NSViewRepresentable {
    let html: SafeMailHTML
    let dark: Bool
    let allowRemoteImages: Bool
    let openLink: (URL) -> Void
    let failed: () -> Void
    var heightChanged: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(openLink: openLink, failed: failed) }
    func makeNSView(context: Context) -> WKWebView {
        let view = Self.makeWebView()
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setAccessibilityLabel("HTML-Nachricht")
        view.setAccessibilityIdentifier("safe-mail-html")
        return view
    }
    static func makeWebView() -> MailDocumentWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsAirPlayForMediaPlayback = false
        let view = MailDocumentWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = false
        view.allowsLinkPreview = false
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.openLink = openLink; context.coordinator.failed = failed
        context.coordinator.heightChanged = heightChanged
        if let document = view as? MailDocumentWebView {
            document.fitsDocument = heightChanged != nil
            document.widthChanged = { [weak coordinator = context.coordinator, weak view] in
                guard let view else { return }
                coordinator?.measure(view)
            }
        }
        context.coordinator.load(html.document(dark: dark, allowRemoteImages: allowRemoteImages), images: allowRemoteImages, in: view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        coordinator.measureTask?.cancel()
        (view as? MailDocumentWebView)?.widthChanged = nil
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        view.loadHTMLString("", baseURL: nil)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var openLink: (URL) -> Void
        var failed: () -> Void
        var task: Task<Void, Never>?
        var measureTask: Task<Void, Never>?
        var heightChanged: ((CGFloat) -> Void)?
        private var ready = false
        private var loaded: String?
        private(set) var blockedNavigationCount = 0
        init(openLink: @escaping (URL) -> Void, failed: @escaping () -> Void) { self.openLink = openLink; self.failed = failed }
        static func rules(images: Bool) -> String {
            var rules = "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}"
            rules += ",{\"trigger\":{\"url-filter\":\"^data:image/\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}"
            if images { rules += ",{\"trigger\":{\"url-filter\":\"^https://\",\"resource-type\":[\"image\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}" }
            return rules + "]"
        }
        func load(_ document: String, images: Bool, in view: WKWebView) {
            guard loaded != document else { return }
            loaded = document; ready = false; task?.cancel(); measureTask?.cancel(); view.stopLoading(); view.pageZoom = 1
            task = Task { @MainActor [weak self, weak view] in
                do {
                    let rule = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "CuMailResources-\(images ? "images" : "none")-v2", encodedContentRuleList: Self.rules(images: images))
                    guard !Task.isCancelled, let view, let rule else { return }
                    view.configuration.userContentController.removeAllContentRuleLists()
                    view.configuration.userContentController.add(rule)
                    view.loadHTMLString(document, baseURL: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.failed()
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; measure(webView)
        }
        func measure(_ view: WKWebView) {
            guard ready, heightChanged != nil, view.bounds.width > 1 else { return }
            measureTask?.cancel()
            measureTask = Task { @MainActor [weak self, weak view] in
                // Only a fixed, app-owned measurement runs in WebKit's isolated client
                // world. Mail JavaScript stays disabled; there is no script bridge.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let view else { return }
                do {
                    view.pageZoom = 1
                    let width = try await metric("Math.max(document.documentElement.scrollWidth,document.body.scrollWidth)", in: view)
                    guard !Task.isCancelled else { return }
                    if width > view.bounds.width + 1 {
                        view.pageZoom = max(0.5, min(1, view.bounds.width / width))
                    }
                    let height = try await metric("document.body.getBoundingClientRect().height + (parseFloat(getComputedStyle(document.body).marginTop)||0) + (parseFloat(getComputedStyle(document.body).marginBottom)||0)", in: view)
                    guard !Task.isCancelled else { return }
                    self.heightChanged?(min(100_000, max(80, ceil(height * view.pageZoom) + 2)))
                } catch { /* A resize must never replace an otherwise readable email with an error. */ }
            }
        }
        private func metric(_ script: String, in view: WKWebView) async throws -> CGFloat {
            let result = try await view.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
            return (result as? NSNumber)?.doubleValue ?? 0
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
               let checked = MailLinkPolicy.externalURL(url.absoluteString) { openLink(checked) }
            // All clicked links and programmatic external navigations are cancelled in the mail view.
            let ownDocument = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
            if !ownDocument { blockedNavigationCount += 1 }
            return ownDocument ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed() }
    }
}

/// With document height supplied to SwiftUI, the outer reader owns vertical scrolling.
final class MailDocumentWebView: WKWebView {
    var widthChanged: (() -> Void)?
    var fitsDocument = false
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(frame.width - newSize.width) > 1
        super.setFrameSize(newSize)
        if changed { widthChanged?() }
    }
    override func scrollWheel(with event: NSEvent) {
        if fitsDocument, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX), frame.height < 100_000 {
            nextResponder?.scrollWheel(with: event)
        } else { super.scrollWheel(with: event) }
    }
}
