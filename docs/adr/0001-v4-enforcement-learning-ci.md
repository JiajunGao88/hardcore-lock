# ADR-0001: v4 全面升级 —— 锁定可靠性、真正的在线学习、CI

**Status:** Proposed（代码已在 `upgrade/v4-hardening-ml-ci` 分支实现，待真机验证后改为 Accepted）
**Date:** 2026-11-02
**Deciders:** Jiajun Gao

## Context

用户反馈三类问题：

1. **调好时间也不锁** —— 设置了时长/日程，App 却没被锁住。
2. **能被关掉、有时不生效** —— 锁定可以被绕过。
3. **"AI" 名不副实** —— 现在只是区间频率统计，连机器学习都算不上。

另外项目没有任何 CI，所有改动都只能靠真机手测，回归频繁（git log 里连续 5 个提交都在修上一个提交引入的问题）。

### 审计发现（按严重度）

| # | 问题 | 位置 | 后果 |
|---|------|------|------|
| 1 | 手动锁的 `DeviceActivitySchedule` 只用了 时:分:秒、`repeats: false` | `AppBlocker.startBlocking` | **≥24h 的锁会在 (时长 mod 24h) 后被扩展的 `intervalDidEnd` 提前解除**；恰好 24h 时起止相同直接抛 `intervalTooShort`，锁根本启动不了；跨午夜的锁语义不明确 |
| 2 | 扩展收到 `intervalDidEnd` 就无条件清除手动锁 | `DeviceActivityMonitorExtension` | 改系统时间 → 区间提前结束 → 锁被清除 |
| 3 | 锁的结束时间只存在 App 自己的 `UserDefaults.standard` | `LockManager` | 扩展无从得知真实结束时间，只能盲清 |
| 4 | 剩余时间用墙上时钟 `Date()` 计算 | `LockManager` | 设置里把时间往后拨 → 打开 App → App 认为锁已结束 → 主动 `stopBlocking()` |
| 5 | 日程正在拦截时可以直接关开关 / 编辑 / 删除 | `ScheduleManager.setEnabled/delete/upsert` | **一个开关就能解除"硬核"拦截** |
| 6 | 可以直接删除 FIFTEEN 本身 | —— | `.individual` 授权下删 App 会移除所有屏蔽（README 里"删 App 也没用"的说法是错的） |
| 7 | 授权状态用缓存"兜底" | `FamilyControlsManager` | 用户在设置里撤销 Screen Time 权限后，App 仍以为已授权，写入的屏蔽全部静默失效 —— **"设置了却不锁"的直接成因之一** |
| 8 | App Group 未注册时静默降级到 `.standard` | `AppGroup.defaults` | Release 包里扩展读不到日程 → 日程永不触发，且没有任何提示 |
| 9 | 未使用的 SwiftData `ModelContainer`，失败时 `fatalError` | `Hardcord_Lock_AppApp` | 存储损坏即启动崩溃，且毫无用处 |
| 10 | "AI" = 全局小时频率直方图 + 固定阈值 | `AIPredictor` | 不区分工作日/周末，不会遗忘旧习惯，没有置信度，提醒提前量写死，不从用户反馈学习 |

### 硬约束（决定了"AI"能做成什么样）

- Apple 把 Screen Time 用量数据沙盒化：**主 App 读不到逐 App 的使用时长**。唯一能拿到的信号是 `DeviceActivityEvent` 的阈值事件（"本窗口内累计用了 ≥5 分钟"）的时间戳，以及 App 自己产生的数据（提醒被接受/忽略、锁是否完成）。
- `DeviceActivityReport` 扩展能看到明细但不能把数据导出给 App。
- 监控扩展内存上限约 6MB，任何模型都必须能在里面增量更新。
- 一个 App + 扩展最多 20 个 DeviceActivity 监控。
- 不能把用量数据发到云端（隐私承诺 + App Review）。

所以"接一个大模型去分析用量"在 iOS 上**不可行**：大模型同样看不到用量数据。

## Decision

### 1. 锁定可靠性（P0）

