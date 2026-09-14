# 菜单栏图标不显示：排查与解决方案

> 症状：TokenBar 在运行、进程健康、额度刷新正常，但菜单栏上**看不到图标**。
> 一句话结论（2026-09-14 晚第三轮定案）：macOS 26 的 ControlCenter 在
> `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
> 的 `trackedApplications` 里，把 `com.tokenbar.mac` 记成了 **VS Code（`com.microsoft.VSCode`）与
> ZCode（`dev.zcode.app`）名下的菜单项**（曾从这些 IDE 的终端直接把 TokenBar 跑起来，系统按"负责进程"归属），
> 而这两个应用在「系统设置 › 菜单栏 › 应用程序」里的开关是关的（`isAllowed=false`），名下所有菜单项连坐，
> 于是 TokenBar 每个新 host 创建后 ~20ms 被 `Moving host to blocked list`。同机 VPSQuota、UniDrop 被拉黑同理
> （挂在 VS Code / Antigravity 名下）。LaunchServices 死记录**不是**根因。
> 解除：在「系统设置 › 菜单栏 › 应用程序」把 **Visual Studio Code、ZCode 的开关打开**（UniDrop 还要开 Antigravity），
> 重启 TokenBar 即可；细节见第九节。
>
> 第一、二、六、七节保留前两轮的过程记录（其中"LS 死记录是触发器"的判断已被第九节推翻，
> 仅作历史参考）；机制详录见 `ARCH_系统架构设计文档.md`「状态项健康自愈」一节。

## 一、症状与快速定性

| 观察 | 表现 |
| :--- | :--- |
| 应用侧日志 | `状态项[launch+2s] verdict=detached(notMirrored) … mirror=false`（error 级，重建后依旧） |
| 几何 | frame 可以完全正常（`win=3349,1418 91x22` 这类），**纯几何判定会误判健康** |
| ControlCenter 日志 | `Moving host to blocked list; (bid:com.tokenbar.mac-TokenBarStatusItem-<pid>)`，出现在 host 创建后 ~20ms |
| 重启应用 / 重建状态项 | 无效——每个新 PID 照样秒拒 |

**最可靠的健康信号是"控制中心有没有为它渲染镜像"**（layer-25、onscreen、同 x 同宽的
ControlCenter 窗口），应用内已实现（`MenuBarController.menuBarHostMirrors`）；`mirror=false`
基本等价于被拉黑。

快速定性命令（ControlCenter 是否正在拉黑我们）：

```bash
command log show --last 10m --predicate 'process == "ControlCenter"' --info --debug \
  | grep -E "Moving host to blocked" | grep tokenbar | tail -5
