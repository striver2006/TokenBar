# Mac Gemini 周额度请求头修复

日期：2026-10-22（Asia/Singapore）

## 现象与根因

本机 TokenBar 1.7.2 的 Gemini 卡片缺少每周额度。Antigravity 官方客户端的 Models & Usage 页面实际仍显示 Gemini 周额度、5 小时额度，以及独立的 Argon 周额度。

此前仅检查 TokenBar 请求后得出的「接口没有 Gemini 周额度」结论不完整：同一账号、同一端点、同一请求体，上游会根据 `User-Agent` 中的客户端版本返回不同分组。

2026-10-22 对 `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` 的对照实测如下。所有请求体均为 `{}`，使用同一凭证：

| User-Agent | 返回分组 |
| --- | --- |
| `antigravity` | 仅 Claude and GPT models |
| `antigravity/1.0.0` | 仅 Claude and GPT models |
| `antigravity/2.25.0` | Gemini Models + Claude and GPT models |
| `antigravity/2.25.0 darwin/arm64` | Gemini Models + Claude and GPT models |

带版本格式来自本机官方 Antigravity 2.25.0 客户端。另一次带 project 的对照在 cloudcode-pa 与 daily-cloudcode-pa 上均观察到相同差异；单独增加 project 不能恢复 Gemini 分组。

裸 User-Agent 导致 Gemini 分组缺失，程序转入 `fetchAvailableModels` 回退。该回退仅返回模型剩余比例与重置时间，现有实现映射为 5 小时窗口，周窗口为 nil，因此界面隐藏周额度。

官方套餐文档仍列出每周限额，不能将此次接口分组缺失解释为套餐取消周额度：https://www.antigravity.google/docs/plans 。

## 修改范围

- 仅修改 Mac 的 `GeminiService.swift`：Cloud Code 请求统一使用已实测有效的 `antigravity/2.25.0`。
- 该常量表示接口兼容版本；不依赖本机 Antigravity 保持运行，也不读取其进程参数。
- 继续保留逐端点解析、Gemini 正主组优先和模型回退逻辑。
- 未修改 Windows、应用版本号或界面布局。

## 验证

- `swift test --filter GeminiCredentialTests`：14 项通过，0 失败。
- 一次性 Swift 在线探针：从修改后的源码提取原始 `postCloudCodeOnce` 方法与 User-Agent 常量，连同生产 `HTTPClient.swift` 编译执行；返回 Gemini `weekly` 与 `5h` 两窗。
- 在线探针读数：周额度剩余 71.75362%，5 小时额度剩余 77.08381%。这是当时快照，使用中会变化。
- 排查过程中本地文件中的 access token 过期，旧 token 的 Python 与 Swift 请求均返回 401；通过现有 OAuth refresh 流程刷新后，上述 Swift 探针通过。未改写本地凭证文件，未将凭证写入仓库、日志或文档。
- 本次未新增与常量赋值重复的单元测试；版本兼容行为由真实接口对照与 Swift 在线请求验证。

## 安装与验收

- `mac/Scripts/build_app.sh`：Release 通用架构（arm64 + x86_64）构建成功，使用现有 Developer ID 证书签名。
- 构建输出包含现有 SecretStore API 弃用警告，以及当前部署目标下 x86_64 架构弃用警告；无构建错误。Intel 真机运行未测。
- 安装前核对新旧应用的 designated requirement 完全一致；新产物与安装后的应用均通过 `codesign --verify --deep --strict`。
- 原应用备份：`mac/build/backups/TokenBar-20261022-091253.app`（本地产物，不提交）。
- 已替换并启动 `/Applications/TokenBar.app`，启动日志确认运行路径、版本 1.7.2、PID 44962；初次刷新于 09:13:06 完成。
- 已通过实际 TokenBar 弹出面板的辅助功能树验收：Google Gemini 卡片显示「5 小时额度剩余 77%」与「每周额度剩余 72%」，周额度重置时间为 10-24 10:17。
- 安装二进制与构建二进制 SHA-256 一致：`2e333be7843327ebb83d3eb6639fcdcb337aaa25d8925cf561063e14dea85265`。
- 未执行公证、发布、Git 提交或推送。

## 后续风险

此接口的客户端版本条件属于上游行为，未来可能继续变化。若再次出现分组缺失，应先对比官方客户端与相同条件下的请求响应，不应直接将 Claude/GPT 的周额度作为 Gemini 额度。

## Windows 实现对照

按用户提示重新刷新 origin、gitcode 并核查 Windows 实现；两端 main 仍均为 `0fa48f5`。

- Windows 在 `0fa48f5` 中已修复端点选择：cloudcode-pa 优先、逐端点寻找 Gemini 分组、优先选择 Gemini Models 正主组。Mac 在同一提交中已有对应实现。
- Windows 当前 `PostCloudCodeOnceAsync` 仍显式发送裸 `User-Agent: antigravity`；本次 Mac 修复补充的是客户端版本兼容，不替换已存在的端点选择和解析逻辑。
- 从请求构造代码推断，Windows 也可能受到相同的上游版本条件影响；Windows 实机未测。本轮未修改 Windows 代码。
