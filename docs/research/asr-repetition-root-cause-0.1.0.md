# Aural 0.1.0 Raw ASR 重复循环根因说明

日期：2026-07-08

本文是可公开的工程摘要。原始 bad-case 音频、生成 transcript、扫描明细和本机实验路径保留在 ignored `work/chunk-hallucination/`，不进入开源仓库。

## 结论

0.1.0 遗留的 raw ASR 大段重复问题，根因不在 UI、ITN、导出或 forced alignment，而在 Qwen3-ASR 长音频解码阶段。部分口语音频 chunk 会让模型进入稳定 repetition loop，表现为单字、短词或短句大面积重复，并可能打满 `max_tokens`。

forced alignment 相关问题是第二类风险：部分长 chunk 在 ASR 文本看似合理时仍可能出现对齐覆盖率低、时间戳坍缩或 chunk 被拒绝。它会影响字幕时间戳，但不是 raw ASR 重复文本的根因。

## 已排除项

- UI 展示：重复已出现在 worker 写出的 raw ASR 文本中。
- ITN：问题发生在 ITN 前的 raw ASR 阶段。
- 导出：SRT/TXT 只是呈现已有 transcript。
- forced alignment：alignment 可以放大时间戳问题，但不会生成 raw ASR 文本重复。
- 音频格式：已复现 case 的 worker 输入是标准 16 kHz mono PCM wav。

## 触发条件

风险与以下因素共同相关：

- Qwen3-ASR long-form decoding。
- 4bit 量化模型的局部稳定性。
- 较长生成窗口和 chunk 边界。
- 口语填充词、停顿、重复语气词。
- 未启用 repetition penalty 或 loop guard 的解码路径。

历史实验显示，单纯缩短 `max_tokens` 只能截短坏输出，不能让模型恢复正确文本；只在展示层删除重复文本会丢失语义，也无法确认缺失内容。

## 当前工程策略

0.1.0 当前 worker 策略：

```text
ASR generate chunk_duration = unset (Aural outer chunking only)
ASR generate max_tokens = 8192
4bit 首轮 repetition_penalty = 1.0
异常重复时 retry chunk_duration = unset
异常重复时 retry repetition_penalty = 1.10
异常重复时 retry repetition_context_size = 32
外层音频 chunk target/max/min = 60s / 90s / 10s
```

worker 会在每个 chunk 的 raw ASR 输出上计算重复 n-gram 覆盖率。当输出命中 hard repetition signal 时，只重试该 chunk；未命中的正常 case 不再全局套用 `1.10`。这样保留 raw ASR blocker 的恢复路径，同时降低常规口语、歌词和弱人声素材被重复惩罚改写的风险。

`accurate` profile 对应 bf16 模型，首轮默认不启用 repetition penalty；若出现同类 hard repetition，仍可通过相同 retry guard 恢复。

可用于回滚或 A/B 的环境变量：

```bash
AURAL_ASR_REPETITION_PENALTY=1.0
AURAL_ASR_REPETITION_RETRY_PENALTY=1.10
AURAL_ASR_REPETITION_CONTEXT_SIZE=32
AURAL_ASR_REPETITION_RETRY=1
AURAL_MODEL_PROFILE=balanced
```

## 发布阻塞判断

该问题是 v0.1.0 P0 blocker。解除条件：

1. `worker_qwen_segmented_bundle.py` 和 smoke baseline worker 都记录并使用当前解码策略。
2. `scripts/validate-direct-segments.py` 和 `scripts/validate-segmented-worker.py` 覆盖解码参数传递。
3. 已有 raw ASR bad-case 回归集中，`asr_repetition_with_alignment_reject` 类 case 在默认 4bit 策略下不再出现 hard repetition。
4. 真实模型 smoke 至少覆盖 direct worker、app queue、alignment on/off 和坏音频失败路径。
5. QA 记录仍然保留“大段重复、明显幻听、整段漏转、任务成功但 transcript 无有效文本”为 release blocker。

## 当前验证结果

2026-07-08 已对固定 `repetition_penalty=1.10` 的 4bit 策略补回归：

- 18 个历史 `asr_repetition_with_alignment_reject` bad-case。
- 结果：`bad=0`，`bad_rate=0.0%`。
- 最大重复覆盖率：0.0849。
- 平均单 chunk 生成耗时：约 4.6 秒。
- 当时 direct worker 和 app queue + segmented worker 真实模型 smoke 均通过，transcript metadata 写入 `chunk_duration_sec=30.0`、`repetition_penalty=1.1`、`repetition_context_size=32`。

2026-07-10 根据新增常规 case 风险，策略调整为 dynamic repetition retry：首轮不传内部 `chunk_duration`，使用 neutral `1.0`；只在 hard repetition signal 命中时用 `1.10/context=32` 重试。当前 direct/segmented validation、direct worker smoke、app queue + alignment on/off smoke 均已通过；`xianxia_story_cards` targeted check 不再出现英文前缀。历史 hard repetition case 作为 0.1.x 持续回归集维护。

## 后续工作

0.1.0 当前采用 chunk-level loop guard：当重复覆盖率异常时自动用更强 repetition penalty 重跑该 chunk，而不是把 `1.10` 作为所有 case 的全局默认。后续仍建议补充更细的异常信号，例如输出长度异常、疑似打满 token、语言漂移和低置信弱人声场景。