```

> 注意两处 macOS/zsh 坑：调系统日志必须写 `command log`（zsh 的 `log` 是内建命令，
> 直接写会报 `too many arguments`）；`--info --debug` 不能省，这条日志是 Default 级但
> 同链路很多线索在 info 级。

## 二、根因模型（两层）

1. **触发层（LaunchServices）**：ControlCenter 创建状态项 host 时按 bundle id 查
   LaunchServices。历史实验（a42d45b，探针逐变量排除）确认：撞上一条**路径已不存在的
   陈旧注册记录**就会触发拉黑。反复挂 DMG 测试、换构建输出目录、删构建产物都会留下
   死记录。
2. **粘性层（会话态，2026-09-14 下午实测补充）**：死记录清零、LS 只剩
   `/Applications/TokenBar.app` 一条干净注册后，**拉黑仍不解除**。用 `com.tokenbar.mac`
   的最小探针 .app（无 autosaveName、ad-hoc 签名、`/tmp` 路径）照样 20ms 内被拉黑，
   全新 bundle id 的同款探针正常上屏——拉黑按 bundle id 精确命中，与应用代码、路径、
   签名、autosaveName 无关。重启 ControlCenter ×2、`tccutil reset All com.tokenbar.mac`、
   `lsregister -f` 重注册、`-u` 后再 `-f` 全部无效；ControlCenter 的全部落盘状态
   （defaults / ByHost displayablemenuextras / Application Support / Group Containers）
   查无该 bundle id 痕迹。结论：**拉黑状态活在重启 ControlCenter 不清的会话层
   （疑似 WindowServer），LS 死记录只是初始触发器**。

## 三、关键实测事实（别再踩）

以下全部为 2026-09-14 受控实验结论，写进过提交 `c0914de`：

1. `lsregister -u <path>` **只认路径上真实存在的合法 bundle**。路径已删除时直接失败
   （`failed to scan … -10814`）——对死记录直接 `-u` 永远无效。
2. 清除死记录的**唯一可行方式：原位重建一个最小 stub .app → `-u` → 删掉 stub**。
   应用内实现为 `MenuBarController.unregisterRecord`（stub 的 Info.plist 由
   `stubInfoPlist` 生成，CFBundleIdentifier 必须与死记录一致，否则 `-u` 匹配不上）。
3. `lsregister -gc` 清不掉死记录（对 `.app` 路径死记录与 `/Volumes` 死记录均无效）。
4. 同 bundle id 在新路径重新注册（`-f`）**不会**挤掉旧死记录。
5. 不可写路径（`/Volumes/...` 等已卸载卷）上的死记录无法用 stub 法清除，应用内会如实
   打日志留给人工处理。
6. 健康/掉线日志行是 `.info` 级（仅驻内存），**事后 `log show` 查不到**，验证必须先起
   `log stream` 现场盯着。
7. macOS 自带 BSD sed 不认 `\s`，`sed -E 's/^\s*path:\s+//'` 这类写法会**静默不生效**
   （管道后面 `[ -e $p ]` 全部误判）。要用 `[[:space:]]`。
8. `cp -R src /Applications/` 在目标 .app 已存在时会嵌套成
   `/Applications/TokenBar.app/TokenBar.app`；装包必须先 `rm -rf` 目标再用 `ditto`。
9. 日常构建（`build_app.sh` 默认）**不带 Hardened Runtime**，只有 `--distribute` 分支有
   `--options runtime`；验证 hardened 行为必须装 dist 版。

## 四、应用内自愈机制（代码指引）

> 本节原描述的 LaunchServices 死记录清理链路（`purgeStaleLaunchServicesRecords` / stub 注销 / dump 看门狗）
> 已于 2026-09-14 晚整体移除（根因证伪，见第九节）。现状如下。

全部在 `mac/Sources/TokenBar/MenuBar/MenuBarController.swift`，判定纯函数在
`mac/Sources/TokenBar/Services/StatusItemHealth.swift`：

- **健康判据优先级**（`StatusItemHealth.evaluate`，顺序不可调）：
  `isVisible`（用户意图）→ 存在性/几何 → **镜像信号**（`mirror=false` → `notMirrored`）。
  `mirror` 查不到（nil）时忽略该信号，绝不因查不到判掉线。
- **镜像匹配**（`menuBarHostMirrors`）：layer-25 控制中心窗口按窗口名（= autosaveName）精确匹配，
  拿不到窗口名（无屏幕录制权限）才退回同 x 同宽；只有同宽、x 不同的说明缓存 frame 过期，返回 nil。
- **重建预算**（`RebuildPolicy`）：一般掉线原因 5 次、指数退避；`notMirrored` 只 1 次，再无镜像返回
  `blockedBySystem`——一次 error 日志「状态项被 ControlCenter 拉黑…请到系统设置 › 菜单栏 › 应用程序…」
  + 一次系统通知，之后只保留心跳探测，用户放行后自动转 healthy。
- 调试键：`defaults write com.tokenbar.mac TokenBarForceStatusItemUnhealthy -bool YES` 强制 `mirror=false`，
  可完整走一遍"重建一次 → blockedBySystem 提示"链路；测完 `defaults delete` 掉。

## 五、构建与启动纪律（防再触发）

```bash
./Scripts/build_app.sh              # 日常构建 → mac/build/TokenBar.app
./Scripts/build_app.sh --distribute # 分发构建 → mac/build/dist/TokenBar.app
./Scripts/build_app.sh --clean      # 删除两个产物路径
open mac/build/TokenBar.app         # 调试启动一律用 open
```

**不要在 VS Code / ZCode 等 IDE 的集成终端里直接执行** `swift run`、`./.build/debug/TokenBar` 或
`xxx.app/Contents/MacOS/TokenBar`：macOS 26 的 ControlCenter 会把状态项记到"负责进程"（IDE）名下，
IDE 在「系统设置 › 菜单栏 › 应用程序」里一旦是关闭状态，TokenBar 的图标就被连坐隐藏，且这条归属不会自动清理。
（构建脚本此前的 `lsregister -u` 注销逻辑基于已证伪的死记录假设，已移除；删构建产物直接 `--clean` 即可。）

## 六、手动排查与清除手册

### 6.1 盘点死记录（先看再动手）

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# 本项目 bundle id 名下：死链 / 存活
$LSR -dump | grep -E '^[[:space:]]*path:[[:space:]]+/Users/chenzhenbo/Work/TokenBar' \
  | sed -E 's/^[[:space:]]*path:[[:space:]]+//; s/ \(0x[0-9a-f]+\)$//' | sort -u \
  | while read -r p; do [ -e "$p" ] && echo "[存在]  $p" || echo "[死链]  $p"; done
```

