# Project Takeover Report

更新时间：2026-07-08

## 当前理解

Aural 是一款本地优先的 macOS 音频/视频转写 App。0.1.0 的核心目标是让 Apple Silicon Mac 用户完成“导入文件 -> 本地转写 -> 播放核对 -> 导出结果”的主链路，同时保持无账号、无遥测、无云端转写。

当前项目已经接近开源发布形态：产品定位、PRD、架构、worker 协议、transcript schema、打包、发布、QA 和真实模型 smoke 文档都已有基础。后续重点不是扩展功能，而是发布前收敛、验证证据补齐和 release 风险决策。

本报告基于 Phase 0/1 的只读接手 research。用户随后明确旧 `v0.1.0` tag 可忽略，后续目标是从当前工作区收敛新的 v0.1.0 初版发布候选。

## 项目运行方式

接手后执行协议：

- Project Lead 是唯一对话入口，但不能在主线程承载完整流程上下文。
- 每个会改变产品范围、代码、文档、QA 状态、release 状态或项目决策的流程，都必须先做角色拆分并使用子 agent 隔离上下文。
- 默认角色流为 PM/UX -> Architect -> Dev -> QA -> Reviewer/Release，按任务裁剪时必须记录原因。
- 每一步必须有输入文档、输出文档、owner、验收标准和停止条件。
- 每轮继续前必须先读 `AGENTS.md`、`work/status.md`、`work/decisions.md`、`work/plan.md` 和 `docs/engineering/project_workflow_principles.md`。
- 具体原则见 `docs/engineering/project_workflow_principles.md`。

默认快速验证：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

本机初始审计曾因 `Sources/.DS_Store` 失败；该生成物已清理，`scripts/audit-open-source.sh` 已通过。

开发 App 构建：

```bash
scripts/build-local-app.sh
```

轻量 release App 构建：

```bash
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
AURAL_RUNTIME_MIN_MACOS=14.0 scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
```

真实模型 smoke 需要完整 runtime 和模型缓存，不属于默认快速基线。

## 核心模块

| 模块 | 职责 |
| --- | --- |
| `Sources/AuralCore/Models` | 任务、状态、worker 协议、transcript、alignment 数据结构 |
| `Sources/AuralCore/Stores` | 任务和 transcript 本地持久化 |
| `Sources/AuralCore/Services` | 队列、worker client、runtime/model path、模型资源准备、导入、导出、播放辅助 |
| `Sources/AuralUIPrototype` | SwiftUI App 主界面和状态模型 |
| `AuralASRWorker` | Python worker、模型下载、ITN、alignment |
| `scripts` | 构建、审计、打包、smoke、发布 |
| `docs` | 产品、架构、协议、schema、发布文档 |
| `qa` | 测试覆盖、回归清单、bug log、真实模型 smoke 记录 |

## 数据流和请求流

1. 启动时 `AuralAppModel` 初始化 `TaskStore`、`TranscriptionQueue` 和 runtime/model 状态。
2. App 修复 interrupted running 任务、无效 done 任务和可恢复 failed 任务。
3. 资源 gate 检查 macOS、Apple Silicon、runtime 和模型缓存。
4. 缺资源时 `ModelResourcePreparer` 启动 `model_resource_prepare.py`，优先从 ModelScope 下载，失败后使用 Hugging Face fallback。
5. 导入音频时复制到任务目录；导入视频时通过 AVFoundation 抽取 app-owned audio。
6. 队列串行处理 pending 任务。
7. `ASRWorkerClient` 启动 Python worker，stdin 写 `WorkerRequest`，stdout 读 progress/completed/failed。
8. worker 写 `transcript.json`，alignment 成功时写 `alignment.json`。
9. Swift 校验 transcript 文件存在、可读且非空后，任务进入 `done`。
10. UI 读取 transcript/alignment 支撑播放、高亮、seek、搜索和导出。

## 测试与验证方式

当前快速基线：

- `swift build`
- `swift run aural-test`
- `swift run aural-validate`
- `scripts/audit-open-source.sh`

条件验证：

- `scripts/validate-direct-segments.py`
- `scripts/validate-segmented-worker.py`
- `scripts/validate-itn-postprocess.py`

发布前验证：

- runtime compatibility audit
- codesign verify
- direct worker smoke
- app queue + segmented worker smoke
- agreed manual QA paths

当前测试薄弱点：

- 无标准 `swift test` target。
- UI 层暂无自动化或截图回归。
- 视频抽音频、英文短音频、aligner 缺失/损坏 fallback 未完成真实模型 smoke。
- ITN FST 策略未定。

## 当前风险

1. P0/P1：旧 `v0.1.0` tag 不再作为发布约束；仍需要在发布前形成新的 release commit/tag。
2. P1：Swift 模型完整性 gate 已与 Python preparer 的 required files 对齐；仍需要真实缓存/首次下载验证。
3. P1：首次模型下载链路没有在干净缓存上形成证据。
4. P1：中文 ITN FST 是否阻塞 0.1.0 未决。
5. P1：真实模型 smoke 缺视频、英文、aligner fallback。
6. P1/P2：第三方许可清单和 release 资产需确认。
7. P0：公开 v0.1.0 DMG 必须完成 Developer ID signing、Apple notarization、staple 和 Gatekeeper 验证。
8. P2：UI 主文件过大，后续维护成本偏高。

## 不确定点

- 中文 ITN FST 是否必须进入 release。
- Developer ID 证书和 notarytool keychain profile 是否已在 release 机器就绪。
- 真实模型 smoke 的最低发布样例范围。
- raw ASR bad-case 回归和真实模型 smoke 是否已通过。
- 发布前是否必须补完整 Python/runtime/model license inventory。

## 建议的首批任务

1. 明确 ITN FST 策略，并决定 `validate-itn-postprocess.py` 是否阻塞发布。
2. 在干净模型缓存上验证首次下载、fallback、partial retry 和缓存复用。
3. 补真实模型 smoke：视频抽音频、英文短音频、aligner 缺失/损坏 fallback。
4. 构建轻量 release app，运行 runtime compatibility audit、Developer ID codesign、notarization 和 Gatekeeper 验证。
5. 梳理 dirty worktree，形成 release commit，再处理 tag 和 DMG。

## 需要用户确认的问题

1. 是否确认 `aural-open-source` 是后续公开发布唯一主线。
2. 是否确认 0.1.0 默认使用轻量 DMG + 首次下载模型。
3. 是否确认默认配置为“平衡 + 字幕时间戳对齐”。
4. 中文 ITN FST 是否必须进入 0.1.0。
5. Developer ID 证书和 notarytool keychain profile 是否已在 release 机器就绪。
6. 真实模型 smoke 最低发布范围是否必须覆盖中文、英文、视频、aligner fallback、长音频。
7. raw ASR bad-case 回归和真实模型 smoke 是否已通过。
8. 发布前是否必须补完整第三方许可清单。
