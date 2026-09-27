import SwiftUI

// MARK: - 厂商官方 Logo 路径数据

/// 内置厂商与自定义预设的官方 Logo 矢量路径(24×24 viewBox,单色 glyph)。
/// 路径数据与 Windows 端 `ProviderIcons.cs` 保持同源:
/// 来源 simple-icons(CC0)与 theSVG(MIT),按各厂商主题色/品牌色填充。
public enum ProviderLogo {
    static let openAI = ["M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"]
    static let anthropic = ["M17.3041 3.541h-3.6718l6.696 16.918H24Zm-10.6082 0L0 20.459h3.7442l1.3693-3.5527h7.0052l1.3693 3.5528h3.7442L10.5363 3.5409Zm-.3712 10.2232 2.2914-5.9456 2.2914 5.9456Z"]
    static let gemini = ["M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"]
    static let deepSeek = ["M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45"]
    static let volcengine = ["M7.29 5.36L3.148 21.737a.215.215 0 0 0 .203.261h8.29a.214.214 0 0 0 .215-.261L7.7 5.359a.214.214 0 0 0-.41 0z",
        "m4.553 16.18l-1.406 5.558a.214.214 0 0 0 .203.261h2.42h-4.551a.214.214 0 0 1-.214-.26l2.275-8.961a.214.214 0 0 1 .409 0z",
        "M14.44.15a.214.214 0 0 0-.41 0L8.366 21.739A.214.214 0 0 0 8.58 22H19.9a.214.214 0 0 0 .215-.261z",
        "M16.694 22h3.207a.215.215 0 0 0 .214-.262l-1.839-6.993l1.164-4.592a.214.214 0 0 1 .411 0l2.951 11.586a.214.214 0 0 1-.214.261z",
        "M10.278 7.741L6.685 21.736a.214.214 0 0 0 .214.264h7.17a.216.216 0 0 0 .214-.166a.2.2 0 0 0 0-.098L10.687 7.742a.214.214 0 0 0-.409 0z"]
    static let kimi = ["M21.765.351C22.998.351 24 1.353 24 2.586S22.998 4.82 21.765 4.82h-1.974c-.15 0-.26-.12-.26-.26V2.586A2.237 2.237 0 0 1 21.765.35M9.41 13.388l8.447-8.377c.16-.16.07-.471-.14-.471h-4.55s-.1.02-.14.06l-9.099 9.029c-.14.14-.35.02-.35-.21V4.81c0-.15-.1-.27-.221-.27H.22c-.12 0-.22.12-.22.27v18.57c0 .15.1.27.22.27h3.137c.12 0 .22-.12.22-.27v-3.79c0-.08.03-.16.08-.21l2.826-2.796c.07-.07.16-.08.241-.03l7.546 5.551a8.9 8.9 0 0 0 4.018 1.493c.12.01.23-.11.23-.27V19.76c0-.14-.08-.25-.19-.26a5.8 5.8 0 0 1-2.355-.942l-6.533-4.73c-.14-.09-.15-.32-.03-.441"]
    static let openRouter = ["M16.778 1.844v1.919q-.569-.026-1.138-.032-.708-.008-1.415.037c-1.93.126-4.023.728-6.149 2.237-2.911 2.066-2.731 1.95-4.14 2.75-.396.223-1.342.574-2.185.798-.841.225-1.753.333-1.751.333v4.229s.768.108 1.61.333c.842.224 1.789.575 2.185.799 1.41.798 1.228.683 4.14 2.75 2.126 1.509 4.22 2.11 6.148 2.236.88.058 1.716.041 2.555.005v1.918l7.222-4.168-7.222-4.17v2.176c-.86.038-1.611.065-2.278.021-1.364-.09-2.417-.357-3.979-1.465-2.244-1.593-2.866-2.027-3.68-2.508.889-.518 1.449-.906 3.822-2.59 1.56-1.109 2.614-1.377 3.978-1.466.667-.044 1.418-.017 2.278.02v2.176L24 6.014Z"]
    static let glm = ["M12.606 1.806l-1.677 2.388c-0.258 0.374-0.697 0.606-1.161 0.606h-9.162V1.794C0.594 1.806 12.606 1.806 12.606 1.806zM24 1.806L9.6 22.206 0 22.206 14.4 1.806zM11.394 22.206l1.69-2.4c0.258-0.374 0.697-0.606 1.161-0.606h9.149v3.006H11.394z"]
    static let aliyunCloud = ["M3.996 4.517h5.291L8.01 6.324 4.153 7.506a1.668 1.668 0 0 0-1.165 1.601v5.786a1.668 1.668 0 0 0 1.165 1.6l3.857 1.183 1.277 1.807H3.996A3.996 3.996 0 0 1 0 15.487V8.513a3.996 3.996 0 0 1 3.996-3.996m16.008 0h-5.291l1.277 1.807 3.857 1.182c.715.227 1.17.889 1.165 1.601v5.786a1.668 1.668 0 0 1-1.165 1.6l-3.857 1.183-1.277 1.807h5.291A3.996 3.996 0 0 0 24 15.487V8.513a3.996 3.996 0 0 0-3.996-3.996m-4.007 8.345H8.002v-1.804h7.995Z"]

