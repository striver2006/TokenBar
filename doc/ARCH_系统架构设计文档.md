# TokenBar 系统架构设计文档 (ARCH)

> **项目名称**：TokenBar  
> **副标题**：模型额度监控 / Model Quota Monitor  
> **设计原则**：原生轻量、本地私密、分层解耦、双端适配。

---

## 1. 总体架构与代码目录组织

TokenBar 采用跨平台双原生实现策略。针对 macOS 与 Windows 系统的状态栏/托盘事件循环与界面渲染特性的差异，项目在仓库顶层将实现完全解耦为 `mac/` 与 `windows/` 独立工程。

```mermaid
graph TD
    subgraph RepoRoot["TokenBar 仓库根目录"]
        Doc["doc/ (设计与使用文档)"]
        MacDir["mac/ (macOS 原生客户端)"]
        WinDir["windows/ (Windows 原生客户端)"]
    end

    subgraph MacArchitecture["macOS (Swift 5.9+ / SwiftUI / AppKit)"]
        M_Tray["NSStatusItem & HoverTrackingView"]
        M_Pop["NSPopover (SwiftUI Host)"]
        M_Mgr["RefreshManager (@ObservableObject)"]
        M_I18n["LocalizationManager (Thread-Safe i18n)"]
        M_Services["Service 模块 (OpenAI/Claude/Gemini/Bailian/etc.)"]
        M_Store["本地存储 (UserDefaults / Keychain)"]
    end

    subgraph WinArchitecture["Windows (.NET 8 / C# / WPF)"]
        W_Tray["NotifyIcon (任务栏托盘)"]
        W_Pop["PopoverWindow (WPF 悬浮卡片)"]
        W_Mgr["RefreshManager (后台定时调度器)"]
        W_I18n["LocalizationManager (中英文动态派发)"]
        W_Services["HttpClient 服务层"]
        W_Store["本地配置 (AppData/TokenBar/settings.json)"]
    end

    MacDir --> M_Tray
    M_Tray --> M_Pop
    M_Pop --> M_Mgr
    M_Mgr --> M_I18n
    M_Mgr --> M_Services
    M_Services --> M_Store

    WinDir --> W_Tray
    W_Tray --> W_Pop
    W_Pop --> W_Mgr
    W_Mgr --> W_I18n
    W_Mgr --> W_Services
    W_Services --> W_Store
```

---

## 2. macOS 原生端架构实现 (`mac/`)

macOS 客户端采用纯 Swift 打造，支持 macOS 13 (Ventura) 及以上系统，无需引入任何臃肿的三方框架。