### 6.2 清除死记录

- **路径还在的记录**：`$LSR -u <path>` 直接有效。
- **路径已删除的记录**（.app 类）：`-u` 无效，需原位重建最小 stub（应用内已自动化；
  手动可参照 `unregisterRecord` 的做法：建 `Contents/Info.plist`（CFBundleIdentifier 填
  `com.tokenbar.mac`）+ 空 `Contents/MacOS/<可执行名>`，`-u` 后删掉 stub）。
- **`/Volumes/...` 卷路径死记录**：stub 法也够不着（不可写），只能重新挂载对应卷后
  `-u`，或走第 6.4 节的重手段。

### 6.3 解除已存在的拉黑（按验证程度排序）

| 手段 | 实测结果（2026-09-14） |
| :--- | :--- |
| 清 LS 死记录 + 重启应用 | 无效（拉黑是粘性态） |
| 重启 ControlCenter（`killall ControlCenter`，自动重生） | 无效 |
| `tccutil reset All com.tokenbar.mac` | 无效 |
| **注销重登 / 重启** | **实测无效**（2026-09-14 13:42 整机重启，13:46 开机自启首个 host 创建 20ms 后复现拉黑，此后全天各 PID 均秒拒） |
| `lsregister -kill -seed -r` 全库重建 | 重手段（影响全局默认应用关联），仅上述全部无效时考虑 |

> 判断拉黑是否已解除：跑第一节的两条命令——ControlCenter 日志不再出现
> `Moving host to blocked list`，且应用侧 `mirror=true`。

### 6.4 验证流程（装包后必做）

```bash
# 1. 先起日志流（.info 级不落盘，必须现场盯）
command log stream --predicate 'subsystem == "com.tokenbar.mac"' --level debug --style compact

# 2. 另开终端：装包并启动（别用 cp -R，会嵌套）
killall TokenBar 2>/dev/null
rm -rf /Applications/TokenBar.app
ditto mac/build/dist/TokenBar.app /Applications/TokenBar.app
open -a TokenBar
```

预期日志（健康）：
- `LaunchServices 注册核对[launch]：无死记录`
- `状态项[launch+2s] verdict=healthy … mirror=true`

若出现 `LaunchServices 死记录清理[launch]：发现 N 条，注销 N 条`，说明自愈生效
（stub 法在 hardened runtime 下也正常工作）。若持续
`verdict=detached(notMirrored) … mirror=false`，回到 6.3。

## 七、证据摘要（怎么定位到会话态的）

1. ControlCenter 日志时序：`Host properties initialized` → `Starting to track host` →
   `Created ephemeral instance … with positioning .ephemeral`（**ephemeral 是正常路径，
   健康探针同样有**）→ ~20ms 后 `Moving host to blocked list`。全程无 LaunchServices
   查询日志。
2. bid 格式 `<bundle id>-<autosaveName>-<pid>`；拉黑跨 PID、跨 autosaveName、跨应用
   路径、跨签名方式复现 → 按 bundle id 粒度。
3. 探针二分：全新 bundle id 正常上屏；`com.tokenbar.mac` 最小探针秒拒 → 与应用代码无关。
4. 排除清单（全部查过且阴性）：LS 死记录/多注册、ControlCenter 落盘状态
   （defaults、ByHost displayablemenuextras、App Support、Group Containers）、Dock/
   systemuiserver/loginwindow 偏好、TCC（归因成功 + reset 无效）、launchd application
   handle（无陈旧项）。