- **锁记录进 App Group**（`ManualLockRecord`：墙钟起止 + 单调时钟起点 + 本次开机 ID + 来源），App 与扩展共享同一事实。
- **防改时间**：同一次开机内用 `CLOCK_MONOTONIC_RAW`（包含休眠时间，用户改不了）判断是否到期；跨重启才退回墙钟。倒计时也用单调时钟，改时间不影响显示。
- **手动锁分段调度**：用完整的 年-月-日 时:分:秒 组件，每段最长 24h；扩展在 `intervalDidEnd` 时先查锁记录，**未到期就重新上屏蔽并续下一段**，到期才清除。续段失败时屏蔽保持（fail-closed），下次打开 App 再清。
- **日程承诺锁**：日程处于拦截中时，禁止关闭、编辑、删除，UI 显示"锁定至 HH:MM"。
- **防卸载**：锁定/日程拦截期间设置 `ManagedSettingsStore.application.denyAppRemoval`（默认开，可在空闲时关闭）。
- **授权状态如实反映**：订阅 `AuthorizationCenter.$authorizationStatus`，去掉缓存兜底；未授权时首页给出红色提示。
- **健康检查**：首页显示 App Group 未配置、Screen Time 未授权、扩展长时间无心跳等问题，而不是静默失败。
- 删除 SwiftData/`Item`。

### 2. 真正的在线学习（P1）

- **分层贝叶斯时段模型**（`HabitModel`）：每个 (星期几 × 小时) 一个 Beta-Binomial 后验，先验来自"所有天同一小时"的合并估计（经验贝叶斯收缩）—— 新用户先用合并估计，数据多了自动分化出工作日/周末差异。所有计数按 21 天半衰期指数遗忘，习惯变了模型会跟着变。决策用后验**下置信界**而不是点估计，避免 3 个样本就"发现高峰"。整个模型 168×3 个数，在扩展里增量更新。
- **按星期几分别提醒**：每个星期几独立的高峰时刻和提醒（7 个通知），不再全周共用一个时间。
- **Thompson Sampling 多臂老虎机**学习提醒提前量（5/10/15/20/30 分钟）：用户点"LOCK NOW"=奖励 1，点"Not today"或划掉=0。可在 AI 页关闭自适应、改回固定提前量。
- **端侧大模型教练（iOS 26+，可选）**：在支持 Apple Intelligence 的设备上，用 `FoundationModels` 端侧模型把模型统计（不含任何 App 名称）写成个性化的周报洞察和提醒文案。不支持的设备自动隐藏，核心功能不依赖它。

### 3. CI（P0）

- `ios-ci.yml`：每次 push/PR —— 模拟器 Debug 构建 + 单元测试、Clang 静态分析（Xcode Analyze）、Release 真机构建（不签名），上传 `.xcresult`。
- `swiftlint.yml`：SwiftLint（Linux 容器，成本低）。
- `codeql.yml`：Swift CodeQL 安全扫描（每周 + PR）。
- `dependabot.yml`：自动升级 Actions 版本。
- 单元测试覆盖纯逻辑：防篡改到期判断、周奇偶、窗口布局、命名解析、贝叶斯模型、老虎机、提醒时刻跨午夜换算。

## Options Considered

### 关于"AI"

#### Option A：保持频率直方图，只调参数
| 维度 | 评估 |
|---|---|
| 复杂度 | 低 |
| 成本 | 无 |
| 效果 | 不区分星期、不遗忘、无置信度 |
| 可解释性 | 高 |

**Pros:** 零风险。**Cons:** 正是用户不满意的现状。

#### Option B：分层贝叶斯 + Thompson Sampling（端侧在线学习）✅
| 维度 | 评估 |
|---|---|
| 复杂度 | 中（约 300 行纯 Swift，无依赖） |
| 成本 | 无，全在端侧 |
| 效果 | 按星期个性化、自动适应习惯变化、从用户反馈学习提醒时机 |
| 可解释性 | 高：每个时段都有"概率 + 置信度"，可直接展示 |

