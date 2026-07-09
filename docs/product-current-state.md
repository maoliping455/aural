# Aural 产品现状与 0.1.0 交付边界

更新时间：2026-07-08

本文档用于产品经理、开发和 QA 快速对齐 Aural 当前代码与文档状态。它不替代架构、协议、打包和 QA 文档；它负责把这些材料收敛成产品范围、交付标准、优先级和待确认问题。

## 当前结论

Aural 当前已经不只是技术原型，而是一个接近 0.1.0 开源发布形态的本地优先 macOS 转写 App。

当前主路径已经明确：

1. 首次启动检查本地运行环境和模型资源。
2. 用户选择本地转写模式，并准备缺失模型。
3. 导入音频或视频。
4. App 在本地创建任务、副本和队列。
5. Python worker 在本机完成 ASR、可选 ITN 和可选时间戳对齐。
6. 用户播放核对转写结果。
7. 用户导出 SRT、纯文本或带分段时间文本。

当前更需要补齐的是发布前的产品验收、真实模型 smoke test、ITN 资源策略、用户安装指引和风险决策，而不是继续扩展新功能。

## 权威代码与文档范围

当前应以 `aural-open-source` 作为公开发布和后续 PM/研发/QA 协作的主要工作目录。

已核对的主要材料：

- `README.md`：用户定位、当前能力、安装、兼容性、源码构建。
- `docs/architecture.md`：系统边界、运行时、模型资源、存储和数据流。
- `docs/packaging.md`：开发包、轻量 release 包、完整离线包和打包验证。
- `docs/release.md`：安装、模型缓存、兼容性和发布 checklist。
- `docs/worker-protocol.md`：Swift 与 Python worker 的 JSONL 协议。
- `docs/transcript-schema.md`：`transcript.json` 与 `alignment.json` schema。
- `qa/`：QA 章程、开发协作规约、覆盖地图、回归清单、Bug log 和进展。
- `Sources/AuralCore/`：任务存储、队列、worker client、导出、播放和模型资源准备。
- `Sources/AuralUIPrototype/`：当前 SwiftUI App 主界面。
- `AuralASRWorker/`：本地 ASR worker、ITN、alignment 和模型资源准备脚本。

`aural-mac-app` 更像早期或内部技术原型目录，文档和 release 边界比 `aural-open-source` 旧。除非另行指定，后续产品文档和发布工作不应再以它为主线。

## 产品定位

Aural 是一款本地优先的 macOS 音频/视频转写 App。

核心用户价值：

- 用户不需要上传私人音视频到云端。
- 用户不需要理解模型、参数和命令行。
- 用户可以批量导入文件，让 App 自动排队转写。
- 用户可以边听边核对转写结果。
- 用户可以把结果导出给字幕、笔记、AI 整理或后续工作流使用。

当前产品原则：

- 本地隐私优先：音视频、模型推理、转写结果默认留在本机。
- 极简主流程：默认配置应足够好，不在主界面暴露复杂模型参数。
- 状态清晰：任务状态保持少而明确。
- 可恢复：App 退出或 worker 异常后不应让任务永久卡死。
- 发布可维护：runtime、模型、用户任务、生成物和源码边界要清楚。

## 0.1.0 当前功能范围

### 首次资源准备

已实现或已有代码路径：

- 启动时检查 macOS 版本、Apple Silicon 架构和 MLX runtime。
- 不支持环境提前提示，不进入大模型下载。
- 模型缓存默认位于 `~/Library/Application Support/Aural/Models`。
- 支持三档本地转写模式：
  - 极速：`qwen3-asr-0.6b-4bit`
  - 平衡：`qwen3-asr-1.7b-4bit`
  - 精准：`qwen3-asr-1.7b-bf16`
- 默认推荐平衡模式。
- 精准模式要求 16GB 及以上内存。
- 字幕时间戳对齐可独立开启或关闭。
- 下载策略是 ModelScope 优先，Hugging Face 兜底。
- 下载完成写入 `.aural-complete.json`，后续启动和升级复用缓存。

产品验收重点：

- 缺资源时必须阻止导入和转写。
- 资源准备失败时必须支持重试，并复用已下载部分。
- 已存在完整资源时不应重复下载。
- Intel Mac 或低版本 macOS 不应先下载模型再失败。

### 导入与任务管理

已实现或已有代码路径：