### 2.1 表现层 (Presentation Layer)
- **`MenuBarController`**：
  - 维护系统状态栏 `NSStatusItem`，用直接挂在按钮上的 `NSTrackingArea` 监听鼠标悬浮与移出事件
    （不往 `NSStatusBarButton` 里插子视图：macOS 26 的状态项由系统进程托管布局，少插一层就少一个变量；
    追踪区的 owner 是控制器本身，回调必须写成 `@objc(mouseEntered:)` —— Swift 自动合成的名字是
    `mouseEnteredWith:`，和 AppKit 实际发送的 selector 对不上会静默收不到悬停事件）。
  - 支持“鼠标悬停快速展开”与“点击固定（Pin）”双重交互模型。悬停 0.15s 展开、移出 0.35s 关闭
    （`hoverOpenDelay` / `hoverCloseDelay`），定时器注册到 `.common` mode。`NSTrackingArea` 只覆盖
    状态栏按钮，鼠标「图标 → 浮窗 → 桌面」后不会再收到 exited，因此 `handleMouseMoved` 在鼠标既不在
    图标也不在浮窗内时必须重新安排关闭；`popoverDidClose` 是状态复位的唯一出口（`.transient`
    点击外部关闭也走它）。承载 `handleMouseMoved` 的本地 `mouseMoved` 监听器只在「悬停展开、
    未 pin」期间按需安装，pin 或关闭即卸载——常驻安装时每个鼠标事件都要分配一个 Task 才能早退，
    被唤醒的长跑弹窗会持续白白消耗 CPU。
  - 设置窗口的 `NSHostingView` 复用不重建；切 tab 与重新读钥匙串通过 `SettingsWindowRequest`
    通知视图（`.task(id: openCount)`），用户未保存的输入不会因为再次打开而丢失。
  - 绑定 `NSPopover`，将其根视图托管至 SwiftUI `TokenSummaryPopoverView`。
  - 订阅 `RefreshManager.objectWillChange`，按用户配置把某个厂商的剩余额度 / 余额渲染到 `NSStatusItem` 标题（文案由纯函数 `MenuBarStatus` 计算，便于单测）。
  - **状态项健康自愈**（macOS 26 起状态项托管在系统进程 ControlCenter，实测会出现"对象活着、内容完好，但控制中心不为它渲染"
    的故障态，用户看到的就是"图标不见了"）。**真正的根因不在应用代码**：ControlCenter 按 bundle id 查 LaunchServices，
    只要有一条路径已不存在的陈旧注册记录（换过构建输出目录、反复挂载 DMG 测安装包都会留下），就把该 bundle id 的状态项
    `Moving host to blocked list` 并隐藏；黑名单不落盘、重启 ControlCenter 也不清，只有 `lsregister -u` 注销死记录后
    下一次注册才恢复（2026-09-14 用探针 .app 逐变量排除后实测确认）。所以自愈动作里**清理 LS 死记录排在重建状态项之前**：
    `purgeStaleLaunchServicesRecords` 在后台线程解析 `lsregister -dump`（全量输出，本机 28MB / 3 秒）找出本 bundle id
    下路径已不存在的记录，逐条注销，完成后回主线程再重建；启动时先清一次、每次重建前再清一次。
    注销机制是受控实验（2026-09-14）实测出来的：`lsregister -u` **只认路径上真实存在的 bundle**，
    路径已删除时直接失败（-10814）；`-gc` 与「同 bundle id 在别处重新注册」都挤不掉死记录。
    所以对每条死记录：先试 `-u`（路径复活过的快路径），失败则**原位重建一个最小 stub .app
    （`stubInfoPlist`，CFBundleIdentifier 与死记录一致）→ `-u` → 删掉 stub 并按 rmdir 语义
    回收新建的空目录**；`/Volumes/...` 等不可写路径上的死记录自动注销会失败，打 error 日志
    留给人工处理（重新挂载对应卷）。
    不能用 `NSWorkspace.urlsForApplications(withBundleIdentifier:)`——它会把不存在的路径过滤掉，永远找不到死记录。
    dump 带 15s 看门狗（这条在重建路径上被同步等待，挂死会永久卡住 `isRebuilding`）；**"没查成"与"查了、没有"
    严格分开**——工具起不来、被看门狗杀掉或退出码非 0 时打 error 级"dump 执行失败，跳过核对"，
    绝不把失败伪装成"无死记录"的假阴性。构建侧配套：`build_app.sh` 删除旧产物前先 `lsregister -u`，
    另提供 `--clean` 一并注销并删除 `build/` 与 `build/dist/` 两个输出路径——清理构建目录必须走它，
    直接 `rm` 又会制造新的死记录。
    2026-09-14 下午真机复测补充：**LS 清干净后 block 未必解除**。LS 里 com.tokenbar.mac 只剩
    /Applications 一条干净注册、死记录为零时，ControlCenter 仍在新会话里对该 bundle id 的状态项
    即时 `Moving host to blocked list`——换用该 bundle id 的最小探针 .app（无 autosaveName、ad-hoc
    签名、/tmp 路径）同样 20ms 内被拉黑，而全新 bundle id 的同款探针正常上屏；重启 ControlCenter、
    `tccutil reset`、`-f` 重注册、注销再注册均无效，且 ControlCenter 的全部落盘状态
    （defaults / ByHost displayablemenuextras / Application Support / Group Containers）里查无该
    bundle id 的痕迹。结论：**拉黑是按 bundle id 的粘性会话态**（疑似活在对 CC 重启免疫的
    WindowServer/会话层），LS 死记录只是初始触发器之一。应用内 LS 清理仍是必要卫生（防再次触发），
    镜像健康信号也如实探测到了 block；但对已存在的拉黑，LS 侧动作已无力解除。2026-09-14 13:42
    整机重启实测：**重启也无效**——开机自启的首个 host 在 13:46 创建 20ms 后复现拉黑，此后全天
    各 PID 均秒拒；「拉黑随会话清除」假设不成立（要么跨重启持久，要么重启后又被即刻再触发）。
    另注意到无关应用 `io.vpsquota.VPSTrafficQuota`、`com.unidrop.client` 同期也被 blocked，
    「按 bundle id 精确命中」有待重审。解除手段目前只剩全库重建 `lsregister -kill -seed -r`
    这类重手段（未验证）。
    - 判定：纯函数 `StatusItemHealth.evaluate` 吃一份 `Snapshot`（`isVisible` / `button.window` 几何 / `windowNumber` /
      控制中心是否为它渲染了镜像 / 能否在 `CGWindowList` 按窗口号查到 / 各屏几何），输出 `healthy` / `userHidden` /
      `detached(Reason)` / `indeterminate`。**最可靠的信号是控制中心镜像**：每个真正显示出来的状态项在 layer-25 层都有一个
      onscreen 的控制中心窗口，与应用自己那个离屏的状态项窗口同 x 同宽；被 block 的状态项没有这条镜像，而它的 frame
      可能仍停在正常位置，所以几何判定只是辅助。
      `isVisible` 判定排在所有几何判定之前——用户 Cmd 拖走图标不是故障，重建会覆盖用户意图。
      几何判定排在窗口服务器信号之前：几何只依赖 AppKit 自己的数字，更可靠。窗口服务器那条信号在 macOS 26 上
      基本恒为"不可用"——托管状态项的 `windowNumber` 是超出 `CGWindowID`(UInt32) 范围的占位值（实测 2^32），
      按号查不到窗口，此时必须返回 nil 让信号被忽略；当成"没注册"会把健康的状态项判成掉线、反复重建。
      判定"在不在菜单栏带内"复用 `MenuBarAnchor.isInMenuBarBand`，对屏幕顶边与左右边界是严格的（故障态正是各越界 1pt），
      只有带下边界留松弛量（健康状态项 `maxY = screen.maxY − 3…−4`，并不贴齐屏幕顶边）。
    - 自愈：`setup()` 拆成"一次性的订阅/监听"与"可重入的 `installStatusItem`"两半，判定掉线时
      `NSStatusBar.removeStatusItem` + 重新安装。轻推 `NSStatusItem.length` 保留下来，但只治
      "位置还在、图标不画了"那种托管渲染丢失，对没拿到槽位的故障态无效（实测心跳推多次都救不回来）。
      重建受 `StatusItemHealth.RebuildPolicy` 约束：连续 2 次确认 + 指数退避（30/60/120…封顶 900s）+ 单次运行最多 5 次，
      最后一次会先清掉 `NSStatusItem Preferred Position/Visible` 两个持久化键再重建，防止坏状态被 `autosaveName` 还原回来；
      连续健康 10 分钟后预算清零。弹窗/右键菜单开着、鼠标按下、无屏幕、显示器重配置后 3s 内一律跳过判定。
    - 触发时机：启动后 2/5/15/60s 四级校验梯（治登录自启时菜单栏服务未就绪的竞态）、屏幕参数变化、唤醒、
      `didBecomeActive`、300s 保底心跳、弹窗关闭、锚点走了兜底。掉线期间快探测间隔 15s。
  - 弹窗定位两层防护（缓存的状态栏窗口坐标在显示器熄屏/唤醒后可能过期，会把 `NSPopover` 定位到屏幕中央或夹到屏幕边缘）：
    - 有鼠标（悬停/点击）：纯函数 `MenuBarAnchor.resolve` 用"触发时鼠标一定在图标上"校验缓存矩形，过期则按鼠标位置推导；
      校验通过的结果还会再过一遍几何校验，因为 `resolve` 在"鼠标不在菜单栏带内"时会把坏缓存原样放行。
    - 无鼠标（`tb` / Dock reopen / 第二实例唤醒）：`MenuBarAnchor.resolveWithoutPointer` 只认几何——缓存矩形不在菜单栏带内就兜底，
      兜底锚点贴到系统项簇（控制中心）左侧、或距屏幕右缘留够弹窗半宽，**不能贴右边缘**，否则 `NSPopover` 会被 AppKit 夹回去、
      看起来仍是错位。这条路径此前完全跳过校验，是"`tb` 弹窗贴死在屏幕右缘"的直接原因。
    - 兜底时把 `NSPopover` 挂到一个透明、穿透点击的辅助 `NSPanel` 上；弹窗关闭后回收面板并复查一次状态项健康。
    - 调试开关：`TokenBarForceAnchorFallback` 强制走锚点兜底、`TokenBarForceStatusItemUnhealthy` 强制判掉线以验证重建链路、
      `TokenBarDisableHoverTracker` 摘掉悬停跟踪视图做 A/B。
