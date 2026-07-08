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

- 严重级别: Major
- 优先级: P1
- 状态: New
- 影响范围: `scripts/validate-itn-postprocess.py`、打包后的 `custom_wetext_fsts`
- 环境: `.build/release/Aural.app/Contents/Resources/runtime/bin/python3`
- 复现步骤: 运行 `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py`
- 实际结果: 失败；当前 bundle 的 `custom_wetext_fsts` 目录只有 `.keep`，缺少 `zh/itn/tagger_no_standalone.fst`
- 预期结果: 若声明执行 ITN 验证，应存在所需 FST 并输出 `itn=ok`；若未打包 FST，应提前给出清晰的缺失规则文件错误
- 证据: 本轮命令确认 `custom_wetext_fsts` 下只有 `.keep`
- 最小复现: `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py`
- 回归建议: 使用带 `--itn-fst-source /path/to/custom-wetext-fsts` 的 bundle 重新运行该脚本，并补跑 `scripts/audit-open-source.sh`

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
- 状态: Verified
- 影响范围: `AuralASRWorker/worker_qwen_segmented_bundle.py`、`AuralASRWorker/worker_qwen_direct_bundle.py`、真实模型 smoke、ASR 质量回归
- 环境: Apple Silicon macOS，本地 Qwen3-ASR 4bit 模型，长口语音频 chunk
- 复现步骤: 使用已有 bad-case 回归集中 `asr_repetition_with_alignment_reject` 类 chunk 运行默认 4bit worker
- 实际结果: 旧策略下部分 chunk 会在 raw ASR 阶段进入 repetition loop，表现为单字、短词或短句大面积重复，可能打满 `max_tokens`
- 预期结果: 默认 4bit 策略不应输出 hard repetition；若模型仍进入异常循环，必须被 bad-case 回归捕获并阻塞发布
- 根因: Qwen3-ASR 长音频解码阶段 repetition loop，不是 UI、ITN、导出或 forced alignment 造成；公开摘要见 `docs/research/asr-repetition-root-cause-0.1.0.md`
- 当前修复: 默认 4bit ASR 生成使用 30s generate window、`repetition_penalty=1.10`、`repetition_context_size=32`；参数写入 transcript metadata；direct/segmented validation 覆盖参数传递
- 验证证据: `work/chunk-hallucination/results/v0_1_0_default_4bit.md` 记录 18 个 `asr_repetition_with_alignment_reject` bad-case 在当前默认策略下 `bad=0`、`bad_rate=0.0%`、最大重复覆盖率 0.0849；最新 `scripts/smoke-direct-bundle-worker.sh` 和 `scripts/smoke-app-queue-bundle.sh` 通过，transcript metadata 写入 `chunk_duration_sec=30.0`、`repetition_penalty=1.1`、`repetition_context_size=32`
- 最小复现: 使用 ignored `work/chunk-hallucination/` 中的 bad-case 回归资料，不将原始音频或 transcript 提交到仓库
- 回归建议: 运行 `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py`、`env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py`、已有 raw ASR bad-case 回归脚本、`scripts/smoke-direct-bundle-worker.sh` 和 `scripts/smoke-app-queue-bundle.sh`
- 发布判断: 当前 blocker 已按默认 4bit 策略验证关闭；后续若新增 hard repetition case，重新打开 P0

## QA-2026-07-08-005: 播放中重命名中文输入被刷新打断且滚动卡顿

- 严重级别: Major
- 优先级: P1
- 状态: Ready for Manual Verification
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
- 回归建议: 手工验证播放中中文重命名、右侧标题重命名、任务列表滚动、详情转写滚动、seek/双击跳转/回到正在播放按钮，以及后台仍有任务运行时的中文重命名。
- 发布判断: 若播放中无法稳定重命名或滚动明显卡顿，阻塞 v0.1.0 用户体验验收。
