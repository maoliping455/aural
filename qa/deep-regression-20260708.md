# Aural QA 深度回归记录 2026-07-08

执行时间：2026-07-08 23:47:51 +0800
工作目录：`<repo>`
当前提交：`106a8d9`
机器：Apple Silicon，`arm64`
系统：macOS 26.2，Build 25C56
Swift：Apple Swift 6.3.3，Target `arm64-apple-macosx26.0`

## 范围与输入

本轮按 QA 深度回归子 agent 范围执行，只读取资料、运行测试，并只写入本文件。

已读取：

- `AGENTS.md`
- `qa/regression-checklist.md`
- `qa/real-model-smoke-0.1.0.md`
- `qa/progress.md`

工作树开始和结束时均存在他人改动，未回退、未覆盖、未修改这些文件：

- `AGENTS.md`
- `CONTRIBUTING.md`
- `README.md`
- `docs/README.md`
- `docs/engineering/project_workflow_principles.md`
- `docs/product-current-state.md`
- `docs/project-plan-0.1.0.md`
- `docs/development.md`

## QA 结论

自动化快速/发布前基础回归通过：`swift build`、`swift run aural-test`、`swift run aural-validate`、`scripts/audit-open-source.sh`、direct segments、segmented worker、runtime compatibility 均通过。

真实模型 direct worker smoke 通过，能使用包内 runtime 和本地模型生成非空 transcript。

真实模型 app queue smoke 的功能路径通过：正常音频转写完成，坏音频进入失败路径并生成 `error.log`。但脚本最终 `codesign --verify --deep --strict` 失败，且独立复验同样失败，因此当前 `.build/release/Aural.app` 不能作为 release app 放行。发布前需要重新生成/签名 release app，并复跑 app queue smoke 与 codesign。

ITN 条件回归失败原因明确：bundle 中缺少 `custom_wetext_fsts/zh/itn/tagger_no_standalone.fst`。后续 PM 已确认该项不阻塞 0.1.0，作为低优先级优化暂不排期；当前版本接受 raw/基础文本 fallback。

## 自动验证结果

| 命令 | 结果 | 退出码 | 证据/备注 |
| --- | --- | ---: | --- |
| `swift build` | Pass | 0 | `Build complete!` |
| `swift run aural-test` | Pass | 0 | `Aural tests passed` |
| `swift run aural-validate` | Pass | 0 | `Aural validation passed` |
| `scripts/audit-open-source.sh` | Pass | 0 | `open-source audit passed` |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py` | Pass | 0 | `direct segment validation passed` |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py` | Pass | 0 | `segmented worker validation passed` |
| `scripts/audit-runtime-compatibility.sh .build/release/Aural.app` | Pass | 0 | `runtime compatibility audit passed`，目标 macOS 14.0+ |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py` | Fail | 1 | 缺少 `.build/release/Aural.app/Contents/Resources/itn/custom_wetext_fsts/zh/itn/tagger_no_standalone.fst` |

## 真实模型 Smoke

前置检查：

- `.build/release/Aural.app` 存在。
- `.build/release/Aural.app/Contents/Resources/runtime/bin/python3` 存在且可执行。
- 默认模型缓存存在：`~/Library/Application Support/Aural/Models`。
- 模型目录包含 `qwen3-asr-1.7b-4bit`、`qwen3-asr-1.7b-bf16`、`qwen3-asr-0.6b-4bit`、`qwen3-forcedaligner-0.6b-4bit-mlx`。

| 项目 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| S1 direct worker | `AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" scripts/smoke-direct-bundle-worker.sh` | Pass | 生成 `.build/direct-worker-smoke/task/transcript.json`，`segments=1`，`timestamp_method=text_length_proportional`，命令内 codesign 当次通过 |
| S2 app queue，首次 | `AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" scripts/smoke-app-queue-bundle.sh` | Fail | 退出码 133。运行时曾提示另一个 SwiftPM 进程占用 `.build`，随后 `aural-e2e` 报 `runtime/bin/python3` 不存在；复查该文件存在，判断为并发/构建目录瞬态风险 |
| S2 app queue，复跑 | 同上 | Fail | 功能路径通过：`status=转写完成`、`segments=1`、`timestamp_method=qwen3_forced_aligner_paragraph`；坏音频路径通过：`status=转写失败`、生成 `error.log`；最终 codesign 失败导致脚本退出 1 |
| 独立 codesign 复验 | `codesign --verify --deep --strict --verbose=4 .build/release/Aural.app` | Fail | `code has no resources but signature indicates they must be present` |
| 签名信息读取 | `codesign -dv --verbose=4 .build/release/Aural.app` | Info | `Signature=adhoc`，`Sealed Resources=none`，`TeamIdentifier=not set` |