- **SwiftUI 视图组件**：
  - `TokenSummaryPopoverView`：主看板，包含标题区（TokenBar 及中英文副标题）、即时刷新动画按钮、滚动卡片列表以及状态栏。
  - `ProviderCardView` & `CustomProviderCardView`：展示各模型厂商卡片，双窗口（5 小时与每周）进度条及重置时间。
  - `SettingsView`：包含 12 个配置选项卡（OpenAI、Anthropic、Gemini、DeepSeek、火山方舟、KIMI、OpenRouter、GLM、阿里云百炼、国内厂商/自定义、显示顺序、通用设置）。

### 2.2 状态与并发管理 (State & Concurrency Layer)
- **`RefreshManager`**：
  - 单例对象，遵循 `ObservableObject` 协议，向所有视图广播额度变更。
  - 采用 Swift 结构化并发 `withTaskGroup`，当触发全量刷新时，各开启的厂商并行拉取。
  - 定时调度器：使用 `Timer` 按照用户设定周期（1~60 分钟）静默触发，注册到 `.common`
    runloop mode，避免右键菜单/拖拽这类 `.eventTracking` 交互期间被暂停。
  - **定时器在 `init()` 中同步创建，先于首刷**。曾经是"首刷完成后才建定时器"，首刷一旦
    挂起就永远不会有自动刷新。
  - **刷新闸门带看门狗**：`isRefreshing` 配 `refreshStartedAt` + `refreshGeneration`，
    上一轮超过 90 秒未结束时新一轮强制抢占。以前只是 `guard !isRefreshing else { return }`，
    一轮卡死就会让之后每一次 tick 和手动刷新都被静默丢弃。
  - **单厂商超时隔离**：每个 provider 经 `withTimeout`（`TaskTimeout.swift`）套独立预算
    （百炼 35s / Gemini 30s / 其余 25s），单个厂商挂起不拖垮整轮。超时哨兵在操作按时完成时
    会被取消，不会每轮每厂商留下一个睡满预算的悬挂 Task。
  - **设置项的保存必须发生在写入的那一刻**，不能挂在 SwiftUI 的 `.onChange` 副作用里。通用设置
    里的 Picker / Toggle 一律走 `SettingsView.savingBinding(_:)`：setter 内写值并立即 `saveSettings()`。
    曾经是「绑定 settings + 紧随其后的 `.onChange` 调 saveSettings」，而这些控件上还叠了
    `.id(i18n.currentLanguage)`，视图标识重建会把 `onChange` 的基线重置成新值、通知被吞掉 ——
    真实故障是刷新间隔改成 1 分钟后仍按 5 分钟跑了近 3 小时，日志里那段时间完全没有「定时器已创建」。
  - **定时器自愈要比对间隔**：每轮结束走 `RefreshTimerHealth.needsRebuild`（Windows 端为同语义的内联判断），
    除「定时器是否失效」外还比对生效中的间隔与设置值。这是「设置改了却没生效」的最后一道防线，
    最迟一个旧周期自愈。间隔一致时**不得**重建 —— 每次重建都会把计时相位打回零。
  - **轮次门控写回**：各 `refreshXxx` 在入口捕获 `refreshGeneration`，结果经 `commit(_:for:gen:)`
    写回；被闸门抢占的旧轮次跑完后其结果直接丢弃，不会用失败态覆盖新轮次刚写入的数据。
  - **状态型窗口**：`TokenWindowKind.status` 表示「只探测到连通性、拿不到真实额度」，卡片只画
    标题与状态点。各厂商 Service **不得**在拿不到数据时伪造进度条（GLM 曾用 `usedPct * 0.6`
    编造每周额度、Gemini API Key 模式曾用「当前小时 / 5」拼 5 小时窗口，均已删除）；
    `x-ratelimit-reset-*` 统一走 `RateLimitReset.parse`（Go duration / 秒 / unix 秒·毫秒时间戳）。