## 八、遗留事项

- [x] **注销重登后闭环验证（2026-09-14 已做，结论证伪）**：13:42 整机重启 → 13:46 开机自启
      首个 host 20ms 内复现拉黑，全天各 PID 均秒拒。「拉黑随会话清除」不成立——要么跨重启
      持久，要么重启后又被即刻再触发（重启瞬间的 LS 状态未留档，两种可能无法区分）。
- [ ] **排查面扩大**：2026-09-14 16:20 实测无关应用 `io.vpsquota.VPSTrafficQuota` 与
      `com.unidrop.client` 同被 blocked；「按 bundle id 精确命中」的结论需重新审视，
      可对照三者在 ControlCenter 判定条件下的共同点。
- [ ] **应用内 stub 注销法自愈复测**：`lsregister -f` 注册 `mac/build` 产物路径后把
      .app 挪走制造死记录，重启应用，预期日志「死记录清理[launch]：发现 1 条，注销 1 条」。
- [ ] UniDrop（`com.unidrop.client`）名下 26 条 `/Volumes` 死记录无法自动清除
      （2026-09-14 盘点；同日晚全机 `/Volumes` 死记录共 48 条，含 ZCode/AutoClaw/Qoder/
      Claude 等卷），需重新挂载对应卷清理或全库重建时顺带解决；UniDrop 应用侧
      也可移植本项目的检测/自愈逻辑。

## 九、第三轮排查（2026-09-14 16:35 重启后）：拉黑来自 ControlCenter 的持久「应用菜单栏项」记录

### 9.1 现场证据链

开机 16:35:42，ControlCenter(pid 498) 16:36:18 起；TokenBar 开机自启 16:37:15，
每个 host 创建后 ~20ms 被拉黑，之后每次重建、每次重启进程都一样。完整时序
（`command log show --info --debug --predicate 'process == "ControlCenter"'`）：

```
Host properties initialized; (bid:com.tokenbar.mac-TokenBarStatusItem-<pid>)
Starting to track host; ...
(TCC) tcc_send_get_identity_for_credential() IPC        ← 用 audit token 向 tccd 取 host 身份
Created new displayable type ... / Adding displayable items ... / Created ephemaral instance ...
[SystemItemMenuBarPreferences] Preferences: changed     ← 连续两条
[SystemItemMenuBarPreferences] Preferences: changed
Moving host to blocked list; ...                        ← 拉黑
Responding to displayables availability update; hiding status items for [...]
```

关键对照：ControlCenter **一启动**就把微信、QQ、钉钉、飞书、网易邮箱大师、WorkBuddy、密码、
Claude 等按 `Starting to track blocked host` 直接跟踪（没有 `Moving` 事件）——这些应用在
「系统设置 › 菜单栏 › 应用程序」里的开关**全是关的**，菜单栏里也确实没有它们的图标。
说明 blocked 名单是持久化的、跨重启的，并且就是这份系统设置。

### 9.2 决策逻辑在哪（ControlCenter 二进制符号）

`strings` / `nm` / `otool -tV` 反查 `/System/Library/CoreServices/ControlCenter.app` 与
dyld 缓存里的私有框架 `ControlCenter.framework`：

- 类 `SystemItemMenuBarPreferences`（`shared`，`SecuredPreferencesController` 存储）：
  `trackedApplications: [TrackedApplicationLocation: TrackedApplication]`、
  `TrackedApplication { isAllowed, location, menuItemLocations }`（Codable，
  `BundleCodingKeys` / `AdhocBinaryCodingKeys` 两种身份）、
  `TrackedApplicationLocation { menuBar, controlCenter, bentoBox }`、
  `startTrackingApplication(for: bundleID, auditToken:)` / `(at: URL, auditToken:)`、
  `blockTrackedApplication(for:auditToken:)` / `(at:auditToken:)`、`stopTrackingApplication`。
- 调用 `blockTrackedApplication` 的函数里紧邻的日志串：`Requesting host set visibility to false`、
  `Unable to handle user removal of menu extra for %s; no available host for %s`——即
  "用户把菜单栏项移除"的处理路径；另有 `Unable to verify new host id for app status item type`。
