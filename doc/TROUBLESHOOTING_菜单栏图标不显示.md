# 菜单栏图标不显示：排查与解决方案

> 症状：TokenBar 在运行、进程健康、额度刷新正常，但菜单栏上**看不到图标**。
> 一句话结论：macOS 26 的 ControlCenter 把 `com.tokenbar.mac` 这个 bundle id 的状态项拉黑了
> （日志特征 `Moving host to blocked list`）；**拉黑是按 bundle id 的粘性会话态**，
> LaunchServices 死记录只是触发器之一，清除死记录是必要卫生、但不足以解除已存在的拉黑。
>
> 结论基于 2026-09-13/14 两轮受控实验，机制详录见
> `ARCH_系统架构设计文档.md`「状态项健康自愈」一节；本文是面向排障的操作手册。

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

全部在 `mac/Sources/TokenBar/MenuBar/MenuBarController.swift`，判定纯函数在
`mac/Sources/TokenBar/Services/StatusItemHealth.swift`：

- **清理时机**：启动时一次（`setup()`）+ 每次状态项重建前（`rebuildStatusItem`，
  清理完才重建——拉黑不解除时重建多少次都一样，所以顺序不能反）。
- **清理范围**：只清**本 bundle id** 且路径已不存在的注册（`NSWorkspace`
  的接口会过滤掉不存在路径，永远找不到死记录，必须解析 `lsregister -dump`；
  解析是纯函数 `staleLaunchServicesPaths(inDump:)`，有单测）。
- **失败可见化**：dump 起不来 / 被看门狗杀掉 / 退出码非 0 → error 级
  `LaunchServices 死记录清理[reason]：dump 执行失败，跳过核对`；成功无死记录 → notice 级
  `LaunchServices 注册核对[reason]：无死记录`；发现 N 条 → error 级
  `发现 N 条，注销 M 条`（M < N 即有失败，含不可写路径清单）。dump 带 15s 看门狗，
  防挂死卡住重建链路。
- **健康判据优先级**（`StatusItemHealth.evaluate`，顺序不可调）：
  `isVisible`（用户意图）→ 存在性/几何 → **镜像信号**（`mirror=false` → `notMirrored`）
  → 窗口服务器注册。`mirror` 查不到（nil）时忽略该信号，绝不因查不到判掉线。

## 五、构建与清理纪律（防再触发）

```bash
# 日常构建 / 分发构建（脚本会在删旧产物前自动 lsregister -u）
./Scripts/build_app.sh
./Scripts/build_app.sh --distribute

# 删除构建产物——一律走 --clean（先注销两个输出路径的 LS 记录再删），别直接 rm
./Scripts/build_app.sh --clean
```

`mac/build/` 与 `mac/build/dist/` 两个输出路径都会被 LaunchServices 注册着；直接 `rm`
其中任何一个，就是给 `com.tokenbar.mac` 制造新的死记录——下次 ControlCenter 重新评估时
可能再次触发拉黑。

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

---
*2026-09-14 · 基于 a42d45b / c0914de 两轮修复与当日受控实验整理；同日 13:42 重启实测
证伪「重启解除拉黑」，已回写 6.3 与第八节。如结论被后续验证修正，先更新本文与
`ARCH_系统架构设计文档.md` 对应段落。*
