# Aural 0.1.0 PRD

更新时间：2026-07-08

## 1. 背景

Aural 0.1.0 的目标是发布一款本地优先的 macOS 音频/视频转写 App。它面向不希望把私人音视频上传到云端、但需要把录音、访谈、课程、播客或视频素材转成文字的个人用户。

当前代码已经具备完整主链路：资源准备、导入、队列、本地 worker 转写、播放核对、导出和删除。0.1.0 的产品重点不是扩展更多智能功能，而是把这条主链路收敛到可安装、可解释、可验证、可开源发布的状态。

## 2. 产品目标

0.1.0 必须达成：

- 用户可以在 Apple Silicon Mac 上安装并启动 Aural。
- 用户可以在首次启动时准备本地转写资源。
- 用户可以导入音频或视频，并由 App 创建本地任务队列。
- 用户可以在本机完成转写，不上传音视频和转写文本。
- 用户可以播放音频、核对转写、定位文本。
- 用户可以导出 SRT、纯文本和带分段时间文本。
- 用户可以停止、重试、重命名、搜索和删除任务。
- 用户删除任务时，Aural 只删除 App 内副本和生成物，不删除原始文件。

0.1.0 不追求：

- 覆盖所有 Mac 硬件。
- 解决所有 ASR 质量问题。
- 做实时字幕、会议助手、总结、说话人分离或云端协作。
- 把模型、runtime 和技术参数暴露给普通用户。

## 3. 目标用户

### 主要用户

- 有本地隐私诉求的个人用户。
- 需要整理访谈录音、课程录音、播客素材、公开视频素材的人。
- 能接受首次模型下载耗时，以换取后续本地离线转写体验的人。

### 非目标用户

- 需要实时会议字幕的人。
- 需要多人说话人分离、会议纪要和行动项自动生成的人。
- 使用 Intel Mac 或低于 macOS 14 的用户。
- 需要企业级团队协作、账号、权限、计费或云端管理的人。

## 4. 核心使用场景

### 场景 A：首次使用

用户安装 Aural 后打开 App。Aural 检查当前设备和本地模型资源。如果设备不支持，直接给出不可继续的说明。如果资源缺失，用户选择本地转写模式和是否启用字幕时间戳对齐，然后开始准备资源。资源准备完成后进入主界面。

验收重点：

- 不支持设备必须在下载前拦截。
- 资源缺失时不能进入导入和转写主流程。
- 下载失败后可重试。
- 已下载完整资源后再次启动应直接复用。

### 场景 B：导入并转写文件

用户拖入或选择音频/视频文件。Aural 创建本地任务，复制音频或从视频提取音频，然后按队列顺序转写。队列默认一次处理一个任务。

验收重点：

- 支持格式可以创建任务。
- 不支持格式不会创建任务。
- 视频任务只保留 App 内音频副本。
- 多任务按队列顺序处理。
- App 退出后 running 任务不会永久停留在转写中。

### 场景 C：播放核对转写

转写完成后，用户在 App 内播放音频，并阅读对应转写段落。用户可以拖动进度、跳转、跟随播放位置。存在 `alignment.json` 时，Aural 优先用更细时间信息改善高亮和定位；不存在时回退到段落时间。

验收重点：

- 没有 alignment sidecar 时仍可阅读、播放和导出。
- seek 后能定位到合理文本区域。
- 播放过程中高亮不应严重偏离音频。

### 场景 D：导出结果

用户选择已完成任务，导出 SRT、纯文本或带分段时间文本。多个任务导出时，Aural 为每个任务生成独立文件并避免覆盖冲突。

验收重点：

- 导出内容使用用户可读的 normalized text。
- SRT 时间格式有效。
- 缺失或异常 end time 时有兜底。
- 空转写不能导出误导性成功结果。

### 场景 E：管理任务

用户可以搜索、重命名、停止、恢复、失败后重试或删除任务。删除任务只影响 Aural 内部副本和生成文件。

验收重点：

- 重命名不能为空。
- 停止 pending/running 任务后进入已停止状态。
- 重试失败任务会清理旧 transcript、alignment 和 error log。
- 删除任务不影响用户原始文件。

## 5. 功能需求

### R1：本地资源准备

优先级：P0

需求：

- Aural 启动时检查 macOS 版本、CPU 架构、MLX runtime 和模型资源完整性。
- 不满足 macOS 14 或 Apple Silicon 条件时，展示不可继续提示。
- 缺少模型资源时展示准备页。
- 用户可以选择极速、平衡、精准三档 ASR 模式。
- 默认推荐平衡模式。
- 精准模式仅在 16GB 及以上内存设备上可用或生效。
- 用户可以选择是否启用字幕时间戳对齐。
- 下载优先使用 ModelScope，失败后 fallback 到 Hugging Face。
- 下载完成后写入完整性标记，后续升级复用本地缓存。

