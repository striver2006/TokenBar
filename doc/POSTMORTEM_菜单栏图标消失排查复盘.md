# 复盘：macOS 26 菜单栏图标消失（2026-09-13 ~ 2026-09-14）

> 三轮排查、两次误判、一次定案。本文只写"经验"：哪些判断错了、为什么错、最后怎么找到的、
> 以后怎么避免。操作细节与命令见 `TROUBLESHOOTING_菜单栏图标不显示.md`，机制描述见
> `ARCH_系统架构设计文档.md`「状态项健康自愈」一节。

## 一、结论速览

| 项 | 内容 |
| :--- | :--- |
| 症状 | TokenBar 正常运行、额度刷新正常、`tb` 唤醒弹窗正常，但菜单栏没有图标 |
| 直接原因 | macOS 26 的 ControlCenter 在状态项 host 创建后 ~20ms 执行 `Moving host to blocked list` 并隐藏 |
| 根因 | ControlCenter 组容器 `group.com.apple.controlcenter.plist` 的 `trackedApplications` 里，`com.tokenbar.mac` 被记在 **VS Code、ZCode 两条 `isAllowed=false` 记录的 `menuItemLocations`** 下；规则是"bundle id 出现在任一禁止记录的菜单项列表里即拉黑"，TokenBar 自己那条允许记录不起作用 |
| 归属怎么来的 | 曾在 IDE 集成终端里直接执行 TokenBar 可执行文件，系统按"负责进程"把状态项记到了 IDE 名下 |
| 解除 | 系统设置 › 菜单栏 › 应用程序：打开 Visual Studio Code、ZCode 的开关；或 sudo 改 plist 删掉归属后 `killall ControlCenter` |
| 预防 | 调试一律 `open xxx.app` 启动，不要在 IDE 终端直接跑可执行文件 |
| 与应用代码的关系 | 无关。应用内"清 LS 死记录 + 5 次重建"的自愈链路对此无效 |

## 二、时间线与判断演变

### 第一轮（09-13 ~ 09-14 上午）：LaunchServices 死记录

- 现象：状态项对象活着、几何正常，但控制中心 layer-25 层没有它的镜像窗口。
- 用探针 .app 逐变量排除（autosaveName、宽度、签名、多副本、主菜单…），发现"冒用 `com.tokenbar.mac` 就被拉黑，换新 bundle id 就正常"。
- 同期 `lsregister -dump` 里确实有路径已删除的死记录，注销后探针"立即恢复"，于是定为根因，
  写进 a42d45b / c0914de：应用内解析 dump、stub 法注销死记录、重建前先清理。
- **事后看错在哪**：探针恢复那一次很可能是探针自身在 `trackedApplications` 里单独成了一条允许记录，
  与 LS 无关；"注销后恢复"是巧合被当成了因果。第一轮没有做"不清 LS、只换条件"的反向对照。

### 第二轮（09-14 中午 ~ 下午）：粘性会话态

- LS 清到只剩 `/Applications` 一条干净注册，仍被拉黑；重启 ControlCenter、`tccutil reset`、整机重启都无效。
- 搜遍 `defaults` / ByHost / Application Support / Group Containers 都"查无该 bundle id"，于是推断"拉黑是活在
  WindowServer 一类对重启免疫的会话层"。
- **事后看错在哪**：Group Containers 下两个 ControlCenter 目录是 TCC 保护的，`ls` 报 `Operation not permitted`
  而 `find` 静默返回空，被当成了"目录是空的"。**"查无痕迹"和"没权限查"必须区分**，这一步的假阴性把整条推理带偏了。
  另外"重启无效"本来就与"持久化落盘"相容，却被解读成了"会话态"。

### 第三轮（09-14 16:35 重启后）：定案

1. **先看别人**：开机后 ControlCenter 一启动就把微信、QQ、钉钉、Claude 等十来个应用按 `Starting to track blocked host`
   直接跟踪，没有 `Moving` 事件——名单是持久的，而且这些应用在「系统设置 › 菜单栏 › 应用程序」里开关全关。
   这一步把问题从"TokenBar 特有"拉回到"系统有一份名单"。
2. **看日志时序**：拉黑前紧邻两条 `SystemItemMenuBarPreferences: Preferences: changed` 和一次向 tccd 的
   `TCCGetIdentityForCredential`，锁定决策类名。
