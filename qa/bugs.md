# Aural QA Bug Log

## QA-2026-07-08-001: `aural-validate` 后开源审计会被 Python 缓存生成物阻断

- 严重级别: Minor
- 优先级: P2
- 状态: Verified
- 影响范围: `swift run aural-validate`、`scripts/audit-open-source.sh`
- 环境: macOS，本地仓库根目录
- 复现步骤: 清理 `AuralASRWorker/__pycache__` 后运行 `swift run aural-validate`，再运行 `scripts/audit-open-source.sh`
- 实际结果: 修改前 worker stub 会生成 `AuralASRWorker/__pycache__`，审计失败并报告 generated files found
- 预期结果: 验证入口不应在源码目录留下 Python bytecode 缓存；审计可稳定通过
- 证据: `aural-validate` worker client 已注入 `PYTHONDONTWRITEBYTECODE=1`；复跑 `swift run aural-validate` 后没有生成 pycache，`scripts/audit-open-source.sh` 通过
- 回归建议: 按 CI 顺序运行 `swift run aural-validate`，再运行 `scripts/audit-open-source.sh`

## QA-2026-07-08-002: ITN 验证在缺少中文 FST 规则时无法完成日期和手机号归一化

- 严重级别: Minor
- 优先级: P3
- 状态: Deferred
- 影响范围: `scripts/validate-itn-postprocess.py`、打包后的 `custom_wetext_fsts`
- 环境: `.build/release/Aural.app/Contents/Resources/runtime/bin/python3`
- 复现步骤: 运行 `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py`
- 实际结果: 失败；当前 bundle 的 `custom_wetext_fsts` 目录只有 `.keep`，缺少 `zh/itn/tagger_no_standalone.fst`
- 预期结果: 若声明执行 ITN 验证，应存在所需 FST 并输出 `itn=ok`；若未打包 FST，应提前给出清晰的缺失规则文件错误
- 证据: 本轮命令确认 `custom_wetext_fsts` 下只有 `.keep`
- 最小复现: `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py`
- 回归建议: 使用带 `--itn-fst-source /path/to/custom-wetext-fsts` 的 bundle 重新运行该脚本，并补跑 `scripts/audit-open-source.sh`
- 发布判断: 不阻塞 0.1.0。当前版本接受 raw/基础文本 fallback；ITN 优化作为低优先级项目记录，暂不排期。

## QA-2026-07-08-003: Swift Package 缺少轻量测试入口

- 严重级别: Major
- 优先级: P1
- 状态: Verified
- 影响范围: Swift 快速验证入口
- 环境: Swift Package `AuralMacApp`
- 复现步骤: 修改前运行快速 Swift 测试入口
- 实际结果: 只有 `aural-validate` 这种大颗粒验证；当前本地 Swift 工具链缺少 `XCTest` 和 `Testing` 模块，不能直接落地 `swift test`
- 预期结果: 至少有一个快速、可重复、可定位的测试入口覆盖核心纯逻辑
- 证据: 已新增 `aural-test` executable 覆盖文件类型识别、导出渲染和 TaskStore 生命周期，并已纳入 CI
- 回归建议: 运行 `swift run aural-test`

## QA-2026-07-08-004: raw ASR 大段重复循环会生成不可接受 transcript