#### 2.2.1 刷新链路的三条硬约束

这三条都来自真实故障（自动刷新连续 4 小时停摆），改动时不要回退：

1. **所有网络请求走 `HTTPClient`，不用 `URLSession.shared`**。shared 的
   `timeoutIntervalForResource` 默认 **7 天**，而 `URLRequest.timeoutInterval` 只是
   "不活动超时"——代理环境下 TCP 停在 ESTABLISHED、响应慢速滴流时它可能永不触发。
   `HTTPClient` 统一 12s 请求 / 30s 端到端上限，并禁用 URLCache（靠响应头取额度的厂商
   命中缓存会连响应头一起回放旧值）。
2. **钥匙串访问必须在后台线程，且读取结果必须三态**。
   `SecItemCopyMatching` 是同步阻塞调用，经 mach IPC 等 securityd；签名变化触发的授权框、
   钥匙串锁定、securityd 繁忙都会让它久等。一旦发生在 MainActor 上，主线程冻结会让**所有**
   provider 的刷新任务一起停摆（它们全都跑在 MainActor 上），连超时哨兵恢复执行都排不上队。
   同步的 `set` / `delete` / `lookup` 带 `assertOffMain` 断言，DEBUG 下会把误用直接炸出来；
   异步入口是 `lookupAsync` / `setAsync` / `deleteAsync` / `prefetch`（Windows 端对应
   `LookupAsync` / `SetAsync` / `DeleteAsync` / `PrefetchAsync`）。

   **三态（`SecretLookup`: `found` / `absent` / `unavailable`）不是洁癖，是防数据丢失。**
   `String?` 表达不了「确定没有」和「读不到」的差别，而**有写权限的调用方**把两者混为一谈
   就是删掉用户凭证：读取失败 → 输入框留空 → 用户点保存 → 走 delete 分支 → 钥匙串里真实
   存在的账号级长期凭证被抹掉。刷新链路可以容忍「读不到」（降级成未授权，下一轮自愈），
   所以它用 `prefetch`；设置页不行，它必须用 `lookupAsync` 并在 `.unavailable` 下
   **跳过删除**。这条判断抽在 `SecretSaveAction.resolve(input:storeReadable:)` 里，
   有专门的单测守着。

   同理，`resolveCredentials` / `ResolveCredentials` 的 `secretStore` 参数**没有默认值也
   不回退**，必须显式传入预取好的内存快照——默认值会把最危险的选项做成打字最少的选项。

   **读别人的钥匙串条目：刷新链路关交互，授权只在设置页做一次。** Antigravity 用 go-keyring
   在 login.keychain 里存了一份 Google 凭证（service `gemini` / account `antigravity`），这是
   **唯一持续更新**的数据源（`cdat` 不变、`mdat` 每小时变，说明是原地更新，ACL 不会被冲掉）；
   `~/.gemini/jetski-standalone-oauth-token` 实测会停在几天前的旧 token 上，只能当回退。
   条目的 ACL 归 Antigravity，TokenBar 首次读取需要用户在系统授权框里点「始终允许」——
   构建已固定开发者证书签名（`Scripts/build_app.sh`），ACL 按 designated requirement 匹配，
   重新编译不会失配。
   曾经的做法是 `/usr/bin/security` 子进程 + 3 秒看门狗 + 缓存/冷却限流，结果是一个死循环：
   3 秒内人来不及点授权框，子进程被 SIGTERM 记为失败，失败冷却（30s）又远短于刷新间隔
   （最小 60s），于是每轮刷新都再弹一次，用户永远点不到「始终允许」，白名单永远建不起来。
   现在的规则是 `KeychainSecretStore.readForeign(allowInteraction:)`：
   - 刷新链路 `allowInteraction: false` —— 查询带 `kSecUseAuthenticationUIFail`，并在钥匙串
     串行队列上成对切换 `SecKeychainSetUserInteractionAllowed`。未授权时 securityd 在 1ms 内
     返回 `errSecAuthFailed`（实测 -25293，不是 -25308），归 `.unavailable`，降级到文件；
     **绝不弹框**是机制保证，不靠限流。
   - 设置页「读取本地 Gemini 配置」按钮 `allowInteraction: true` —— 全 App 唯一允许弹框的入口，
     超时 120s 让用户慢慢点。
   三层来源合并在 `GeminiService.mergeCredentials`（纯函数，有单测）：钥匙串 > 文件 >
   TokenBar 自有条目里的 `geminiRefreshToken` 快照（额度拉取成功后写入，Antigravity 卸载后
   仍能续期）。

   **自有 Google 登录（2026-09 起的推荐主通道）：** 上述本地链路有两个绕不开的脆弱点——
   外来条目 ACL 会被 Antigravity 重登重置、文件里的 refresh_token 会被 Antigravity 的后续
   刷新轮换掉（2026-09-13 实测：`invalid_grant`）。`GeminiService` 因此增加了自己的 loopback
   OAuth 登录：`prepareGoogleLogin()` 用扫描出的 client 构造授权 URL（redirect_uri 为随机端口
   的 `http://localhost:<port>`，scope 与 Antigravity 凭证实测一致），`WebLoginWindowController`
   在 `decidePolicyFor` 里**拦截**（而非真的监听）该重定向取 code，`exchangeGoogleLoginCode`
   换出 refresh_token 存进自有条目 `geminiOwnRefreshToken`。`fetchQuota` 的凭证优先级变为
   **自有登录 > 外来钥匙串 > 文件 > 快照**：自有凭证存在时完全不碰外来条目（日志里也不再
   出现 -25293 噪音）；自有凭证被判 `invalid_grant` 时自动清除并当场落到本地链路。刷成功的
   client 配对持久化在 `geminiAntigravityClient` 条目（`id|secret`），启动后不必重扫几百 MB
   的二进制。

   **错误归因按失败阶段分流（同批改造）：** 以前 `keychainDenied` 只是个选文案的布尔——钥匙串
   读不到时，refresh_token 被轮换、配额接口 401、刷新冷却中统统显示成「钥匙串授权被拒」，
   把用户反复引向无效的重新授权。现在 `KeychainSecretStore.readForeignWithStatus` 把原始
   OSStatus 带出来（只有 -25293/-25308 才算 ACL 拒，见 `ForeignLookup.isACLDenied`），
   `refreshGoogleAccessToken` 返回结构化的 `TokenRefreshOutcome`（invalidGrant / clientMismatch /
   unreachable / cooldown / noCandidates），`fetchQuota` 按 `CredentialStage` 抛
   `CredentialError`，每个阶段对应一条真正有效的恢复指引（有单测 `testGeminiFailureMessagePerStage`）。