    // 自定义预设厂商(按名称关键词匹配)
    static let xiaomi = ["M12 0C8.016 0 4.756.255 2.493 2.516.23 4.776 0 8.033 0 12.012c0 3.98.23 7.235 2.494 9.497C4.757 23.77 8.017 24 12 24c3.983 0 7.243-.23 9.506-2.491C23.77 19.247 24 15.99 24 12.012c0-3.984-.233-7.243-2.502-9.504C19.234.252 15.978 0 12 0zM4.906 7.405h5.624c1.47 0 3.007.068 3.764.827.746.746.827 2.233.83 3.676v4.54a.15.15 0 0 1-.152.147h-1.947a.15.15 0 0 1-.152-.148V11.83c-.002-.806-.048-1.634-.464-2.051-.358-.36-1.026-.441-1.72-.458H7.158a.15.15 0 0 0-.151.147v6.98a.15.15 0 0 1-.152.148H4.906a.15.15 0 0 1-.15-.148V7.554a.15.15 0 0 1 .15-.149zm12.131 0h1.949a.15.15 0 0 1 .15.15v8.892a.15.15 0 0 1-.15.148h-1.949a.15.15 0 0 1-.151-.148V7.554a.15.15 0 0 1 .151-.149zM8.92 10.948h2.046c.083 0 .15.066.15.147v5.352a.15.15 0 0 1-.15.148H8.92a.15.15 0 0 1-.152-.148v-5.352a.15.15 0 0 1 .152-.147Z"]
    static let tencentQQ = ["M21.395 15.035a40 40 0 0 0-.803-2.264l-1.079-2.695c.001-.032.014-.562.014-.836C19.526 4.632 17.351 0 12 0S4.474 4.632 4.474 9.241c0 .274.013.804.014.836l-1.08 2.695a39 39 0 0 0-.802 2.264c-1.021 3.283-.69 4.643-.438 4.673.54.065 2.103-2.472 2.103-2.472 0 1.469.756 3.387 2.394 4.771-.612.188-1.363.479-1.845.835-.434.32-.379.646-.301.778.343.578 5.883.369 7.482.189 1.6.18 7.14.389 7.483-.189.078-.132.132-.458-.301-.778-.483-.356-1.233-.646-1.846-.836 1.637-1.384 2.393-3.302 2.393-4.771 0 0 1.563 2.537 2.103 2.472.251-.03.581-1.39-.438-4.673"]
    static let stepFun = ["M22.012 0h1.032v.927H24v.968h-.956V3.78h-1.032V1.896h-1.878v-.97h1.878zM2.6 12.371V1.87h.969v10.502zm10.423.66h10.95v.918h-6.208v9.579h-4.742V13.03zM5.629 3.333v12.356H0v4.51h10.386V8h10.473l-.003-4.668z"]
    static let siliconFlow = ["M22.956 6.521H12.522c-.577 0-1.044.468-1.044 1.044v3.13c0 .577-.466 1.044-1.043 1.044H1.044c-.577 0-1.044.467-1.044 1.044v4.174C0 17.533.467 18 1.044 18h10.434c.577 0 1.044-.467 1.044-1.043v-3.13c0-.578.466-1.044 1.043-1.044h9.391c.577 0 1.044-.467 1.044-1.044V7.565c0-.576-.467-1.044-1.044-1.044"]
    static let miniMax = ["M11.43 3.92a.86.86 0 1 0-1.718 0v14.236a1.999 1.999 0 0 1-3.997 0V9.022a.86.86 0 1 0-1.718 0v3.87a1.999 1.999 0 0 1-3.997 0V11.49a.57.57 0 0 1 1.139 0v1.404a.86.86 0 0 0 1.719 0V9.022a1.999 1.999 0 0 1 3.997 0v9.134a.86.86 0 0 0 1.719 0V3.92a1.998 1.998 0 1 1 3.996 0v11.788a.57.57 0 1 1-1.139 0zm10.572 3.105a2 2 0 0 0-1.999 1.997v7.63a.86.86 0 0 1-1.718 0V3.923a1.999 1.999 0 0 0-3.997 0v16.16a.86.86 0 0 1-1.719 0V18.08a.57.57 0 1 0-1.138 0v2a1.998 1.998 0 0 0 3.996 0V3.92a.86.86 0 0 1 1.719 0v12.73a1.999 1.999 0 0 0 3.996 0V9.023a.86.86 0 1 1 1.72 0v6.686a.57.57 0 0 0 1.138 0V9.022a2 2 0 0 0-1.998-1.997"]
    static let baidu = ["M9.154 0C7.71 0 6.54 1.658 6.54 3.707c0 2.051 1.171 3.71 2.615 3.71 1.446 0 2.614-1.659 2.614-3.71C11.768 1.658 10.6 0 9.154 0zm7.025.594C14.86.58 13.347 2.589 13.2 3.927c-.187 1.745.25 3.487 2.179 3.735 1.933.25 3.175-1.806 3.422-3.364.252-1.555-.995-3.364-2.362-3.674a1.218 1.218 0 0 0-.261-.03zM3.582 5.535a2.811 2.811 0 0 0-.156.008c-2.118.19-2.428 3.24-2.428 3.24-.287 1.41.686 4.425 3.297 3.864 2.617-.561 2.262-3.68 2.183-4.362-.125-1.018-1.292-2.773-2.896-2.75zm16.534 1.753c-2.308 0-2.617 2.119-2.617 3.616 0 1.43.121 3.425 2.988 3.362 2.867-.063 2.553-3.238 2.553-3.988 0-.745-.62-2.99-2.924-2.99zm-8.264 2.478c-1.424.014-2.708.925-3.323 1.947-1.118 1.868-2.863 3.05-3.112 3.363-.25.309-3.61 2.116-2.864 5.42.746 3.301 3.365 3.237 3.365 3.237s1.93.19 4.171-.31c2.24-.495 4.17.123 4.17.123s5.233 1.748 6.665-1.616c1.43-3.364-.808-5.109-.808-5.109s-2.99-2.306-4.736-4.798c-1.072-1.665-2.348-2.268-3.528-2.257zm-2.234 3.84l1.542.024v8.197H7.758c-1.47-.291-2.055-1.292-2.13-1.462-.072-.173-.488-.976-.268-2.343.635-2.049 2.447-2.196 2.447-2.196h1.81zm3.964 2.39v3.881c.096.413.612.488.612.488h1.614v-4.343h1.689v5.782h-3.915c-1.517-.39-1.59-1.465-1.59-1.465v-4.317zm-5.458 1.147c-.66.197-.978.708-1.05.928-.076.22-.247.78-.1 1.269.294 1.095 1.248 1.144 1.248 1.144h1.37v-3.34z"]