3. **反查二进制**：`strings` / `nm | swift demangle` / `otool -tV` 在 ControlCenter 主程序与 dyld 缓存里找到
   `SystemItemMenuBarPreferences.trackedApplications`、`TrackedApplication{location, menuItemLocations, isAllowed}`、
   `blockTrackedApplication(for:auditToken:)`、`SecuredPreferencesController`，以及设置面板扩展的
   「在菜单栏显示 / 不在菜单栏显示」文案，确认这是系统设置的一部分。
4. **排除法收口**：LS 注册条数、安装路径、autosaveName、控制中心面板内容、ControlCenter defaults 全部 JSON/bplist
   字段、`NSStatusItem VisibleCC` 键、公证状态，逐项实测排除；同时发现裸可执行文件（非 .app）和新 bundle id 探针能上屏。
5. **拿到原始数据**：让用户 `sudo cp` 出组容器里的 plist，plistlib 解开嵌套 bplist，64 条记录一览无余，
   `com.microsoft.VSCode` 与 `dev.zcode.app` 名下的 `com.tokenbar.mac` 直接给出答案。

## 三、方法论上的教训

1. **先区分"没有"和"看不到"**。任何一次搜索/枚举返回空，先确认自己有没有权限、工具有没有静默失败
   （`find` 对 TCC 目录静默、BSD `sed` 不认 `\s`、zsh 的 `log` 是内建命令）。第二轮整个推论建立在一个假阴性上。
2. **相关不是因果，要做反向对照**。第一轮"注销死记录后探针恢复"没有配"不注销、换别的条件"的对照组。
   第三轮补上后（LS 清到 1 条仍拉黑；换 bundle id 立即正常），第一轮结论当场倒掉。
3. **系统级问题先看同类受害者**。UniDrop、VPSQuota 同时中招是第二轮就注意到的线索，但被当成"待重审"搁置了；
   第三轮一开始就拿它们和正常应用（Tailscale、Google Drive）对照，很快把范围收窄到"系统有名单"。
4. **日志的"前一条"往往比报错本身更有信息**。`Moving host to blocked list` 看了两天，直到把它前面 5ms 的
   `Preferences: changed` 和 tccd 调用当成线索，才找到决策类。
5. **私有框架不神秘**。`strings` 找日志格式串 → `otool -tV` 按 `literal pool for:` 反查函数 → `nm | swift demangle`
   拿类型与属性名 → 缓存里 `strings` 拿路径与键名。一小时能把黑盒变成半透明，比继续猜便宜。
6. **系统"隐藏一切细节"的 UI 背后一定有落盘**。看到设置面板里有对应的列表，就应该直接去找它的存储，
   而不是先在 `defaults` 里猜键名。
7. **应用侧自愈要有上限和"识别放弃"**。5 次重建对系统级拉黑毫无作用，还让 ControlCenter 每次重写偏好。
   遇到"几何正常但镜像缺失"应只重建一次，然后把用户引到系统设置。

## 四、可复用的排查手段

- 判定是否被拉黑：
  `command log show --last 10m --predicate 'process == "ControlCenter" AND eventMessage CONTAINS "blocked list"'`
- 看拉黑前后完整上下文（含 tccd）：加 `--info --debug`，谓词加上 `process == "tccd"`。
- 看名单：`sudo cp ~/Library/Group\ Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist /tmp/`
  后用 python `plistlib` 解 `trackedApplications`（bplist，key/value 交替数组）。
- 健康判据：控制中心 layer-25 层是否有同名镜像窗口（`CGWindowListCopyWindowInfo`），不要只看几何。
- 探针法：`swiftc` 单文件 + 手工 .app + 同证书签名，用环境变量切换 autosaveName 等条件，`open -W -n` 跑完
  `lsregister -u` 再删。
- 后台核对系统设置：computer-use 的 `app_screenshot` 可以不抢焦点截「系统设置」窗口，只看不改。

## 五、遗留与后续

- [ ] 应用侧：镜像缺失但几何正常时只重建一次，并在日志/通知里指引用户去「系统设置 › 菜单栏 › 应用程序」。
- [ ] 应用侧：镜像匹配容忍缓存 frame 过期（实测镜像在 x=2718、缓存 frame 停在 3333 时误报 `mirror=false`）。
- [ ] 评估是否保留 `purgeStaleLaunchServicesRecords`：它对本问题无效，但作为构建卫生仍无害。
- [ ] UniDrop 同样挂在 VS Code / Antigravity 名下，`unidrop-client` 两条 adhoc 记录是禁止状态，一并处理。
- [ ] 第一、二轮的结论已在 `TROUBLESHOOTING_菜单栏图标不显示.md` 顶部标注为历史记录，内容保留供比对。

---
*2026-09-14 · Edit by CZB*
