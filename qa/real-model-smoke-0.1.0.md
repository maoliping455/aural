# Aural 0.1.0 真实模型 Smoke Test 计划

更新时间：2026-07-08

本文档定义 Aural 0.1.0 发布前的真实模型 smoke test 范围。它不替代完整 ASR 质量评测；它只回答一个发布前问题：当前 release 包、runtime、模型缓存、worker、任务队列和基础输出是否能在真实本地 ASR 链路上闭环。

## 1. 目标

真实模型 smoke test 必须证明：

- 打包后的 `Aural.app` 能使用包内 Python runtime。
- worker 能从用户本机模型缓存读取 ASR 模型。
- 至少一条真实 ASR 路径能生成非空 `transcript.json`。
- App queue 路径能创建任务、调用 worker、保存 transcript，并把任务置为转写完成。
- 坏音频能稳定进入转写失败，并产生本地错误日志。
- alignment 开启、关闭、缺失时的行为符合发布预期。
- 已知 raw ASR repetition bad-case 在默认 4bit 策略下不再出现 hard repetition。

## 2. 非目标

本计划不负责：

- 排出完整模型质量榜。
- 覆盖长音频、强噪声、强口音和复杂多语言场景。
- 证明所有用户文件都能成功转写。
- 评估 diarization、OCR、总结、实时转写等非 0.1.0 范围能力。

这些内容应进入 ASR 质量回归集或后续专项评测。

## 3. 前置条件

执行前必须具备：

- Apple Silicon Mac。
- macOS 14 或更新版本。
- 已构建 `.build/release/Aural.app`。
- `.build/release/Aural.app/Contents/Resources/runtime/bin/python3` 可执行。
- 本机模型缓存完整，默认路径：

```text
~/Library/Application Support/Aural/Models
```

默认模型要求：

- 平衡模式 ASR：`qwen3-asr-1.7b-4bit`
- 若验证 alignment：`qwen3-forcedaligner-0.6b-4bit-mlx`

如果模型缓存使用非默认路径，执行命令时设置：

```bash
AURAL_MODEL_ROOT=/path/to/Aural/Models
```

## 4. 最小 Smoke 集合

### S1：Direct Worker 基线

目标：验证包内 Python runtime、direct worker、ASR 模型读取、`transcript.json` 生成和 codesign。

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-direct-bundle-worker.sh
```

通过标准：

- 命令退出码为 0。
- 输出包含 `direct bundle worker smoke passed`。
- 生成 `transcript.json`。
- transcript 至少包含 1 个 segment。
- `metadata.timestamp_method = "text_length_proportional"`。
- `codesign --verify` 通过。

### S2：App Queue + Segmented Worker

目标：验证 Swift queue、app-owned audio copy、packaged segmented worker、真实 ASR 和成功任务状态。

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-app-queue-bundle.sh
```

通过标准：

- 命令退出码为 0。
- 输出包含 `status=转写完成`。
- 输出包含 `segments=`。
- 生成可读、非空 transcript。
- 坏音频分支输出 `status=转写失败`。
- 坏音频分支输出 `error_log=`。
- `codesign --verify` 通过。

### S3：Alignment 开启

目标：验证默认字幕时间戳对齐资源存在时，segmented worker 能写入 forced alignment 结果或符合预期 fallback。

前置：

- 模型缓存中存在 `qwen3-forcedaligner-0.6b-4bit-mlx`。

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
AURAL_ALIGNMENT_ENABLED=1 \
scripts/smoke-app-queue-bundle.sh
```

通过标准：

- 任务成功完成。
- 期望 `metadata.timestamp_method = "qwen3_forced_aligner_paragraph"`。
- 若 alignment 失败但 transcript 有效，必须记录 fallback metadata，并由 QA 记录为 P1/P2 风险，不能静默忽略。

### S4：Alignment 关闭

目标：验证用户关闭字幕时间戳对齐后，缺少 aligner 不阻塞转写。

建议命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
AURAL_ALIGNMENT_ENABLED=0 \
scripts/smoke-app-queue-bundle.sh
```

通过标准：

- 任务成功完成。
- transcript 非空。
- 不要求生成 `alignment.json`。
- timestamp method 应为估算类方法，例如 `vad_speech_weighted_paragraph` 或明确的 direct fallback 方法。

### S5：视频抽音频路径