    public static func paths(for provider: ProviderType) -> [String] {
        switch provider {
        case .openAI: return openAI
        case .claudeCode: return anthropic
        case .gemini: return gemini
        case .deepseek: return deepSeek
        case .volcengine: return volcengine
        case .kimi: return kimi
        case .openRouter: return openRouter
        case .glm: return glm
        case .aliyunBailian: return aliyunCloud
        }
    }

    /// 自定义提供商按名称关键词匹配官方 Logo(大小写不敏感,用户改过名也能命中)。
    /// 返回 nil 表示无匹配,调用方回退到通用图标/首字母。
    public static func presetLogo(forName name: String) -> (paths: [String], color: Color)? {
        let lower = name.lowercased()
        func hit(_ keys: [String]) -> Bool { keys.contains { lower.contains($0) } }
        if hit(["mimo", "xiaomi", "小米"]) { return (xiaomi, Color(red: 1.0, green: 0.412, blue: 0.0)) }
        if hit(["hunyuan", "tencent", "混元", "腾讯"]) { return (tencentQQ, Color(red: 0.0, green: 0.322, blue: 0.851)) }
        if hit(["stepfun", "阶跃"]) { return (stepFun, Color(red: 0.0, green: 0.353, blue: 1.0)) }
        if hit(["siliconflow", "硅基"]) { return (siliconFlow, Color(red: 0.431, green: 0.161, blue: 0.965)) }
        if hit(["minimax", "名之梦"]) { return (miniMax, Color(red: 0.906, green: 0.208, blue: 0.384)) }
        if hit(["qianfan", "baidu", "千帆", "百度", "文心"]) { return (baidu, Color(red: 0.161, green: 0.196, blue: 0.882)) }
        return nil
    }
}

