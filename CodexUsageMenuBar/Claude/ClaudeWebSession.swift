import AppKit
import SwiftUI
import WebKit

/// A private, app-owned browser session. WebKit persists and sends its cookies;
/// native code never imports another application's credentials or reads cookies.
@MainActor
final class ClaudeWebUsageAdapter: NSObject, ObservableObject, ClaudeUsageProviding, WKNavigationDelegate, WKUIDelegate {
    typealias Evaluation = @MainActor () async throws -> [String: Any]
    struct Organization: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static let shared = ClaudeWebUsageAdapter()
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isChecking = false
    @Published private(set) var isDisconnecting = false
    @Published private(set) var statusText = "Sign in with email below, then check the connection."
    @Published private(set) var organizations: [Organization] = []
    @Published private(set) var organizationID: String
    var onRefresh: (() -> Void)?
    var onIdentityChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let evaluation: Evaluation?
    private var browser: WKWebView?
    private var connectionWindow: NSWindow?
    private var blockedUntil: Date?
    private var generation = 0
    private var pageWaiter: CheckedContinuation<Void, Error>?
    private var pageTimeout: Task<Void, Never>?
    private var scriptWaiter: CheckedContinuation<[String: Any], Error>?
    private var scriptTimeout: Task<Void, Never>?
    private var activeScript: UUID?

    init(defaults: UserDefaults = .standard, evaluate: Evaluation? = nil) {
        self.defaults = defaults
        self.evaluation = evaluate
        isEnabled = defaults.bool(forKey: "claudeWebConnectionEnabled")
        organizationID = defaults.string(forKey: "claudeWebOrganizationID") ?? ""
        super.init()
    }

    func fetchUsage(allowInteraction: Bool) async throws -> ClaudeUsageSnapshot {
        // Refresh never initiates sign-in or opens a window, even on user action.
        guard isEnabled else { throw ClaudeUsageAPIError.signInRequired }
        if let blockedUntil, blockedUntil > Date() { throw ClaudeUsageAPIError.rateLimited }
        guard !isChecking else { throw CancellationError() }
        isChecking = true
        let currentGeneration = generation
        defer { isChecking = false }
        do {
            let payload: [String: Any]
            if let evaluation { payload = try await evaluation() }
            else { payload = try await evaluateUsage() }
            try Task.checkCancellation()
            guard generation == currentGeneration, isEnabled else { throw CancellationError() }
            switch payload["kind"] as? String {
            case "usage":
                guard let id = payload["organizationID"] as? String, UUID(uuidString: id) != nil,
                      let used = payload["utilization"] as? Double, used.isFinite, (0...100).contains(used)
                else { throw ClaudeUsageAPIError.invalidResponse }
                let window: ClaudeUsageSnapshot.UsageWindow
                if payload["state"] as? String == "notStarted" {
                    guard used == 0, payload["resetsAt"] is NSNull else { throw ClaudeUsageAPIError.invalidResponse }
                    window = .init(usedPercentage: 0, resetsAt: nil, state: .notStarted)
                } else {
                    guard let rawReset = payload["resetsAt"] as? String else { throw ClaudeUsageAPIError.invalidResponse }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    var reset = formatter.date(from: rawReset)
                    if reset == nil {
                        formatter.formatOptions = [.withInternetDateTime]
                        reset = formatter.date(from: rawReset)
                    }
                    guard let reset, reset > Date() else { throw ClaudeUsageAPIError.noWindow }
                    window = .init(usedPercentage: used, resetsAt: reset)
                }
                organizationID = id
                defaults.set(id, forKey: "claudeWebOrganizationID")
                statusText = "Connected. Usage refreshes through this app's Claude session."
                return ClaudeUsageSnapshot(version: 3, updatedAt: Date(), rateLimits: .init(fiveHour: window))
            case "organizations":
                organizations = (payload["organizations"] as? [[String: Any]] ?? []).compactMap { item in
                    guard let id = item["id"] as? String, UUID(uuidString: id) != nil,
                          let name = item["name"] as? String else { return nil }
                    return Organization(id: id, name: String(name.prefix(120)))
                }
                guard !organizations.isEmpty else { throw ClaudeUsageAPIError.invalidResponse }
                throw ClaudeUsageAPIError.organizationSelectionRequired
            case "signIn": throw ClaudeUsageAPIError.signInRequired
            case "noUsageOrganization": throw ClaudeUsageAPIError.noUsageOrganization
            case "verification": throw ClaudeUsageAPIError.webVerificationRequired
            case "rateLimited":
                let seconds = payload["retryAfter"] as? Double ?? 300
                blockedUntil = Date().addingTimeInterval(seconds.isFinite ? min(3600, max(60, seconds)) : 300)
                throw ClaudeUsageAPIError.rateLimited
            case "noWindow": throw ClaudeUsageAPIError.noWindow
            case "network": throw ClaudeUsageAPIError.network
            case "server": throw ClaudeUsageAPIError.server(payload["status"] as? Int ?? 503)
            default: throw ClaudeUsageAPIError.invalidResponse
            }
        } catch {
            guard generation == currentGeneration else { throw CancellationError() }
            if error is CancellationError { throw error }
            let safeError = (error as? ClaudeUsageAPIError) ?? .network
            statusText = safeError.errorDescription ?? "The Claude connection could not be checked."
            throw safeError
        }
    }