**Pros:** 在 Apple 给的信号下是统计上正确的做法；能跑在 6MB 扩展里；可单元测试。**Cons:** 不是"深度学习"——但数据量（每天几个阈值事件）也撑不起深度模型。

#### Option C：Core ML 训练模型
**Cons:** 没有训练数据（用量被沙盒化），没法训练；端侧个性化训练 (`MLUpdateTask`) 对这么少的标量信号是杀鸡用牛刀。否决。

#### Option D：云端大模型
**Cons:** 看不到用量数据；违背隐私承诺；增加审核风险和成本。否决。

#### Option E：Apple Foundation Models（端侧 LLM）✅ 作为 B 的补充
**Pros:** 端侧、免费、隐私安全；能把统计结果说成人话。**Cons:** 仅 iOS 26 + Apple Intelligence 设备；不能做预测本身（它也看不到用量）。所以只做"教练/文案"层，可选。

### 关于防绕过

| 方案 | 评估 |
|---|---|
| 单调时钟 + 开机 ID（选中） | 挡住"改系统时间"；重启 + 改时间仍可绕过（需要两步刻意操作，已记录） |
| 只信墙钟（现状） | 改时间即可解锁 |
| 联网校时 | 断网即失效，还要加隐私说明；收益不抵成本 |

## Trade-off Analysis

- **Fail-closed vs. fail-open**：所有新的不确定路径（续段失败、开机 ID 读不到）都选择"保持锁定"，最坏结果是锁比预期多留到下次打开 App；而旧代码的不确定路径全部是"提前解锁"。对一个以"NO ESCAPE"为卖点的产品，前者正确。
- **防卸载会挡住删除所有 App**：这是 `denyAppRemoval` 的系统语义，无法只保护自己。因此做成可关闭的开关（仅空闲时可关），并在 UI 中写清楚。
- **日程承诺锁降低了灵活性**：拦截中改不了日程。这正是用户要的"关不掉"。窗口外照常可改。
- **仍然无法防住的**：用户在系统设置里撤销 Screen Time 权限。`.individual` 授权下 Apple 不提供阻止手段。缓解：检测到撤销后首页红色警示；文档建议让朋友设置 Screen Time 密码。

## Consequences

- **更容易**：任何改动都有 CI 编译 + 测试兜底；锁的状态 App/扩展一致；AI 每个预测都有可展示的置信度。
- **更难**：日程拦截期间不能改；防卸载期间删不了任何 App。
- **需要回头看**：
  - `kern.bootsessionuuid` 在 iOS 沙盒内是否可读（读不到时自动退回墙钟，行为不劣于旧版）。
  - 监控扩展内调用 `DeviceActivityCenter.startMonitoring` 续段在真机上的可靠性（失败也是 fail-closed）。
  - 老虎机奖励信号较稀疏，如 4 周后提前量仍未收敛，考虑加入"锁是否完成"作为奖励。

## Action Items

1. [x] 锁记录迁移到 App Group，单调时钟到期判断，分段续锁
2. [x] 扩展 `intervalDidEnd` 查记录再清除，未到期续段
3. [x] 日程承诺锁（拦截中禁止关闭/编辑/删除）
4. [x] 防卸载开关（`denyAppRemoval`）
5. [x] 授权状态如实反映 + 健康检查
6. [x] 删除 SwiftData
7. [x] `HabitModel` 分层贝叶斯 + 按星期提醒 + Thompson Sampling 提前量
8. [x] Foundation Models 教练（iOS 26+，可选）
9. [x] GitHub Actions：构建/测试/分析/Release 构建、SwiftLint、CodeQL、Dependabot
10. [ ] 推送分支，让 CI 在 macOS runner 上首次编译（本次改动在 Windows 上编写，未经本地编译）
11. [ ] 真机验证清单：跨午夜锁、48h 锁、改系统时间、拦截中关日程、锁定中删 App、撤销 Screen Time 权限
12. [ ] 真机跑 2 周后检查模型：每个星期的高峰与提醒是否合理