目标：验证 0.1.0 支持视频导入后只保留 app-owned audio copy。

当前状态：需要补可重复样例或脚本化入口。

建议最小做法：

- 准备一个 5-10 秒本地测试视频。
- 导入 Aural。
- 确认任务 `mediaKind = video`。
- 确认任务目录中存在提取后的音频。
- 确认原始视频不复制进 Aural 任务目录。
- 确认该任务可转写完成。

通过标准：

- 视频任务成功创建。
- 任务目录只保留用于转写的音频副本。
- 转写完成并可导出。

### S6：raw ASR repetition bad-case 回归

目标：验证 v0.1.0 发布阻塞的 raw ASR 大段重复问题已经在默认 4bit 策略下闭环。

当前公开根因摘要：

- `docs/research/asr-repetition-root-cause-0.1.0.md`

执行要求：

- 使用 ignored `work/chunk-hallucination/` 中已有 bad-case 回归资料。
- 只记录统计结果、命令和结论，不把原始音频、私有 transcript 或本机路径提交到仓库。
- 默认 4bit 策略必须包含 `chunk_duration=30s`、`repetition_penalty=1.10`、`repetition_context_size=32`。

通过标准：

- `asr_repetition_with_alignment_reject` 类 case 不再出现 hard repetition。
- transcript metadata 记录当前 ASR generate 参数。
- 若仍出现大段重复、明显幻听、整段漏转或任务成功但 transcript 无有效文本，标记 P0 并阻塞发布候选。

## 5. 跳过规则

真实模型 smoke 可以跳过，但必须记录原因。

允许跳过的情况：

- 当前机器不是 Apple Silicon Mac。
- 当前系统低于 macOS 14。
- release app 尚未构建。
- runtime 缺失。
- 本地模型缓存不完整，且当前任务不是验证模型下载。
- 当前环境不能访问必要下载源，且没有本地缓存。

不允许无记录跳过：

- 发布候选包已经生成。
- 准备公开 release。
- 修改过 runtime、模型资源、worker、queue、transcript schema、alignment、ITN 或打包脚本。

跳过记录必须包含：

```text
跳过项：
原因：
影响：
是否阻塞发布：
下一步：
```

## 6. 失败分级

| 等级 | 条件 | 发布判断 |
| --- | --- | --- |
| P0 | direct worker 或 app queue 真实 ASR 完全不能完成 | 阻塞发布 |
| P0 | 任务显示成功但 transcript 缺失、不可读或为空 | 阻塞发布 |
| P0 | raw ASR 仍出现大段重复、明显幻听或整段漏转 | 阻塞发布 |
| P0 | 坏音频不能进入失败路径，或任务永久卡住 | 阻塞发布 |
| P1 | alignment 开启后经常失败但能 fallback | 发布前评估 |
| P1 | 视频抽音频路径未验证 | 发布前评估 |
| P2 | 合成短音频文本有轻微错字或标点差异 | 不阻塞 |

## 7. 结果记录模板

```text
版本：
机器：
macOS：
Aural.app 构建方式：
模型缓存路径：
ASR profile：
alignment：

S1 direct worker：
结果：
证据路径：
备注：

S2 app queue：
结果：
证据路径：
备注：

S3 alignment on：
结果：
timestamp_method：
alignment.json：
备注：

S4 alignment off：
结果：
timestamp_method：
备注：

S5 video import：
结果：
备注：

新发现问题：
发布阻塞判断：
需要 PM 决策：
```

## 8. 证据保存

建议保存：

- smoke 命令输出摘要。
- `.build/direct-worker-smoke/events.jsonl`
- `.build/direct-worker-smoke/task/transcript.json`
- `.build/app-queue-smoke/e2e.log`
- `.build/app-queue-smoke/e2e-failure.log`
- app queue 任务目录中的 `transcript.json`、`alignment.json`、`error.log`

不要提交这些生成物到 Git。

如果需要分享给开发排查，优先给本地路径和摘要；涉及私人音视频或完整 transcript 时，先确认是否可公开。

## 9. 后续改进

建议后续补齐：

- 可重复的视频 smoke 样例生成脚本。
- alignment 缺失/损坏的独立 smoke 脚本。
- 英文短音频 smoke。
- 对 `timestamp_method` 的更宽容但明确的断言。
- smoke 结果自动汇总到 QA 报告。