    func showConnectionWindow() {
        guard !isDisconnecting else { return }
        isEnabled = true
        defaults.set(true, forKey: "claudeWebConnectionEnabled")
        if let window = connectionWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if browser?.url?.host != "claude.ai" { loadSignIn() }
            return
        }
        let webView = makeBrowser()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Connect Claude — Brim"
        window.minSize = NSSize(width: 640, height: 500)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ClaudeConnectionView(session: self, browser: webView))
        window.center()
        connectionWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loadSignIn()
    }

    func selectOrganization(_ id: String) {
        guard organizations.contains(where: { $0.id == id }) else { return }
        generation += 1
        organizationID = id
        defaults.set(id, forKey: "claudeWebOrganizationID")
        onIdentityChanged?()
        onRefresh?()
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        isDisconnecting = true
        defer { isDisconnecting = false }
        generation += 1
        isEnabled = false
        defaults.set(false, forKey: "claudeWebConnectionEnabled")
        defaults.removeObject(forKey: "claudeWebOrganizationID")
        organizationID = ""
        organizations = []
        blockedUntil = nil
        statusText = "Disconnected. Click Sign in to reconnect."
        onIdentityChanged?()
        browser?.stopLoading()
        finishPage(.failure(CancellationError()))
        finishScript(.failure(CancellationError()))
        // Clear only this app's WebKit store; other browsers and Claude Code are untouched.
        // Tests with an injected evaluator have no browser store to clear.
        if let browser {
            await withCheckedContinuation { continuation in
                browser.configuration.websiteDataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
                ) { continuation.resume() }
            }
            browser.loadHTMLString("<html><body>Claude disconnected.</body></html>", baseURL: nil)
        }
    }

    func signIn() {
        guard !isDisconnecting, !isChecking else { return }
        generation += 1
        organizationID = ""
        defaults.removeObject(forKey: "claudeWebOrganizationID")
        isEnabled = true
        defaults.set(true, forKey: "claudeWebConnectionEnabled")
        blockedUntil = nil
        onIdentityChanged?()
        loadSignIn()
    }

    private func makeBrowser() -> WKWebView {
        if let browser { return browser }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default() // Persistent and sandboxed to our bundle, not Safari's session.
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        browser = view
        return view
    }

    private func loadSignIn() {
        statusText = "Sign in with email below, then check the connection."
        makeBrowser().load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    private func evaluateUsage() async throws -> [String: Any] {
        let view = makeBrowser()
        if view.url == nil || view.isLoading || !Self.isClaudeOrigin(view.url) {
            try await withCheckedThrowingContinuation { continuation in
                pageWaiter = continuation
                pageTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.finishPage(.failure(ClaudeUsageAPIError.network))
                }
                if !view.isLoading { view.load(URLRequest(url: URL(string: "https://claude.ai/")!)) }
            }
        }
        guard Self.isClaudeOrigin(view.url), isEnabled else { throw ClaudeUsageAPIError.signInRequired }
        guard let url = Bundle.main.url(forResource: "ClaudeWebUsage", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ClaudeUsageAPIError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            activeScript = id
            scriptWaiter = continuation
            scriptTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.finishScript(.failure(ClaudeUsageAPIError.network), id: id)
            }
            view.callAsyncJavaScript(script, arguments: ["organizationID": organizationID],
                                     in: nil, in: .defaultClient) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let value):
                    guard let payload = value as? [String: Any] else {
                        self.finishScript(.failure(ClaudeUsageAPIError.invalidResponse), id: id); return
                    }
                    self.finishScript(.success(payload), id: id)
                case .failure: self.finishScript(.failure(ClaudeUsageAPIError.network), id: id)
                }
            }
        }
    }

    private func finishPage(_ result: Result<Void, Error>) {
        pageTimeout?.cancel()
        pageTimeout = nil
        let waiter = pageWaiter
        pageWaiter = nil
        waiter?.resume(with: result)
    }

    private func finishScript(_ result: Result<[String: Any], Error>, id: UUID? = nil) {
        if let id, activeScript != id { return }
        scriptTimeout?.cancel()
        scriptTimeout = nil
        activeScript = nil
        let waiter = scriptWaiter
        scriptWaiter = nil
        waiter?.resume(with: result)
    }

    static func isClaudeOrigin(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == "claude.ai" && (url?.port == nil || url?.port == 443)
            && url?.user == nil && url?.password == nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Subresources stay under WebKit's normal origin rules; native usage code
        // executes only in the trusted main-frame Claude origin and isolated world.
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        if Self.isClaudeOrigin(navigationAction.request.url) || navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            statusText = "Use email sign-in here. External sign-in providers aren't supported in this preview."
            decisionHandler(.cancel)
            finishPage(.failure(ClaudeUsageAPIError.signInRequired))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishPage(Self.isClaudeOrigin(webView.url) ? .success(()) : .failure(ClaudeUsageAPIError.signInRequired))
        if connectionWindow?.isVisible == true, isEnabled, !isChecking { onRefresh?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        let allowed = Self.isClaudeOrigin(navigationResponse.response.url) && navigationResponse.canShowMIMEType
        decisionHandler(allowed ? .allow : .cancel)
        if !allowed { finishPage(.failure(ClaudeUsageAPIError.signInRequired)) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPage(.failure(ClaudeUsageAPIError.network))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPage(.failure(ClaudeUsageAPIError.network))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishPage(.failure(ClaudeUsageAPIError.network))
        finishScript(.failure(ClaudeUsageAPIError.network))
        browser = nil
        connectionWindow?.close()
        connectionWindow = nil
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.isClaudeOrigin(navigationAction.request.url) { webView.load(navigationAction.request) }
        else { statusText = "Use email sign-in here. External sign-in providers aren't supported in this preview." }
        return nil
    }
}

private struct ClaudeBrowserView: NSViewRepresentable {
    let browser: WKWebView
    func makeNSView(context: Context) -> WKWebView { browser }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ClaudeConnectionView: View {
    @ObservedObject var session: ClaudeWebUsageAdapter
    let browser: WKWebView

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude connection").font(.title2.bold())
                Spacer()
                Button("Sign in") { session.signIn() }.disabled(session.isChecking || session.isDisconnecting)
                Button("Check connection") { session.onRefresh?() }
                    .disabled(session.isChecking || session.isDisconnecting || !session.isEnabled)
                Button("Disconnect") { Task { await session.disconnect() } }.disabled(session.isDisconnecting || !session.isEnabled)
            }
            Text("Sign in using your email. This app keeps its own browser session and never reads Claude Code's Keychain.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                if session.isChecking { ProgressView().controlSize(.small) }
                Text(session.statusText).font(.callout).textSelection(.enabled)
            }
            if !session.organizations.isEmpty {
                Picker("Organization", selection: Binding(get: { session.organizationID }, set: { session.selectOrganization($0) })) {
                    Text("Choose an organization").tag("")
                    ForEach(session.organizations) { Text($0.name).tag($0.id) }
                }.disabled(session.isChecking)
            }
            Divider()
            ClaudeBrowserView(browser: browser)
        }
        .padding(16)
    }
}