// MARK: - SVG path 解析

/// 把 SVG path data(`d` 属性)解析为 `Path`。
/// 支持 M/L/H/V/C/S/Q/T/A/Z 全部绝对/相对命令;弧线按 SVG 规范端点参数化
/// 转圆心参数化,再按 ≤90° 分段近似为三阶贝塞尔。仅供内置 Logo 静态路径使用。
public enum SVGPathParser {
    public static func parse(_ data: String) -> Path {
        let scanner = Scanner(data)
        return scanner.run()
    }

    private final class Scanner {
        let chars: [Character]
        var pos = 0

        init(_ s: String) { chars = Array(s) }

        // MARK: 词法

        private func skipSeparators() {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "," || chars[pos] == "\n" || chars[pos] == "\r" || chars[pos] == "\t" {
                pos += 1
            }
        }

        private func peekChar() -> Character? { pos < chars.count ? chars[pos] : nil }

        /// 读一个数字;SVG 允许省略分隔符(如 `1.5.5` = 1.5 与 .5,`1-2` = 1 与 -2)。
        private func readNumber() -> CGFloat? {
            skipSeparators()
            var text = ""
            if let c = peekChar(), c == "-" || c == "+" { text.append(c); pos += 1 }
            var seenDot = false
            while let c = peekChar() {
                if c.isNumber { text.append(c); pos += 1 }
                else if c == "." && !seenDot { seenDot = true; text.append(c); pos += 1 }
                else { break }
            }
            // 指数(e.g. 1e-3)
            if let c = peekChar(), c == "e" || c == "E" {
                var exp = "e"
                pos += 1
                if let s = peekChar(), s == "-" || s == "+" { exp.append(s); pos += 1 }
                if let d = peekChar(), d.isNumber {
                    while let d2 = peekChar(), d2.isNumber { exp.append(d2); pos += 1 }
                    text += exp
                } else {
                    pos -= exp.count - 1 // 不是合法指数,回退
                }
            }
            guard !text.isEmpty, let value = Double(text) else { return nil }
            return CGFloat(value)
        }

