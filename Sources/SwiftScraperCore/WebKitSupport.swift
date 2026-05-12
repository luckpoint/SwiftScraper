import AppKit
import Foundation
import WebKit

@MainActor
enum WebKitSupport {
    static func websiteDataStore(for mode: DataStoreMode) -> WKWebsiteDataStore {
        switch mode {
        case .ephemeral:
            return .nonPersistent()
        case .persistent:
            return .default()
        }
    }

    static func frame(for viewport: Viewport) -> NSRect {
        NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height)
    }

    static func makeWebView(frame: NSRect, configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.setFrameSize(frame.size)
        return webView
    }

    static func load(
        _ url: URL,
        in webView: WKWebView,
        timeout: TimeInterval,
        headers: [String: String]
    ) {
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            webView.load(request)
        }
    }
}

enum JavaScriptLiteral {
    static func encoded(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func string(_ value: String) -> String {
        do {
            return try encoded(value)
        } catch {
            preconditionFailure("String JSON encoding should not fail: \(error)")
        }
    }
}

extension WKHTTPCookieStore {
    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            setCookie(cookie) {
                continuation.resume()
            }
        }
    }

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    func deleteCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delete(cookie) {
                continuation.resume()
            }
        }
    }
}

@MainActor
final class WebViewPresentation: NSObject, NSWindowDelegate {
    enum VisibleActivation {
        case orderFront
        case activateApplication
    }

    private let visibility: VisibilityMode
    private let visibleActivation: VisibleActivation
    private let window: NSWindow?

    init(
        visibility: VisibilityMode,
        title: String,
        frame: NSRect,
        webView: WKWebView,
        visibleActivation: VisibleActivation = .orderFront,
        collectionBehavior: NSWindow.CollectionBehavior? = nil,
        hidesOnClose: Bool = false
    ) {
        self.visibility = visibility
        self.visibleActivation = visibleActivation

        let createdWindow: NSWindow?
        switch visibility {
        case .windowless:
            createdWindow = nil
        case .hiddenWindow, .visibleWindow:
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = title
            window.contentView = NSView(frame: frame)
            window.contentView?.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(webView)
            webView.frame = window.contentView?.bounds ?? frame
            webView.autoresizingMask = [.width, .height]
            if let collectionBehavior {
                window.collectionBehavior = collectionBehavior
            }
            createdWindow = window
        }

        self.window = createdWindow
        super.init()
        if hidesOnClose {
            self.window?.delegate = self
        }
    }

    func activateIfNeeded() {
        switch visibility {
        case .windowless:
            return
        case .hiddenWindow:
            window?.orderOut(nil)
        case .visibleWindow:
            switch visibleActivation {
            case .orderFront:
                window?.makeKeyAndOrderFront(nil)
            case .activateApplication:
                window?.center()
                window?.level = .normal
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func deactivate() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
    }

    func resize(to size: NSSize) {
        guard let window else {
            return
        }

        window.setContentSize(size)
        window.contentView?.frame.size = size
        window.contentView?.subviews.forEach { subview in
            subview.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: size)
        }
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in
            sender.orderOut(nil)
        }
        return false
    }
}