3. **`Process` 子进程要先读 pipe 再 `waitUntilExit`**，并配超时 kill 与
   `standardInput = FileHandle.nullDevice`。反序会在输出超过 64KB pipe 缓冲区时形成
   父子互等死锁；`withTimeout` 救不了子进程（不响应 Task 取消），必须自己兜。

   第 2 条的精神同样适用于**文件 IO**：`~/.claude.json`（重度用户数 MB）、`~/.bailian/config.json`、
   余额历史 `balance_history.json` 都不得在 MainActor 上同步读写。对应入口是
   `ClaudeService.readLocalClaudeJson()`（async）、`BailianCLIConfig.loadFromDiskAsync()`、
   `BalanceHistoryStore`（actor，内存常驻一份，磁盘只在首次访问读一次）。

   **有可变缓存的 Service 必须是 actor**（`GeminiService`：token 缓存、client 候选、刷新失败冷却）。
   普通 class 的 nonisolated async 方法从 MainActor `await` 进去后并不在主线程执行，刷新链路与
   设置页「测试」按钮并发进入就是数据竞争。排查此类问题可临时开严格检查：
   `swift build -Xswiftc -strict-concurrency=complete`（目前约 100 条警告，多为 Foundation
   类型未标 Sendable 的噪音，故未固化进 Package.swift）。

#### 2.2.2 可观测性与排查