- 支持音频：`mp3`、`m4a`、`wav`、`aac`、`flac`。
- 支持视频：`mp4`、`mov`、`m4v`。
- 音频导入后复制为 app-owned audio copy。
- 视频导入后用 AVFoundation 提取音频，App 不保留原始视频副本。
- 任务记录保存在本地任务目录和 `tasks.json`。
- 支持搜索、重命名、停止、恢复、失败后重试、删除。
- 删除任务会删除 App 内副本、转写结果、alignment sidecar 和日志，不删除用户原始文件。

产品验收重点：

- 不支持格式不能创建任务。
- 视频无音轨时应失败且不留下脏任务目录。
- 删除任务必须保护用户原始文件。
- App 重启后 running 任务应恢复到 pending 或可继续处理状态。

### 转写队列与 worker

已实现或已有代码路径：

- 默认串行队列，一次处理一个任务。
- Swift 通过 stdin/stdout JSONL 协议调用 Python worker。
- stdout 只传 JSON 事件；stderr 保留技术日志。
- 当前生产默认 worker 是 `worker_qwen_segmented_bundle.py`。
- worker 本地做音频规范化、分段、Qwen3-ASR 转写、可选 ITN、可选 forced alignment。
- `worker_qwen_direct_bundle.py` 保留为无分段 fallback 和 smoke-test 基线。
- worker 非零退出、超时、缺 terminal event、失败事件都会进入失败路径并写 `error.log`。
- 任务完成后会校验 `transcript.json` 存在、可读且有文本。

产品验收重点：

- 进度只能作为 best effort，不应取代最终 completed / failed 状态。
- worker 出错时，用户看到的状态应简洁；技术细节进入本地日志。
- 转写完成但 transcript 缺失、不可读或为空时，任务必须标记失败。
- 可选 alignment 失败不应让有文本的转写任务失败，应回退到估算时间戳。

### 播放核对与导出

已实现或已有代码路径：

- 转写完成后读取 `transcript.json` 展示段落。
- 有 `alignment.json` 时可使用字/词级时间改善高亮和定位。
- 缺少 alignment sidecar 时回退到段落时间。
- 支持播放、拖动进度、跳转、段落高亮、跟随播放位置。
- 支持导出：
  - SRT
  - 纯文本 TXT
  - 带分段时间 TXT

产品验收重点：

- 导出应使用用户可读的 normalized text。
- SRT 时间戳必须有兜底，不能因为某段 end time 缺失生成不可用字幕。
- 搜索、播放和导出都应能容忍缺失 alignment。

## 0.1.0 明确不做

以下能力不进入 0.1.0 默认范围：

- 实时麦克风转写。
- 云端转写。
- 账号体系、订阅、计费。
- 遥测或默认上传日志。
- 说话人分离。
- 内置总结、纪要、行动项或 LLM 后处理。
- Intel Mac 或 CPU-only 后端。
- 视频 OCR 上下文增强。
- 复杂模型参数暴露在主流程中。

这些可以进入后续路线图，但不能阻塞 0.1.0 核心本地转写发布，除非它们被重新定义为发布必需。

## 当前文档状态

已经比较完整的部分：

- 用户 README 已说明定位、能力、安装、兼容性和源码构建。
- 架构文档已说明 Swift App、Python worker、模型缓存和存储布局。
- worker 协议和 transcript schema 已能支撑开发/QA 对齐。
- 打包和 release 文档已覆盖轻量包、完整离线包、runtime 审计和发布 checklist。
- QA 文档已覆盖 QA/开发职责、回归清单、覆盖地图和已知 Bug。

本轮补齐的部分：

- 增加 PM 视角的当前状态文档，明确产品范围、开发/QA 验收口径、优先级和开放问题。

后续仍建议补齐：

- 普通用户安装与故障排查页，重点覆盖 Gatekeeper、模型下载失败、缓存清理、磁盘占用、卸载。
- 0.1.0 release checklist 的实际执行记录，每次发布保留命令结果摘要。
- 真实模型 smoke test 的 skip 规则、样例要求和失败记录模板。
- 开源 issue 模板，把 Bug、功能建议、兼容性问题和 ASR 质量问题分开。

## 当前 QA 状态

默认快速基线：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

轻量扩展回归：

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py
```

条件回归：

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py
```

当前已知条件：ITN 验证需要完整 `custom_wetext_fsts`。如果 release 声明包含中文 ITN 能力，必须补齐 FST 并让该验证通过；如果不作为 0.1.0 必备能力，需要在 release 文档和 QA 口径里明确降级行为。

## 优先级建议

### P0：发布阻塞