验收标准：

- 干净模型目录下，App 会阻止导入并进入资源准备。
- 已有完整模型目录下，App 不重复下载。
- 资源准备失败不会破坏已下载部分。
- 缺失 aligner 且用户关闭时间戳对齐时，不应阻塞转写。

### R2：文件导入

优先级：P0

需求：

- 支持音频格式：`mp3`、`m4a`、`wav`、`aac`、`flac`。
- 支持视频格式：`mp4`、`mov`、`m4v`。
- 音频文件复制到任务目录。
- 视频文件提取音频副本，原始视频不进入 Aural 数据目录。
- 不支持格式不能创建任务。

验收标准：

- 每个支持格式至少能创建任务。
- 不支持格式不会进入队列。
- 视频无音轨时返回失败并清理临时任务目录。

### R3：任务队列

优先级：P0

需求：

- 默认串行处理，一次只运行一个转写任务。
- 新任务默认 pending。
- 运行时进入 running。
- 完成后进入 done。
- 用户停止后进入 paused。
- 失败后进入 failed。
- App 启动时修复 interrupted running 任务。

验收标准：

- 多个 pending 任务按确定顺序处理。
- worker failed event 会持久化 failed 状态。
- worker timeout、非零退出、缺 terminal event 会进入失败路径。
- completed event 指向的 transcript 缺失、不可读或为空时，任务必须失败。

### R4：本地转写 worker

优先级：P0

需求：

- Swift App 通过 JSONL stdin/stdout 协议调用 Python worker。
- stdout 只传结构化事件。
- stderr 作为技术日志保存。
- 默认 worker 为 segmented Qwen worker。
- worker 输出 `transcript.json`。
- alignment 启用且成功时输出 `alignment.json`。
- ITN 和 alignment 失败不应掩盖原始转写结果。

验收标准：

- 成功任务必须生成可读且非空的 `transcript.json`。
- alignment 失败时，如果转写文本有效，任务仍可完成并记录 fallback。
- worker 技术错误应写入本地 `error.log`。

### R5：播放核对

优先级：P1

需求：

- 已完成任务可播放 App 内音频副本。
- UI 展示 transcript segments。
- 支持拖动进度、跳转、跟随播放位置和段落高亮。
- 有 alignment 时优先使用细粒度时间；无 alignment 时回退段落时间。

验收标准：

- 已完成任务能正常加载播放。
- seek 后预览和当前位置文本合理。
- 缺少 alignment 不影响基本播放和阅读。

### R6：导出

优先级：P0

需求：

- 支持导出 SRT。
- 支持导出纯文本 TXT。
- 支持导出带分段时间 TXT。
- 单任务导出可选择目标文件。
- 多任务导出可选择目录，并自动避免文件名冲突。

验收标准：

- SRT cue 编号连续，时间格式合法。
- 纯文本不包含多余空白。
- 带时间文本包含每段起止时间。
- 缺失 end time 时使用下一段起点、音频时长或最小兜底时长。

### R7：任务管理

优先级：P1

需求：

- 支持任务搜索。
- 支持任务重命名。
- 支持停止 pending/running 任务。
- 支持恢复 paused 任务。
- 支持 failed 任务重试。
- 支持删除任务。

验收标准：

- 搜索按文件名过滤。
- 空文件名不会覆盖原名。
- 重试会清理旧生成物。
- 删除任务会移除任务目录，但不删除用户原始导入文件。

### R8：隐私与本地数据

优先级：P0

需求：

- 0.1.0 不上传用户音视频和转写文本。
- 不要求账号。
- 不内置遥测。
- 用户任务和模型缓存默认保存在用户本机 Application Support 目录。
- 发布仓库不得包含用户媒体、生成 transcript、模型权重、runtime、凭据和私有路径。

验收标准：

- 公开审计脚本通过。
- 隐私文档与实际行为一致。
- 删除任务行为与隐私文档一致。

## 6. 非功能需求

### 兼容性

- 0.1.0 支持 Apple Silicon Mac。
- 0.1.0 要求 macOS 14 或更新版本。
- Intel Mac 和 CPU-only 后端不进入 0.1.0。
- 发布包必须避免打入高于目标系统版本的 runtime wheel 或二进制。

### 稳定性

- worker 超时、异常退出、缺事件和输出异常不能让任务永久卡死。
- App 重启后应能恢复可处理任务状态。
- 失败任务必须保留足够本地日志供开发排查。