`Log.swift` 统一日志出口，subsystem `com.tokenbar.mac`，category 分
`timer` / `refresh` / `provider` / `net` / `lifecycle`。级别按落盘规则选：
`.notice` / `.error` 持久化（定时器 fire、轮次起止、厂商超时、闸门抢占），
`.info` / `.debug` 只驻内存（单厂商耗时、排队时间、超时哨兵触发时刻）。

```bash
# 实时观察定时器是否真的按周期 fire
log stream --predicate 'subsystem == "com.tokenbar.mac" AND category IN {"timer","refresh"}' --style compact

# 事后回溯（notice/error 已落盘）
log show --last 1h --predicate 'subsystem == "com.tokenbar.mac"' --info --style compact
```

排查"更新不及时"时，**先看 `timer fired，距上次 xxxs` 是否稳定在设定周期**，再看
`round end` 的耗时与 `provider=xxx TIMEOUT`。若某厂商耗时异常而主线程栈（`sample <pid>`）
显示空闲，怀疑 MainActor 上的同步阻塞（钥匙串、子进程）。

#### 2.2.3 签名与钥匙串 ACL

`Scripts/build_app.sh` 推荐用固定的 Apple Development 证书签名。**签名身份属于每台
机器的本地配置，不进仓库**，取值优先级为：

1. `CODESIGN_IDENTITY` 环境变量；
2. `mac/Scripts/signing.local.env`（已 gitignore，模板见同目录 `signing.local.env.example`）；
3. 都没有则退回 ad-hoc（脚本会打印如何配置的提示）。

首次 clone 后配置一次即可：

```bash
cd mac/Scripts
cp signing.local.env.example signing.local.env
security find-identity -v -p codesigning   # 取行首 40 位 SHA-1 填进去
```

用 SHA-1 哈希而非证书名指定：同名证书可能有多张（例如已吊销的旧证书，
按名字签会撞上它报 `CSSMERR_TP_CERT_REVOKED`）。

为什么不用 ad-hoc：ad-hoc 签名没有稳定的 designated requirement，钥匙串 ACL 只能按
cdhash 匹配，而 cdhash 每次重新编译都变——于是每次构建后首次读钥匙串都会弹授权框，
而这个框卡在主线程上就会冻结整个刷新流程。固定证书签名后 requirement 变成
`identifier "com.tokenbar.mac" and ... certificate leaf[subject.CN] = "..."`，
重新编译不再反复授权。切换签名身份后第一次启动仍会问一次，点「始终允许」即可。

**应用生命周期与单实例（`main.swift` / `AppDelegate`）**：`main` 入口在任何 UI 建立之前
经 `SingleInstanceGuard` 以 `flock` 文件锁（`~/Library/Application Support/TokenBar/singleton.lock`）
实现单实例——按文件加锁而不按 bundle ID 查询，是为了拦住「开发构建 + 正式安装版」以及
直接执行二进制这类绕过 LaunchServices 的双开。第二实例退出前经分布式通知唤醒首实例弹出
面板（与 Windows 端 Mutex + `EventWaitHandle` 行为对齐）；锁随进程退出（含崩溃）由内核
自动释放，不存在残留死锁。唤醒弹出的面板 5 秒后自动收回（唤醒示意没有自然关闭时机，
`.transient` 只在用户点击其他应用时关闭，pin 着不关会把弹窗打开期间的每帧成本拉长为
无限期），用户点按状态项即接管、不收；Dock / Finder reopen 路径用户在场，不自动收回。
锁文件创建失败（目录不可写等）时降级放行作主实例，只有 `flock` 明确被占才判定已有实例——
此前该场景会被误判成已有实例而 `exit(0)`，应用永远起不来。

### 2.3 国际化与本地化架构 (`I18n.swift`)
- **设计策略**：
  - 采用强类型枚举 `I18nKey` 管理所有中英文字符串键值。
  - `LocalizationManager` 单例维护 `cachedLanguage` 与 `@Published public var currentLanguage: AppLanguage`。
  - 读操作通过线程锁实现无锁/轻量读取，保证在后台解析线程与主线程均可安全同构调用 `I18n(.key)`。
  - 当用户在设置中变更语言时，通过发布通知与绑定 `@ObservedObject`，所有 UI 视图与系统菜单即时重绘。

---

## 3. Windows 原生端架构实现 (`windows/`)

Windows 客户端采用轻量现代的 **.NET 8 WPF** 架构，利用 Windows 原生消息机制与任务栏通知区（Taskbar Notification Area）无缝交互。

### 3.1 核心组件划分
1. **`TrayIconManager`**：
   - 封装 Windows Forms `NotifyIcon`，集成到右下角托盘。
   - 实现左键单击呼出 `PopoverWindow`、右键弹出多语言原生上下文菜单。
2. **`PopoverWindow`**：
   - 无边框（`WindowStyle="None"`）且透明背景（`AllowsTransparency="True"`）的现代化卡片浮窗。
   - 自动获取任务栏工作区边界（`SystemParameters.WorkArea`），精准定位在托盘图标上方。