- 拉黑判定函数（含 `Moving host to blocked list` 的那个）先取
  `TrackedApplication.menuItemLocations`，遍历比较 `TrackedApplicationLocation` 枚举，再决定拉黑。
- 落盘路径（dyld 缓存字符串）：
  `Library/Group Containers/group.com.apple.secure-control-center-preferences/Library/Preferences/group.com.apple.secure-control-center-preferences.*.plist`。
  该目录受 TCC 保护，普通 shell `ls` 直接 `Operation not permitted`——**这就是前两轮
  "ControlCenter 落盘状态查无该 bundle id"的原因：根本没读到。**
- 设置面板扩展 `ControlCenterSettings.appex` 里有 `TrackedApplicationsView`，文案
  「在菜单栏显示 / 不在菜单栏显示 / 在控制中心显示 / 始终在菜单栏显示」，以及
  「应用程序可添加菜单栏项……**菜单栏项关闭后，将无法再在菜单栏显示**」。

### 9.3 本轮实测排除项（别再查）

| 假设 | 实验 | 结果 |
| :--- | :--- | :--- |
| LS 同 bundle id 多条注册 | 注销 `mac/build` 与 `mac/build/dist` 两条，只剩 `/Applications` 一条后重启应用 | 仍 20ms 拉黑 |
| 安装路径 | 分别从 `/Applications`、`mac/build`、`mac/build/dist` 启动 | 三处都拉黑 |
| 被挪进了控制中心面板 | 解码 ByHost `com.apple.controlcenter.bentoboxes` 的 `boxes`→`displayablesData`（嵌套 bplist） | 只有系统模块，没有任何应用项 |
| ControlCenter 自己的 defaults | 递归解码 `com.apple.controlcenter` 里所有 JSON/base64/bplist 字段（`MenuBarCustomizationState`、`ControlCenterDisplayableChronoControlsProviderConfiguration` 等） | 无 tokenbar/unidrop/vpsquota |
| 用户拖出菜单栏（`NSStatusItem VisibleCC <autosave> = 0`，写在**应用自己的域**里） | 全盘扫 Preferences / ByHost / Containers | 钉钉、WPS、Passwords、OpenAI Sky 有该键；tokenbar 三个域都没有 |
| 不是 .app 包的裸可执行文件 | 直接运行 `mac/.build/arm64-apple-macosx/debug/TokenBar`（ad-hoc 签名，内嵌 Info.plist 同 bundle id） | **正常上屏**（layer-25 出现 `TokenBarStatusItem` 镜像，x=2718 宽 107），ControlCenter 甚至不为它记 host 日志——拉黑只针对 bundle 身份的记录 |
| 签名差异 | TokenBar/VPSQuota 未公证、UniDrop 已公证，都被拉黑；Tailscale/Google Drive 等正常 | 与公证/Gatekeeper 无关 |

### 9.4 落盘记录长什么样（sudo 拷出 plist 后解码，2026-09-14 17:27）