- 严重级别: Critical
- 优先级: P0
- 状态: Accepted for 0.1.0 RC
- 影响范围: `AuralASRWorker/worker_qwen_segmented_bundle.py`、`AuralASRWorker/worker_qwen_direct_bundle.py`、真实模型 smoke、ASR 质量回归
- 环境: Apple Silicon macOS，本地 Qwen3-ASR 4bit 模型，长口语音频 chunk
- 复现步骤: 使用已有 bad-case 回归集中 `asr_repetition_with_alignment_reject` 类 chunk 运行默认 4bit worker
- 实际结果: 旧策略下部分 chunk 会在 raw ASR 阶段进入 repetition loop，表现为单字、短词或短句大面积重复，可能打满 `max_tokens`
- 预期结果: 默认 4bit 策略不应输出 hard repetition；若模型仍进入异常循环，必须被 bad-case 回归捕获并阻塞发布
- 根因: Qwen3-ASR 长音频解码阶段 repetition loop，不是 UI、ITN、导出或 forced alignment 造成；公开摘要见 `docs/research/asr-repetition-root-cause-0.1.0.md`
- 当前修复: 默认 4bit ASR 首轮不传内部 `chunk_duration`，只使用 Aural 外层 60/90s chunking；首轮 neutral `repetition_penalty=1.0`。当 chunk 输出命中 hard repetition signal 时，自动用 `repetition_penalty=1.10`、`repetition_context_size=32` 重试该 chunk，并将 retry 触发和采纳结果写入 transcript metadata。
- 验证证据: 2026-07-08 固定 `repetition_penalty=1.10` 策略曾在 18 个 `asr_repetition_with_alignment_reject` bad-case 上回归 `bad=0`。2026-07-10 当前策略已通过 direct/segmented validation，覆盖首轮 `1.0`、异常重复触发 `1.10` retry、采纳非重复 retry 文本；当前 `.build/release/Aural.app` 的 direct worker smoke、app queue + alignment on、app queue + alignment off、坏音频失败路径均通过，metadata 写入 `chunk_duration_sec=null`、`repetition_penalty=1.0`、`retry_repetition_penalty=1.1`。历史 hard repetition case 未重新完整批量回放，作为 0.1.x 持续回归集继续维护。
- 最小复现: 使用 ignored `work/chunk-hallucination/` 中的 bad-case 回归资料，不将原始音频或 transcript 提交到仓库
- 回归建议: 运行 `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py`、`env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py`、已有 raw ASR bad-case 回归脚本、`scripts/smoke-direct-bundle-worker.sh` 和 `scripts/smoke-app-queue-bundle.sh`
- 发布判断: 已接受为 0.1.0 release candidate；若后续新增 hard repetition case，重新打开 P0 并补充到回归集。

## QA-2026-07-08-005: 播放中重命名中文输入被刷新打断且滚动卡顿

- 严重级别: Major
- 优先级: P1
- 状态: Verified for 0.1.0 RC
- 影响范围: `Sources/AuralUIPrototype/AuralUIPrototypeApp.swift`，任务列表 rename、播放进度刷新、任务列表/详情滚动
- 环境: macOS SwiftUI App，播放音频时，中文输入法重命名任务
- 复现步骤:
  1. 打开一个已有音频任务。
  2. 点击播放。
  3. 在左侧任务列表修改任务名字。
  4. 使用中文输入法输入。
  5. 同时尝试上下滑动任务列表或详情区域。
- 实际结果: 播放中中文输入 composition 像被刷新打断，输入不稳定或无法输入；播放时滚动明显卡顿。
- 预期结果: 播放进度更新不应重建 rename 输入控件；中文输入法 composition 应稳定；播放中滚动应接近暂停状态。
- 初步判断: 播放 `currentTime` 高频回传到父级详情视图，导致不相关区域随 0.25s playback tick 反复刷新；rename 控件和滚动容器受到影响。
- 当前修复: 将播放状态下沉到 `TaskPlaybackTranscriptSection`，避免 tick 重绘标题/重命名区域；`RenameCommitTextField` 在编辑中或中文输入法 marked text 存在时不再回写 `stringValue`；`TranscriptPreview` 缓存 transcript/alignment bundle，并减少非 active row 的时间更新；`reload()` 和 `AudioPlaybackViewModel.refresh()` 只在实际变化时发布。
- QA 复核: 子 agent 只读复核认为当前 diff 合理覆盖两个症状；残余风险集中在超长 transcript/alignment 的高亮计算、首次读取 transcript 失败后的缓存失败状态、以及真实 macOS 中文输入法 marked text 行为必须实机验证。
- 自动验证证据: `swift build`、`swift run aural-test`、`swift run aural-validate`、`scripts/audit-open-source.sh` 均通过；本地验证 DMG 已生成并通过 `hdiutil verify`。
- 工作流记录: `work/checkpoints/2026-07-08-playback-rename-scroll.md`
- 手工验证: 用户在 `Aural-0.1.0-local-verify-20260710-123709.dmg` 上反馈“基本功能没有问题”。
- 回归建议: 后续 0.1.x 继续覆盖播放中中文重命名、右侧标题重命名、任务列表滚动、详情转写滚动、seek/双击跳转/回到正在播放按钮，以及后台仍有任务运行时的中文重命名。
- 发布判断: 已接受为 0.1.0 release candidate。