- 首次资源准备在干净机器上可完成，失败可重试，已完成资源可复用。
- 默认轻量 release 包在 macOS 14+ Apple Silicon 上可启动并进入主流程。
- 导入、转写、播放核对、导出、删除这条核心路径可完成。
- worker 失败、超时、缺 transcript 时不会造成任务永久卡死或数据损坏。
- 开源审计通过，不包含模型权重、runtime 目录、用户媒体、生成转写、私有路径或凭据。
- 公开 v0.1.0 DMG 完成 Developer ID signing、Apple notarization、staple 和 Gatekeeper 验证。
- raw ASR 大段重复问题已完成根因说明、默认解码策略修复和 bad-case/真实模型回归；后续新增 hard repetition case 继续按 P0 阻塞。

### P1：0.1.0 发布前强烈建议完成

- 明确 ITN FST 是否是 0.1.0 必备资源。
- 补一套真实模型 smoke test 的可复现执行记录。
- 完成首次安装、模型下载失败、断点续传、缓存复用的手工验收。
- 完成 SRT、TXT、带时间 TXT 的导出回归。
- 完成至少一轮普通用户 README 与 release 文档走读，确保公开包不再按未 notarized 口径说明。
- 确认 GitHub Release 默认使用轻量 DMG，不使用 split assets。

### P2：可进入 0.1.x 或后续版本

- 用户故障排查文档。
- issue 模板和贡献流程细化。
- 更完整的 UI 自动化或截图回归。
- 真实长音频、噪声、强口音和中英混合 ASR 质量回归集。
- 包体进一步瘦身。
- CPU-only / Intel Mac 后端调研。

### P3：暂不进入当前发布路径

- 视频 OCR 上下文增强。
- 内置总结或智能体 Skill。
- 云端 ASR 对照或多模型策略。
- 实时麦克风转写。
- 说话人分离。

## 需要产品经理确认的问题

1. `aural-open-source` 是否正式作为 Aural 后续公开发布的唯一主线目录。
2. 0.1.0 是否以“轻量 DMG + 首次下载模型”为唯一默认发布形态。
3. 默认配置是否保持“平衡 + 字幕时间戳对齐”。
4. ITN 中文 FST 是否必须进入 0.1.0 release；如果不是，是否接受 raw/基础归一化文本作为 0.1.0 结果。
5. Developer ID 证书和 notarytool keychain profile 是否已在 release 机器就绪。
6. 真实模型 smoke test 需要覆盖哪些样例：中文、英文、中英混合、长音频、视频抽音频、低音质素材。
7. raw ASR bad-case 回归和真实模型 smoke 是否已通过。
8. README 是否先保持中文优先，还是发布前需要完整英文版。

## 开发/QA 协作口径

项目执行必须遵守 `docs/engineering/project_workflow_principles.md`。这里的子 agent 是项目执行机制，不是 Aural App 的产品功能。

开发默认需要同步：

- 改动影响的用户路径。
- 是否改变 worker 协议、transcript schema、模型资源、打包或本地存储。
- 自测命令和结果。
- 已知风险和建议 QA 回归范围。

QA 默认需要同步：

- 复现步骤、环境、样例、实际结果和预期结果。
- 问题严重级别与优先级建议。
- 最小回归命令或手工路径。
- 是否影响发布阻塞。

产品经理默认负责：

- 决定是否进入当前版本。
- 确认默认配置和降级策略。
- 确认哪些失败必须阻塞发布。
- 维护 P0/P1/P2/P3 优先级。
- 把模糊反馈转成可开发、可测试、可验收的需求。

运营 / Aural Ops 默认负责：

- 收集和分流用户反馈、GitHub issue、安装问题、文档缺口和 adoption blocker。
- 宣传 Aural，维护适合的公开渠道、发布沟通、使用案例、known issues 和用户支持信息。
- 推动更多用户成功试用并持续使用 Aural，关注新用户 onboarding、安装成功率、首次转写体验和留存障碍。
- 维护运营型 backlog，并给出优先级、影响范围和传播/支持成本建议。
- 维护用户可发现的文档入口和支持路径，例如安装、故障排查、卸载、问题上报和反馈入口说明。
- 只提供证据、风险和建议；不直接决定产品范围、隐私策略、release blocker、notarization 策略或是否发布。

## 后续维护规则

当以下内容变化时，需要同步更新本文档或链接到更细文档：

- 0.1.0 范围变化。
- 默认模型、默认 alignment、ITN 策略变化。
- 支持格式、任务状态、导出格式变化。
- 发布包形态、安装流程、兼容性策略变化。
- QA 发布门槛或已知 P0/P1 风险变化。