文件：`~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
（目录受 TCC 保护，普通 shell 连 `ls` 都是 Operation not permitted，要 `sudo cp` 出来再解；同目录
`group.com.apple.secure-control-center-preferences/...av.plist` 是音视频权限的，不相干）。
顶层键 `showSpotlight` / `showWeather` / `trackedApplications`，后者是一段 bplist，内容是
`[TrackedApplicationLocation: TrackedApplication]` 字典（数组形式 key,value 交替），共 64 条。
每条 `TrackedApplication { location, menuItemLocations: [Location], isAllowed }`，`Location` 是
`bundle(<bundle id>)` 或 `adhocBinary(<file URL>)`。与本项目相关的几条：

| 记录（location） | isAllowed | menuItemLocations |
| :--- | :--- | :--- |
| `bundle:com.tokenbar.mac` | true | `com.tokenbar.mac` |
| **`bundle:com.microsoft.VSCode`** | **false** | `com.unidrop.client`, **`com.tokenbar.mac`**, `io.vpsquota.VPSTrafficQuota`, `com.unidrop.traytest` |
| **`bundle:dev.zcode.app`** | **false** | **`com.tokenbar.mac`** |
| `bundle:com.google.antigravity` | false | `com.google.antigravity`, `com.unidrop.client` |
| `adhoc:…/mac/.build/arm64-apple-macosx/debug/TokenBar` | true | 自身（裸可执行文件独立成记录，所以能上屏） |
| `bundle:com.tokenbar.probe5` | true | 自身（探针新 bundle id，能上屏） |

判定逻辑（与 ControlCenter 反汇编里"遍历集合 → 比较 → 命中即处理"的循环吻合）：新 host 的 bundle id
只要出现在**任何一条 `isAllowed=false` 记录的 `menuItemLocations`** 里，就被拉黑，不管它自己那条记录开关如何。
「系统设置 › 菜单栏 › 应用程序」列表里每一行就是一条记录；TokenBar 的两行 = `bundle:com.tokenbar.mac` +
`adhoc:…/debug/TokenBar`（后者无图标）。

**怎么挂到 VS Code / ZCode 名下的**：从 IDE 集成终端直接执行 TokenBar 可执行文件（`swift run`、
`./.build/debug/TokenBar`、`mac/build/TokenBar.app/Contents/MacOS/TokenBar`）时，进程的"负责进程"是 IDE，
ControlCenter 按负责进程归属菜单项。用 `open` 启动的 .app 由 launchd 负责，不会被归到 IDE 下。

### 9.5 解除步骤

1. **系统设置 › 菜单栏 › 应用程序**：把 **Visual Studio Code、ZCode 的开关打开**（把这两条记录的 `isAllowed`
   置 true，名下的 `com.tokenbar.mac` 随之解封；UniDrop 还需打开 Antigravity）。
   **2026-09-14 17:4x 实测有效**：开关打开的瞬间 ControlCenter 日志出现
   `Unblocking host; (bid:com.tokenbar.mac-TokenBarStatusItem-39125)`，正在运行的进程无需重启即恢复；
   之后新启动的进程只有 `Starting to track host`，layer-25 出现 `TokenBarStatusItem` 镜像（x=2605 宽 107），
   菜单栏图标回来了。副作用只是允许这些 IDE
   "名下"的菜单项显示，它们自身并没有状态项。然后 `killall TokenBar && open -a TokenBar`，
   跑第一节的命令确认没有新的 `Moving host to blocked list`，应用日志 `mirror=true`。
2. 只想让 TokenBar 自己那行开关起作用而不动 IDE 的开关：`sudo` 拷出上述 plist，用 plistlib 从
   VS Code / ZCode 记录的 `menuItemLocations` 里删掉 `com.tokenbar.mac`，写回原路径（保持 600 权限）后
   `killall ControlCenter`。属于改系统偏好文件，优先走第 1 步。
3. 已实测**无效**的手段：清 LS 死记录、重启 ControlCenter、`tccutil reset`、整机重启、
   TokenBar 自己那行开关关再开（只写 `Preferences: changed`，不改 IDE 记录）。
4. **预防**：开发时不要在 IDE 集成终端里直接执行 TokenBar 可执行文件；构建后一律 `open mac/build/TokenBar.app`
   或 `open -a TokenBar`。已经挂错的归属不会自动清理。
5. 应用侧改造（2026-09-14 晚已落地）：`notMirrored` 只重建一次，再无镜像即 `blockedBySystem`——
   error 日志「状态项被 ControlCenter 拉黑…请到系统设置 › 菜单栏 › 应用程序…」+ 一次系统通知，
   停止重建、保留心跳探测；用户放行后自动转 healthy。镜像匹配改为按 layer-25 窗口名（autosaveName）
   优先，几何兜底，缓存 frame 过期时忽略信号，不再把健康项误判成 `notMirrored`。
   LS 死记录清理链路（约 300 行）与恒为 nil 的窗口服务器信号已整体删除。验证日志：`verdict=healthy … mirror=true`。

---
*2026-09-14 · 基于 a42d45b / c0914de 两轮修复与当日受控实验整理；同日 13:42 重启实测
证伪「重启解除拉黑」；同日 16:35 重启后第三轮（第九节）读到 ControlCenter 组容器里的 `trackedApplications`，定案为
TokenBar 被记在开关已关的 VS Code / ZCode 名下连坐拉黑，推翻"LS 死记录是触发器"的判断。如结论被后续验证修正，先更新本文与
`ARCH_系统架构设计文档.md` 对应段落。*