## QA-2026-07-10-006: 重装后首次打开 Aural 意外退出，第二次打开正常

- 严重级别: Critical
- 优先级: P0
- 状态: Ready for Notarized Package Verification
- 影响范围: 首次启动、资源检查、Developer ID notarized DMG 安装后首次打开
- 环境: macOS 26.2，`/Applications/Aural.app`，notarized `Aural-0.1.0.dmg`
- 复现步骤:
  1. 使用 `Aural-0.1.0.dmg` 安装或覆盖安装到 Applications。
  2. 首次打开 Aural。
  3. 观察 macOS crash 弹窗。
  4. 再次打开 Aural。
- 实际结果: 首次打开出现 “Aural 意外退出”，重新打开后正常。
- 预期结果: 首次打开不应崩溃；若资源需要检查或下载，应稳定显示资源准备界面。
- 根因: `AuralAppModel.init()` 在 SwiftUI `StateObject` 安装期间同步调用 `refreshLocalResourceState()`，随后在主线程执行 `ModelResourcePreparer.probeRuntimeCompatibility()` 内的 `Process.waitUntilExit()`。首次启动时 AppKit/SwiftUI 启动通知重入，触发 AttributeGraph `AG::precondition_failure` 并 `SIGABRT`。
- 崩溃证据: `~/Library/Logs/DiagnosticReports/Aural-2026-07-10-104854.ips` 中 faulting thread 为 0，调用栈包含 `AG::precondition_failure`、`-[NSConcreteTask waitUntilExit]`、`ModelResourcePreparer.probeRuntimeCompatibility()`、`AuralAppModel.refreshLocalResourceState()`、`AuralAppModel.init()`。
- 当前修复: 资源状态刷新改为先显示 `.checking`，再通过后台 utility task 执行 runtime probe 和模型文件检查，完成后回主线程更新 `resourceStatus`；`prepareLocalResources()` 也避免在主线程同步执行 runtime probe。
- 自动验证证据: `swift build`、`swift run aural-test`、`swift run aural-validate`、packaged worker smoke、app queue smoke 通过；使用临时 `AURAL_DATA_ROOT` 运行 `.build/release/Aural.app/Contents/MacOS/Aural` 8 秒未崩溃，未生成新的 Aural `.ips`。
- 发布包: 最终正式 notarized DMG 已生成：`.build/release/Aural-0.1.0.dmg`，submission id `c4c8b838-e96a-4efe-ad32-71cfa96650ef`，Gatekeeper `accepted`。
- 手工验证: 用户在本地验证包上反馈“基本功能没有问题”。后续 RC 修复包用户反馈“目前没有发现其他问题”，同意开始制作 release 包并推进发布。
- 回归建议: 使用 notarized `Aural-0.1.0.dmg` 重新覆盖安装，首次打开应不再出现 crash 弹窗；然后确认资源检查/模型准备界面、第二次打开、已有模型缓存复用均正常。
- 发布判断: 不阻塞生成 0.1.0 release package；notarized 包交付后保留最终安装验证。

## QA-2026-07-10-007: 中文视频转写开头混入英文短句