3. **`SettingsWindow`**：
   - 独立的偏好设置窗口，提供厂商 Key/端点配置及中英文语言即时切换。
4. **`RefreshManager`**：
   - 基于 `System.Threading.Timer` 运行异步定时调度，定时器在 `Initialize()` 中先于首刷创建。
   - 配置通过 `System.Text.Json` 本地持久化到 `%AppData%\TokenBar\settings.json`。
   - **闸门看门狗**：`Interlocked` 抢占的基础上加 `_refreshStartedAtTicks` + `_refreshGeneration`，
     上一轮超过 90 秒未结束时强制抢占。以前一轮卡死就会让之后每次定时触发与手动刷新
     都被静默丢弃（与 macOS 端同源缺陷，详见 2.2 节）。
   - **单厂商超时隔离** `RunProviderAsync`：`Task.WhenAny(work, Task.Delay(budget))` 给每个
     provider 套独立预算（百炼 35s / Gemini 30s / 其余 25s），超时后补一次 `IsLoading=false`
     收尾，避免卡片一直转圈。`Quotas` 在初始化时已预填充全部 `ProviderType`，各刷新方法
     只改 `ProviderQuota`（class）的属性、不做结构性写入，因此并发访问该 `Dictionary` 是安全的。
   - **日志** `Log.cs`：写入 `%AppData%\TokenBar\tokenbar.log`（2MB 轮转一次）。Windows 没有
     `log stream` 的等价物，排查用 `Get-Content "$env:APPDATA\TokenBar\tokenbar.log" -Wait -Tail 50`。
     关键指标同样是 `timer fired，距上次 xxxs` 是否稳定在设定周期。

> **与 macOS 端的差异**：2.2.1 的第 1 条（`URLSession.shared` 的 7 天 resource 超时、URLCache
> 回放旧响应头）在 Windows 上不成立 —— `HttpClient.Timeout` 本身就是端到端总超时，且
> `SocketsHttpHandler` 默认不做响应缓存。第 2 条的钥匙串阻塞风险也低得多：凭据管理器
> (`CredReadW`) 不会弹授权框，且刷新链路跑在线程池线程而非 UI 线程。第 3 条的 pipe 读取
> 顺序 Windows 端本就正确（先 `ReadToEndAsync` 再 `WaitForExitAsync`），但补上了 20s 超时
> 与 `Kill(entireProcessTree)`，并关闭 stdin 防 `bl` 交互等待。
5. **凭据安全与系统集成 (`GeminiService` / `Advapi32`)**：
   - 原生 P/Invoke 调用 Windows 凭据管理器 (`advapi32.dll` `CredReadW`)，安全提取 Antigravity CLI (`agy`) 及 Antigravity IDE 托管的 Google One PRO 凭证（目标名 `gemini:antigravity`）。
   - 使用凭证中的 refresh_token 自动续期访问令牌（内存缓存约 1 小时有效期），调用 Google Code Assist 配额接口获取与 Antigravity 官方用量面板一致的真实数据；自动请求 Google UserInfo 接口解析用户邮箱，实现与 macOS 凭证管理完全同构。
6. **应用生命周期与单实例 (`App`)**：
   - `OnStartup` 通过命名 Mutex（`Local\TokenBar.SingleInstance.Mutex`）实现单实例保护，避免双托盘图标与重复额度 API 请求。
   - 第二实例启动时经命名 `EventWaitHandle` 通知首实例弹出额度浮窗后自行退出，对齐 macOS「重复启动即激活已有实例」的行为。
   - 首实例正常退出时释放 Mutex；异常崩溃由内核对象随进程销毁兜底，不会造成永久锁死。

---

## 4. 速率限制响应头 (Rate Limit Headers) 解析机制

各大模型厂商在 HTTP API 响应中会携带详细的速率与限额头信息，TokenBar 实现了针对各厂商规范的智能解析器：