Smoke 产物摘要：

- Direct transcript：`.build/direct-worker-smoke/task/transcript.json`
  - `segments=1`
  - `pipeline=direct_single_pass_text_segments`
  - `timestamp_method=text_length_proportional`
- App queue transcript：`.build/app-queue-smoke/data/tasks/FC4E738D-B417-45D5-8E67-3AEDA255CA6D/transcript.json`
  - `segments=1`
  - `pipeline=macos_afconvert_segmented`
  - `timestamp_method=qwen3_forced_aligner_paragraph`
- 坏音频错误日志：`.build/app-queue-smoke/failure-data/tasks/74C91463-1649-4B00-AACE-CCAA267F753C/error.log`
  - 摘要：`RuntimeError("Error: Couldn't open input file ('typ?')")`

跳过项：无。runtime 和模型缓存可用，direct/app queue smoke 均已尝试执行。
影响：app queue 真实模型功能链路有通过证据，但 release app 当前签名状态失败，不能用于发布结论。
是否阻塞发布：阻塞当前 release app 放行。
下一步：重新构建并签名 `.build/release/Aural.app`，避免多个 agent 同时写 `.build`，复跑 `scripts/smoke-app-queue-bundle.sh` 和独立 codesign。

## 手工回归清单

发布前仍建议按 `qa/regression-checklist.md` 逐项手工确认：

- 首次启动资源检查：无模型、部分模型、已有完整模型。
- 模型准备路径：ModelScope 优先、Hugging Face fallback 原因可见、失败可恢复。
- 音频导入：`mp3`、`m4a`、`wav`、`aac`、`flac`。
- 视频导入：`mp4`、`mov`、`m4v`；确认只保留 app-owned audio copy，不复制用户原始视频。
- 队列行为：多个任务顺序处理、运行中停止、失败后重试、暂停/恢复状态一致。
- 播放核对：拖动进度、段落高亮、点击段落跳转到对应时间。
- 导出：SRT、纯文本、带分段时间文本；确认空 transcript 和失败任务不可误导导出。
- 删除任务：删除 app-owned 音频副本和 transcript，不删除用户原始文件。
- Alignment：开启、关闭、aligner 缺失/损坏 fallback；记录 `timestamp_method`。
- ITN：补齐 `custom_wetext_fsts` 后复跑 `scripts/validate-itn-postprocess.py`。
- 英文短音频 smoke：补齐一个可重复样例，确认语言/分段/导出没有中文路径假设。
- 视频抽音频 e2e smoke：补齐脚本化样例或手工证据。
- 签名与发布包：重新生成 release app/DMG 后执行 `codesign --verify --deep --strict`、notarization 验证和打开后首启 smoke。

## 发布风险

- P0/Release blocker：当前 `.build/release/Aural.app` codesign 严格校验失败。
- P1：app queue smoke 首次遇到 `.build` 并发/瞬态缺失 runtime 的失败；多 agent 共享工作树时建议串行 release/smoke 构建步骤。
- P3：ITN FST 缺失；PM 已确认不阻塞 0.1.0，作为低优先级优化暂不排期。
- 未覆盖：视频抽音频 e2e、英文短音频、aligner 缺失/损坏 fallback、notarized DMG。

## Project Lead 复验补充

时间：2026-07-09

QA 原始报告中的 codesign blocker 指向当时的 ad-hoc / 中间态 `.build/release/Aural.app`。随后 Project Lead 修复 `scripts/build-local-app.sh`，在签外层 App 前逐个 Developer ID 签名 bundle 内嵌 Mach-O，并重新生成正式候选包。

最终候选：

```text
.build/release/Aural-0.1.0-20260709-163802.dmg
```

最终复验结果：

- `codesign --verify --deep --strict --verbose=2 .build/release/Aural.app`：Pass。
- 嵌套 Mach-O 扫描：140 个 Mach-O，均具备 Developer ID、timestamp 和 hardened runtime。
- runtime hygiene 复验：本机绝对 load path 数量为 0，`joblib/test/data/*.gz` warning 源数量为 0。
- `hdiutil verify .build/release/Aural-0.1.0-20260709-163802.dmg`：Pass。
- `scripts/smoke-direct-bundle-worker.sh`：Pass。
- `scripts/smoke-app-queue-bundle.sh`：Pass，正常转写和坏音频失败路径均通过。

当前剩余 release blocker 变更为 notarization/staple 未完成：Developer ID signing 和 `AuralNotaryProfile` 已可用；旧 signed-DMG submission 长时间停留 `In Progress`，已重建更干净的新 signed DMG 并提交 notarization，当前等待 Apple 返回最终状态。详见 `work/checkpoints/2026-07-09-release-build-qa.md`。