### 可维护性

- worker 协议、transcript schema、打包方式和 QA 门槛变更时必须更新文档。
- 大模型、runtime、DMG、用户数据和生成物不得进入源码仓库。
- Release 前必须跑开源审计。

## 7. 0.1.0 不做范围

- 实时麦克风转写。
- 云端 ASR。
- 说话人分离。
- 摘要、纪要、行动项和 LLM 后处理。
- 视频 OCR 上下文增强。
- Intel Mac 支持。
- CPU-only 后端。
- 多模型专业参数面板。
- 团队协作、账号、同步、权限和计费。

## 8. 发布验收门槛

### 自动化门槛

发布前必须通过：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

轻量扩展验证：

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py
```

发布包验证：

```bash
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
AURAL_RUNTIME_MIN_MACOS=14.0 \
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
AURAL_RUNTIME_MIN_MACOS=14.0 scripts/audit-runtime-compatibility.sh .build/release/Aural.app
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
spctl --assess --type execute --verbose=4 .build/release/Aural.app
scripts/package-local-dmg.sh
scripts/notarize-release-dmg.sh .build/release/Aural-0.1.0-<timestamp>.dmg
```

### 手工门槛

至少覆盖：

- 干净模型缓存首次启动。
- 已有完整模型缓存启动。
- 模型下载失败后重试。
- 音频导入、视频导入、不支持格式。
- 单任务转写和多任务队列。
- running 任务停止与恢复。
- failed 任务重试。
- 播放、seek、跟随播放位置。
- SRT、纯文本、带分段时间导出。
- 删除任务并确认原始文件仍在。

## 9. 当前风险

### RISK-1：ITN FST 资源策略未完全闭环

影响：中文日期、手机号、英文缩写等归一化能力和验证脚本可能与 release 包实际资源不一致。

建议：产品确认 ITN 是否为 0.1.0 发布必备。如果必备，开发补齐 `custom_wetext_fsts` 并让 `validate-itn-postprocess.py` 通过；如果非必备，文档和 QA 口径必须声明 fallback 行为。

### RISK-2：真实模型 smoke test 仍需要明确样例和 skip 规则

影响：快速 CI 能证明核心逻辑，但不能完全证明发布包在真实 ASR 链路上可用。

建议：建立最小真实模型 smoke test 样例，覆盖音频、视频抽音频、alignment 开启/关闭和失败 fallback。

### RISK-3：Developer ID signing / notarization 未完成会阻塞公开发布

影响：Gatekeeper 会造成安装阻力；公开 release 不应要求普通用户绕过无法验证开发者提示。

建议：公开 v0.1.0 DMG 必须 Developer ID signed、提交 Apple notarization、staple 并通过 Gatekeeper 验证。ad-hoc signed 只作为本地开发包或内部临时验证包。

### RISK-4：ASR 重复、幻听和时间戳偏移

影响：某些真实音频可能生成用户不可接受结果。遗留 raw ASR 大段重复问题已定位为 Qwen3-ASR 长音频解码 repetition loop，不是 UI、ITN、导出或 alignment 生成。

建议：严重重复、明显幻听、整段漏转、任务成功但 transcript 无有效文本属于 P0 blocker。当前已保留 raw ASR 根因文档、默认 4bit 解码修复和 18-case bad-case/真实模型回归证据；后续新增 hard repetition case 继续阻塞发布候选。

## 10. 需要产品经理确认

1. 是否正式以 `aural-open-source` 作为唯一发布主线。
2. 0.1.0 是否只发布轻量 DMG，不发布完整离线模型包。
3. 默认配置是否保持“平衡 + 字幕时间戳对齐”。
4. ITN FST 是否是 0.1.0 必备资源。
5. Developer ID 证书和 notarytool keychain profile 是否已在 release 机器就绪。
6. 真实模型 smoke test 的最小样例集合。
7. raw ASR bad-case 回归和真实模型 smoke 是否已通过。
8. README 是否需要在 0.1.0 前补完整英文版。

## 11. 开发交付要求

开发提交与 0.1.0 相关改动时，应说明：

- 影响的需求编号。
- 改动范围。
- 是否影响 worker 协议、transcript schema、模型资源、打包或本地存储。
- 自测命令和结果。
- 建议 QA 回归范围。
- 已知风险和降级行为。

## 12. QA 验收要求

QA 验收 0.1.0 时，应至少输出：

- 自动化命令结果。
- 手工主链路结果。
- 真实模型 smoke test 结果或跳过原因。
- 未解决 Bug 列表及优先级。
- 发布阻塞判断。
- 需要产品经理决策的问题。
