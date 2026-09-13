import Cocoa
import WebKit

public enum LoginProvider {
    case claude
    case gemini
    case aliyun

    var title: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        switch self {
        case .claude: return isZh ? "Claude Code 网页登录授权" : "Claude Code Web Login"
        case .gemini: return isZh ? "Gemini Google 账号登录" : "Gemini Google Account Sign-in"
        case .aliyun: return isZh ? "阿里云百炼控制台网页登录授权" : "Aliyun Bailian Console Web Login"
        }
    }

    var initialURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        // 兜底用的旧 OOB 授权页（Google 已停用 OOB，正常流程不会走到这里——
        // Gemini 登录一律由 GeminiService.prepareGoogleLogin 生成 loopback 授权 URL 传入）
        case .gemini: return URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/cloud-platform%20https://www.googleapis.com/auth/userinfo.email")!
        case .aliyun: return URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        }
    }
}

public class WebLoginWindowController: NSWindowController, WKNavigationDelegate {
    public static var current: WebLoginWindowController?

    private var webView: WKWebView!
    private var provider: LoginProvider
    /// Gemini 的 loopback OAuth 授权页 URL（由 GeminiService.prepareGoogleLogin 生成）。
    /// claude / aliyun 不需要，仍走 provider.initialURL。
    private var authorizeURL: URL?
    private var completion: (String?) -> Void
    private var progressBar: NSProgressIndicator!
    /// completion 只能触发一次：didFinish 每次导航都会来，Google 登录流程有多次导航，
    /// 以前 Gemini 分支既不关窗也不去重，调用方会被重复回调、重复保存、重复刷新。
    private var hasCompleted = false

    public init(provider: LoginProvider, authorizeURL: URL? = nil, completion: @escaping (String?) -> Void) {
        self.provider = provider
        self.authorizeURL = authorizeURL
        self.completion = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = provider.title
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let window = self.window else { return }

        let config = WKWebViewConfiguration()
        // 非持久化：登录态只活在这次授权窗口里，不把 Google / Anthropic / 阿里云整站
        // Cookie 落进 App 容器磁盘。我们只需要拿一次凭证，不需要「下次自动登录」。
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        if provider == .gemini {
            // accounts.google.com 按 UA 令牌做浏览器支持性检查：裸 WKWebView 的 UA
            // 不含 Safari/Chrome 版本号，登录页直接判「系统不再支持您的浏览器」
            // （2026-09-13 实测）。伪装成当前版 Safari 是嵌入登录窗的标准做法。
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"
        }

        progressBar = NSProgressIndicator(frame: NSRect(x: 0, y: window.contentView!.bounds.height - 3, width: window.contentView!.bounds.width, height: 3))
        progressBar.autoresizingMask = [.width, .minYMargin]
        progressBar.isIndeterminate = true
        progressBar.style = .bar

        window.contentView?.addSubview(webView)
        window.contentView?.addSubview(progressBar)

        progressBar.startAnimation(nil)
        let target = authorizeURL ?? provider.initialURL
        webView.load(URLRequest(url: target))
    }

    /// 唯一的完成出口：去重 + 关窗
    private func finish(with value: String) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(value)
        close()
    }

    /// 用户直接关窗 / 在授权页点「取消」：按未完成回调，别让调用方的 Task 悬着。
    private func finishCancelled() {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(nil)
        close()
    }

    public static func show(provider: LoginProvider, authorizeURL: URL? = nil, completion: @escaping (String?) -> Void) {
        let controller = WebLoginWindowController(provider: provider, authorizeURL: authorizeURL, completion: completion)
        WebLoginWindowController.current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
    }

    /// Gemini 的 loopback OAuth：Google 授权完成会 302 到 http://localhost:<port>?code=…。
    /// 我们不真的监听那个端口——在导航发出**之前**拦下重定向、从 URL 里取 code 并取消
    /// 导航即可（RFC 8252 loopback 的 WebView 常规做法），因此端口可以完全随机。
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if provider == .gemini,
           let url = navigationAction.request.url,
           url.scheme == "http",
           let host = url.host, host == "localhost" || host == "127.0.0.1" {
            decisionHandler(.cancel)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                finish(with: code)
            } else {
                // error=access_denied 等：视为用户取消
                finishCancelled()
            }
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.stopAnimation(nil)
        progressBar.isHidden = true

        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self = self else { return }

            if self.provider == .claude {
                // Check for sessionKey or claude OAuth cookies
                if cookies.contains(where: { $0.name == "sessionKey" || $0.name.contains("token") || $0.name == "__cf_bm" }) {
                    // Check if logged in
                    webView.evaluateJavaScript("document.cookie") { result, _ in
                        if let cookieStr = result as? String, cookieStr.contains("sessionKey") {
                            for c in cookies where c.name == "sessionKey" {
                                self.finish(with: c.value)
                                return
                            }
                        }
                    }
                }
            } else if self.provider == .aliyun {
                // Check if Aliyun sign-in completed
                if cookies.contains(where: { $0.name.contains("login_aliyunid") || $0.name == "login_aliyunid_ticket" }) {
                    let cookieHeader = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    self.finish(with: cookieHeader)
                }
            }
            // Gemini 不再把 Google 的 SID / SSID 会话 Cookie 当 token 交出去：它们不是 access token，
            // 拿去调 API 只会得到 401。Gemini 的授权码由 decidePolicyFor 的 loopback 拦截收取。
        }
    }
}

extension WebLoginWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        finishCancelled()
    }
}