```
+-------------------+-------------------------------------------------------------+
| 平台              | 核心响应头与解析策略                                        |
+-------------------+-------------------------------------------------------------+
| OpenAI            | x-ratelimit-remaining-tokens (剩余TPM)                      |
|                   | x-ratelimit-remaining-requests (剩余RPM)                    |
|                   | x-ratelimit-reset-tokens (重置时间，格式形如 1s, 6m0s)      |
+-------------------+-------------------------------------------------------------+
| Anthropic API     | anthropic-ratelimit-tokens-remaining                        |
|                   | anthropic-ratelimit-tokens-reset (ISO8601 时间戳)           |
+-------------------+-------------------------------------------------------------+
| Claude Code       | 本地读取 ~/.claude.json 会话配置与 OAuth 令牌，             |
|                   | 解析 5 小时滚动滑动窗口百分比与每周额度配额                 |
+-------------------+-------------------------------------------------------------+
| Google Gemini /   | 1. API Key 模式：直连 Generative Language API 探测配额状态；|
| Google One /      | 2. 账号授权 / Antigravity 模式（与 Antigravity 官方面板同源）：|
| Antigravity       |    - Windows: 原生 P/Invoke 调用 Windows 凭据管理器          |
|                   |      (`advapi32.dll` `CredReadW`) 安全读取 `gemini:antigravity`|
|                   |      Generic Credential；同时兼容读取 `%USERPROFILE%\.gemini\`|
|                   |      凭证文件；macOS: 读取 `~/.gemini/` 会话；               |
|                   |    - 使用 agy CLI 内置 OAuth 客户端自动刷新访问令牌，调用    |
|                   |      Google Code Assist `v1internal:retrieveUserQuotaSummary`|
|                   |      获取 "Gemini Models" 分组的每周 / 5 小时剩余比例与真实  |
|                   |      重置时间（fetchAvailableModels 逐模型兜底聚合）；       |
|                   |    - 支持内置 OAuth 2.0 Web 回环授权；获取失败时如实报错。  |
+-------------------+-------------------------------------------------------------+
| DeepSeek          | 查询 /user/balance 接口获取实时账户余额与赠送金额           |
+-------------------+-------------------------------------------------------------+
| 阿里云百炼         | 四级通道，顺序即优先级：                                     |
|                   | 1. AK/SK 原生（首选，双端并发）：以 ACS3-HMAC-SHA256 签名调用 |
|                   |    modelstudio.<region>.aliyuncs.com/modelstudio/cli/       |
|                   |    generateAccessToken (GenerateCLIAccessToken, 2026-02-10)  |
|                   |    换取控制台令牌，再以 Bearer 直调 /cli/api.json 网关查询    |
|                   |    tokenplan/personal/api/v2/usage；网关返回 NotLogined 时    |
|                   |    自动重新签发令牌并单次重试，天然规避 Web SSO 单点互踢；    |
|                   | 2. 只读复用本机 ~/.bailian/config.json 中已有的控制台令牌；   |
|                   | 3. 备用：官方 CLI (`bl usage token-plan --output json`) 子进程；|
|                   | 4. 兜底：控制台 Cookie 直调 /data/api.json 网关。             |
|                   | 响应解析统一走多层 unwrap，兼容以上三种嵌套形状。            |
|                   | 另经 BSS OpenAPI QueryAccountBalance 查询阿里云账户现金余额。|
+-------------------+-------------------------------------------------------------+
```

---

## 5. 安全与隐私架构

1. **本地存储隔离**：
   - 所有 API Key、OAuth Token 与用户设置均直接保存在用户本地电脑磁盘中，不上传至任何中心化云服务。
   - **全部凭证不落明文配置**：各厂商 API Key、Claude / Gemini OAuth token、控制台 Cookie、自定义厂商的
     Key 与 Cookie、阿里云 AccessKey Secret 与控制台令牌，macOS 一律存入系统钥匙串（Security.framework，
     service `TokenBar`，account 名见 `SecretKey` / `AppSecrets`），Windows 存入凭据管理器（`CredWriteW`，
     TargetName `TokenBar/<同名>`）。`AppSettings` 在内存里仍持有明文供刷新链路与设置页使用，
     但 macOS 的 `AppSettings.encode(to:)` / Windows 的 `AppSettings.SerializeForDisk()` 在
     `secretsInKeychain` / `SecretsInKeychain` 为 true 时不再把任何凭证写进 plist / settings.json。
   - **迁移与三态**：启动时 `RefreshManager.loadSecretsFromKeychain`（Windows：`LoadSecretsFromStoreAsync`）
     用 `lookupAll` / `LookupAllAsync` 逐键三态读取：
     found → 以安全存储为准；absent 且旧明文非空 → 迁入安全存储；unavailable → 保留旧明文、什么都不写不删，
     标志保持 false 让明文继续落盘兜底。全部键可信且迁移成功后才置 true 并重写配置清掉明文。
     保存时 `syncSecretsToKeychain` / `SyncSecretsToStoreAsync` 按差异写 / 删，「输入为空且这轮没读到」
     只保留不删（`AppSecrets.saveAction` / `AppSecrets.ResolveSave`，两端各有单测）。
     安全存储不可用时**不降级为新的明文写入**，而是在设置页横幅如实报错并保持既有明文兜底。
     自定义厂商被删除时，它的两个条目由差异同步顺带删除，**不要另开删除路径** —— 那会与同步任务
     在线程池上并发改同一份对齐表。
   - 网页授权窗口（`WebLoginWindowController`）使用非持久化 `WKWebsiteDataStore`，不把第三方整站登录态落进
     App 容器；completion 只触发一次。`GeminiService` 不再写回 Antigravity 的 `~/.gemini/jetski-standalone-oauth-token`。
   - 本机 `~/.bailian/config.json`（百炼 CLI 的配置）只读复用，**绝不写回** —— CLI 用 tmp+rename
     原子替换整个文件，并发写会覆盖掉它的其他字段。
2. **纯客户端通讯**：
   - 应用直接向模型提供商官方接入端点发起 HTTPS 请求，无任何二次代理服务器。
3. **开源透明**：
   - 代码遵循 MIT 许可证完全开源，可由社区开发者独立审计与验证。