        /// 弧线命令的单字符 flag(0/1),可能与后续数字粘连(如 `011.5`)。
        private func readFlag() -> Int? {
            skipSeparators()
            guard let c = peekChar() else { return nil }
            if c == "0" { pos += 1; return 0 }
            if c == "1" { pos += 1; return 1 }
            return nil
        }

        // MARK: 状态

        var path = Path()
        var cx: CGFloat = 0, cy: CGFloat = 0      // 当前点
        var sx: CGFloat = 0, sy: CGFloat = 0      // 子路径起点
        var cubicCtrl: CGPoint? = nil             // 上一段 C/S 的第二控制点(S 反射用)
        var quadCtrl: CGPoint? = nil              // 上一段 Q/T 的控制点(T 反射用)

        func move(_ x: CGFloat, _ y: CGFloat) {
            path.move(to: CGPoint(x: x, y: y))
            cx = x; cy = y; sx = x; sy = y
            cubicCtrl = nil; quadCtrl = nil
        }
        func line(_ x: CGFloat, _ y: CGFloat) {
            path.addLine(to: CGPoint(x: x, y: y))
            cx = x; cy = y; cubicCtrl = nil; quadCtrl = nil
        }
        func curve(_ x: CGFloat, _ y: CGFloat, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat) {
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            cx = x; cy = y; cubicCtrl = CGPoint(x: c2x, y: c2y); quadCtrl = nil
        }
        func quad(_ x: CGFloat, _ y: CGFloat, _ qx: CGFloat, _ qy: CGFloat) {
            path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: qx, y: qy))
            cx = x; cy = y; quadCtrl = CGPoint(x: qx, y: qy); cubicCtrl = nil
        }
        func close() {
            path.addLine(to: CGPoint(x: sx, y: sy))
            cx = sx; cy = sy; cubicCtrl = nil; quadCtrl = nil
        }

        // MARK: 弧线:端点参数化 → 圆心参数化 → 分段三阶贝塞尔

        func arc(rx: CGFloat, ry: CGFloat, rotation: CGFloat, largeArc: Bool, sweep: Bool, x: CGFloat, y: CGFloat) {
            guard rx > 0, ry > 0, !(x == cx && y == cy) else { line(x, y); return }
            let phi = rotation * .pi / 180
            let cosP = cos(phi), sinP = sin(phi)
            let dx = (cx - x) / 2, dy = (cy - y) / 2
            let x1 = cosP * dx + sinP * dy
            let y1 = -sinP * dx + cosP * dy
            var rx = abs(rx), ry = abs(ry)
            let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
            if lambda > 1 {
                let s = sqrt(lambda)
                rx *= s; ry *= s
            }
            let sign: CGFloat = (largeArc == sweep) ? -1 : 1
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coef = sign * sqrt(max(0, den == 0 ? 0 : num / den))
            let cx1 = coef * (rx * y1 / ry)
            let cy1 = -coef * (ry * x1 / rx)
            let center = CGPoint(
                x: cosP * cx1 - sinP * cy1 + (cx + x) / 2,
                y: sinP * cx1 + cosP * cy1 + (cy + y) / 2
            )
            func theta(_ ux: CGFloat, _ uy: CGFloat) -> CGFloat {
                atan2(uy, ux)
            }
            let t1 = theta((x1 - cx1) / rx, (y1 - cy1) / ry)
            var dt = theta((-x1 - cx1) / rx, (-y1 - cy1) / ry) - t1
            if !sweep && dt > 0 { dt -= 2 * .pi }
            if sweep && dt < 0 { dt += 2 * .pi }
            // 分段(每段 ≤90°),kappa = 4/3·tan(δ/4)
            let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
            let delta = dt / CGFloat(segments)
            let k: CGFloat = 4.0 / 3.0 * tan(delta / 4)
            func pointAt(_ t: CGFloat) -> (p: CGPoint, tan: CGPoint) {
                let ex = rx * cos(t), ey = ry * sin(t)
                let p = CGPoint(x: center.x + cosP * ex - sinP * ey, y: center.y + sinP * ex + cosP * ey)
                let tx = -rx * sin(t), ty = ry * cos(t)
                return (p, CGPoint(x: cosP * tx - sinP * ty, y: sinP * tx + cosP * ty))
            }
            var t = t1
            for _ in 0..<segments {
                let a = pointAt(t), b = pointAt(t + delta)
                path.addCurve(
                    to: b.p,
                    control1: CGPoint(x: a.p.x + k * a.tan.x, y: a.p.y + k * a.tan.y),
                    control2: CGPoint(x: b.p.x - k * b.tan.x, y: b.p.y - k * b.tan.y)
                )
                t += delta
            }
            cx = x; cy = y; cubicCtrl = nil; quadCtrl = nil
        }

        // MARK: 语法

        static let argCounts: [Character: Int] = [
            "M": 2, "L": 2, "T": 2, "H": 1, "V": 1,
            "C": 6, "S": 4, "Q": 4, "A": 7, "Z": 0,
        ]

        func run() -> Path {
            var command: Character = " "
            while true {
                skipSeparators()
                guard pos < chars.count else { break }
                let c = chars[pos]
                if c.isLetter {
                    command = c
                    pos += 1
                    if command == "Z" || command == "z" {
                        close()
                        command = " " // Z 不重复
                        continue
                    }
                }
                guard Scanner.argCounts[Character(command.uppercased())] != nil else { break }
                let relative = command.isLowercase
                switch command.uppercased() {
                case "M":
                    guard let x = readNumber(), let y = readNumber() else { return path }
                    let px = relative ? cx + x : x, py = relative ? cy + y : y
                    move(px, py)
                    command = relative ? "l" : "L" // M 后续隐式为 L/l
                case "L":
                    guard let x = readNumber(), let y = readNumber() else { return path }
                    line(relative ? cx + x : x, relative ? cy + y : y)
                case "H":
                    guard let x = readNumber() else { return path }
                    line(relative ? cx + x : x, cy)
                case "V":
                    guard let y = readNumber() else { return path }
                    line(cx, relative ? cy + y : y)
                case "C":
                    guard let a = readNumber(), let b = readNumber(), let c1 = readNumber(), let c2 = readNumber(), let d = readNumber(), let e = readNumber() else { return path }
                    let (x, y, c1x, c1y, c2x, c2y) = relative
                        ? (cx + a, cy + b, cx + c1, cy + c2, cx + d, cy + e)
                        : (a, b, c1, c2, d, e)
                    curve(x, y, c1x, c1y, c2x, c2y)
                case "S":
                    guard let a = readNumber(), let b = readNumber(), let c1 = readNumber(), let c2 = readNumber() else { return path }
                    let (x, y, c2x, c2y) = relative ? (cx + a, cy + b, cx + c1, cy + c2) : (a, b, c1, c2)
                    let c1p = cubicCtrl ?? CGPoint(x: cx, y: cy)
                    let c1x = 2 * cx - c1p.x, c1y = 2 * cy - c1p.y
                    curve(x, y, c1x, c1y, c2x, c2y)
                case "Q":
                    guard let a = readNumber(), let b = readNumber(), let c1 = readNumber(), let c2 = readNumber() else { return path }
                    let (x, y, qx, qy) = relative ? (cx + a, cy + b, cx + c1, cy + c2) : (a, b, c1, c2)
                    quad(x, y, qx, qy)
                case "T":
                    guard let x = readNumber(), let y = readNumber() else { return path }
                    let q = quadCtrl ?? CGPoint(x: cx, y: cy)
                    let qx = 2 * cx - q.x, qy = 2 * cy - q.y
                    let px = relative ? cx + x : x, py = relative ? cy + y : y
                    quad(px, py, qx, qy)
                case "A":
                    guard let rx = readNumber(), let ry = readNumber(), let rot = readNumber(),
                          let la = readFlag(), let sw = readFlag(),
                          let x = readNumber(), let y = readNumber() else { return path }
                    arc(rx: rx, ry: ry, rotation: rot, largeArc: la == 1, sweep: sw == 1,
                        x: relative ? cx + x : x, y: relative ? cy + y : y)
                default:
                    return path
                }
            }
            return path
        }
    }
}

