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
        case .gemini: return isZh ? "Gemini 网页登录授权" : "Gemini Web Login"
        case .aliyun: return isZh ? "阿里云百炼控制台网页登录授权" : "Aliyun Bailian Console Web Login"
        }
    }

    var initialURL: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/login")!
        case .gemini: return URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/cloud-platform%20https://www.googleapis.com/auth/userinfo.email")!
        case .aliyun: return URL(string: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan")!
        }
    }
}

public class WebLoginWindowController: NSWindowController, WKNavigationDelegate {
    public static var current: WebLoginWindowController?

    private var webView: WKWebView!
    private var provider: LoginProvider
    private var completion: (String?) -> Void
    private var progressBar: NSProgressIndicator!
    /// completion 只能触发一次：didFinish 每次导航都会来，Google 登录流程有多次导航，
    /// 以前 Gemini 分支既不关窗也不去重，调用方会被重复回调、重复保存、重复刷新。
    private var hasCompleted = false

    public init(provider: LoginProvider, completion: @escaping (String?) -> Void) {
        self.provider = provider
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

        progressBar = NSProgressIndicator(frame: NSRect(x: 0, y: window.contentView!.bounds.height - 3, width: window.contentView!.bounds.width, height: 3))
        progressBar.autoresizingMask = [.width, .minYMargin]
        progressBar.isIndeterminate = true
        progressBar.style = .bar

        window.contentView?.addSubview(webView)
        window.contentView?.addSubview(progressBar)

        progressBar.startAnimation(nil)
        let request = URLRequest(url: provider.initialURL)
        webView.load(request)
    }

    /// 唯一的完成出口：去重 + 关窗
    private func finish(with value: String) {
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(value)
        close()
    }

    public static func show(provider: LoginProvider, completion: @escaping (String?) -> Void) {
        let controller = WebLoginWindowController(provider: provider, completion: completion)
        WebLoginWindowController.current = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.isHidden = false
        progressBar.startAnimation(nil)
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
            // 拿去调 API 只会得到 401。Gemini 只认下面 OOB 流程里的授权码。
        }

        // For Google OAuth OOB flow, detect authorization code on screen
        if provider == .gemini {
            webView.evaluateJavaScript("document.querySelector('input[type=\"text\"]')?.value || document.querySelector('textarea')?.value || document.title") { [weak self] result, _ in
                guard let self = self, let text = result as? String else { return }
                if text.starts(with: "4/") && text.count > 20 {
                    self.finish(with: text)
                }
            }
        }
    }
}