- 严重级别: Critical
- 优先级: P0
- 状态: Verified for 0.1.0 RC
- 影响范围: balanced profile、中文视频/配乐/歌词类素材、`xianxia_story_cards.mp4`
- 环境: macOS，Aural 0.1.0 notarized app，Qwen3-ASR 1.7B 4bit balanced profile
- 复现步骤:
  1. 导入 `xianxia_story_cards.mp4`。
  2. 使用均衡型模型完成转写。
  3. 查看转写开头和后续歌词段落。
- 实际结果: 部分 run 在开头生成 `I've been watching you.` 或 `The.`，后续中文也有配乐/歌词场景下的措辞漂移。
- 预期结果: 中文素材不应出现明显无关英文短句；同时不能为了单一中文 case 直接牺牲 `language=auto` 的基础能力。
- 根因判断: 不是 UI、ITN、alignment 或 transcript 渲染问题；英文短句已经存在于 raw transcript。对同一 `source.m4a` 的矩阵验证显示，`language=auto` 下 `repetition_penalty=1.0/1.05/1.10` 都可能出现英文开头；强制 `language=zh` 可以消除英文开头，但该方案会改变产品默认语言行为，已被明确否决。进一步窗口矩阵显示：同一 0-60s/0-90s 输入在内部 `chunk_duration=30` 时稳定出现 `I've been watching you.`，不传内部 `chunk_duration` 时不出现；裁掉前 8.42s 后也不出现。因此当前主因更像是内部 30s 二次切分叠加开头音乐/弱人声触发语言漂移。
- 当前修复: 保持 `WorkerRequest.language=auto`；默认首轮不传内部 `chunk_duration`，首轮使用 neutral `repetition_penalty=1.0`；仅在 hard repetition signal 命中时用 `1.10/context=32` 重试，retry 也不默认改变内部 `chunk_duration`。
- 自动验证证据: `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py` 和 `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py` 已覆盖动态 retry 逻辑和“不传内部 chunk_duration”策略。窗口矩阵证明 `chunk_duration=30` 是该样例英文前缀的重要触发条件；当前源码 worker 对同一 `source.m4a` 输出 `/tmp/aural-no-internal-chunk-xianxia/transcript.json`，metadata 为 `chunk_duration_sec=null`、`retry_chunk_duration_sec=null`，首段不再出现 `I've been watching you.`。
- 手工验证: 用户在 `Aural-0.1.0-local-verify-20260710-123709.dmg` 上反馈“基本功能没有问题”。
- 回归建议: 0.1.x 持续收集中文配乐/弱人声开头样例，避免未来重新引入内部短 `chunk_duration` 默认值。
- 发布判断: 已接受为 0.1.0 release candidate。

## QA-2026-07-10-008: MacBook Air 转写长时间停留在 0%

- 严重级别: Critical
- 优先级: P0
- 状态: Verified for 0.1.0 RC
- 影响范围: 任务队列、worker 进度、App 退出清理、模型设置并发、重跑任务工作目录
- 环境: MacBook Air，macOS 15.6.1，Apple Silicon，16GB 内存，notarized `Aural-0.1.0.dmg`
- 复现步骤:
  1. 在 MacBook Air 上连续启动两个相同音频任务。
  2. 观察第二个任务显示 `转写中 0%` 很久。
  3. 重启 App 或手动检查 `ps axu | grep Aural`。