// MARK: - 视图

/// 单条或多条 path data 渲染为 24×24 viewBox 内的形状,随 rect 等比缩放。
struct SVGPathShape: Shape {
    let data: [String]

    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for d in data { combined.addPath(SVGPathParser.parse(d)) }
        let scale = min(rect.width, rect.height) / 24
        guard scale > 0 else { return combined }
        return combined.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// 厂商 Logo 视图:单色 glyph(主题色填充),徽章底色/圆角由调用方修饰(与原 SF Symbol 徽章一致)。
public struct ProviderLogoView: View {
    let provider: ProviderType
    var size: CGFloat

    public init(provider: ProviderType, size: CGFloat = 14) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        SVGPathShape(data: ProviderLogo.paths(for: provider))
            .fill(provider.themeColor)
            .frame(width: size, height: size)
    }
}

// MARK: - 原生菜单图标(NSImage)

extension ProviderLogo {
    private static var menuIconCache: [SettingsTab: NSImage] = [:]

    /// 设置页下拉菜单用的小尺寸 Logo 图像。macOS 原生菜单项只支持 SF Symbol 或
    /// NSMenuItem.image(SwiftUI 自定义视图不渲染),因此离屏渲染成位图后经
    /// NSPopUpButton 塞入;非厂商 Tab(自定义/显示顺序/通用)回退 SF Symbol。
    public static func menuImage(for tab: SettingsTab) -> NSImage {
        if let cached = menuIconCache[tab] { return cached }

        let provider: ProviderType?
        switch tab {
        case .openAI: provider = .openAI
        case .anthropic: provider = .claudeCode
        case .gemini: provider = .gemini
        case .deepseek: provider = .deepseek
        case .volcengine: provider = .volcengine
        case .kimi: provider = .kimi
        case .openRouter: provider = .openRouter
        case .glm: provider = .glm
        case .aliyun: provider = .aliyunBailian
        default: provider = nil
        }

        let image: NSImage
        if let provider {
            image = renderedImage(paths: paths(for: provider), color: NSColor(provider.themeColor))
        } else if let symbol = NSImage(systemSymbolName: tab.icon, accessibilityDescription: nil) {
            image = symbol
        } else {
            image = NSImage()
        }
        menuIconCache[tab] = image
        return image
    }

    /// 把 Logo 路径渲染为 16pt 画布、内容约 14pt 的位图(@2x),供菜单项使用。
    private static func renderedImage(paths: [String], color: NSColor, canvas: CGFloat = 16, glyph: CGFloat = 14) -> NSImage {
        let pixels = Int(canvas) * 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return NSImage(size: NSSize(width: canvas, height: canvas)) }
        rep.size = NSSize(width: canvas, height: canvas)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let context = NSGraphicsContext.current?.cgContext {
            var combined = Path()
            for d in paths { combined.addPath(SVGPathParser.parse(d)) }
            context.saveGState()
            // SVG 的 y 轴向下,位图坐标 y 向上:先翻转再按 glyph/24 缩放并居中
            let scale = glyph / 24
            context.translateBy(x: (canvas - glyph) / 2, y: canvas - (canvas - glyph) / 2)
            context.scaleBy(x: scale, y: -scale)
            context.addPath(combined.cgPath)
            context.setFillColor(color.usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        NSGraphicsContext.current = nil
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.addRepresentation(rep)
        return image
    }
}