- 实际结果: 任务并非完全死锁，但在模型加载和首个 chunk 推理阶段长期显示 0%；历史异常退出后可能留下 worker/helper 进程；恢复任务目录中存在旧 `audio-segments/chunks` 残留，污染下一轮诊断。
- 预期结果: App 退出或重启不应留下 Aural worker/preparer；每次任务启动前应清理旧生成物；首段推理前应展示可理解的阶段，不应长期看起来卡死；正在转写时不应并发启动模型准备。
- 现场证据: 用户提供 MacBook Air debug zip。快照中只有一个活跃 `worker_qwen_segmented_bundle.py`，CPU 55%、RSS 约 1GB；`C2C30BF9-D1A9-4FD3-B7C2-FD670F5345A5` 运行 2m37s 仍 `progressFraction=0`，目录有本轮 `normalized.wav` 和 `chunk-0001.wav`，但 `chunk-0002.wav` 时间戳早于本轮 `startedAt`，说明旧工作目录残留参与了现场。
- 根因判断: 不是模型缓存缺失，也不是多个 worker 当前同时运行。主要是 worker 早期阶段粒度太粗：音频准备、模型加载和首个 chunk 推理前没有可见非零进度；此外 App 缺少统一子进程生命周期管理，恢复/重跑任务没有清理 `audio-segments`，设置页允许转写中触发资源准备。
- 当前修复:
  - 新增 `AuralChildProcessRegistry`，worker/preparer 启动后登记；取消、超时、App 退出时杀进程树；App 启动时清理旧 Aural helper。
  - 每次 pending 任务真正启动前清理 `transcript.json`、`alignment.json`、`error.log`、`worker-events.jsonl` 和 `audio-segments`，只保留 source 音频。
  - worker 增加 `preparing`、`normalizing`、`reading_audio`、`segmenting`、`loading`、`transcribing` 阶段事件；Swift 队列持久化 `progressStage`，并为早期阶段设置保底进度，避免 UI 长期 0%。
  - `ASRWorkerClient` 将 worker stdout 事件写入任务目录 `worker-events.jsonl`，便于后续诊断。
  - 正在转写时禁止保存并准备模型资源；队列启动前重新检查模型资源真实可用。
- 自动验证证据: `swift build`、`swift run aural-test`、`swift run aural-validate`、`env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py` 通过。
- 手工验证: 用户在 `Aural-0.1.0-dev-ui-hang-20260710-163545.dmg` 上反馈“目前没有发现其他问题”，同意开始制作 release 包并推进发布。
- 回归建议: 在后续 0.1.x 继续覆盖 MacBook Air 双任务、退出后残留进程、重试任务目录清理和早期阶段进度显示。
- 发布判断: 已接受为 0.1.0 release candidate。

## QA-2026-07-10-009: 导入任务后 App 鼠标转圈且无响应

- 严重级别: Critical
- 优先级: P0
- 状态: Verified for 0.1.0 RC
- 影响范围: App 启动、残留 worker 清理、批量任务导入后的主线程响应
- 环境: macOS，本地安装开发验证包后批量拖入多个 wav 任务
- 复现步骤:
  1. 安装 `Aural-0.1.0-dev-zero-progress-20260710-160750.dmg`。
  2. 批量拖入多个 wav 任务。
  3. 等待任务开始执行或部分完成。
  4. 观察鼠标持续转圈，App 窗口无响应。
- 实际结果: worker 任务可以继续完成，但 App 主线程卡住，界面无法响应。
- 预期结果: 启动残留进程清理不应阻塞 AppKit/SwiftUI 主线程；导入和执行任务期间窗口应保持可操作。
- 现场证据: `sample` 采样显示主线程停在 `AuralAppDelegate.applicationDidFinishLaunching(_:) -> AuralChildProcessRegistry.terminateStaleAuralHelpers() -> staleAuralHelperProcessIDs() -> Process.waitUntilExit()`。
- 根因: `applicationDidFinishLaunching` 同步执行残留 Aural helper 清理；清理内部调用 `/bin/ps` 并 `waitUntilExit()`，导致启动通知和 UI 事件处理被阻塞。
- 当前修复: 启动残留 helper 清理改为后台 utility queue 执行；`ps` 快照改为读取 `pid/ppid/command`，并排除当前 App 进程的后代，避免异步清理和新启动 worker 之间发生竞态误杀。
- 手工验证: 用户在 `Aural-0.1.0-dev-ui-hang-20260710-163545.dmg` 上反馈“目前没有发现其他问题”，同意开始制作 release 包并推进发布。
- 回归建议: 后续 0.1.x 继续覆盖批量拖入 5 个以上 wav、任务执行期间窗口响应、退出后 worker/preparer 清理，以及 MainActor 同步 IO 卡顿优化。
- 发布判断: 已接受为 0.1.0 release candidate。
