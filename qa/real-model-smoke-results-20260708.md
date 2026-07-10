# Aural 0.1.0 真实模型 Smoke Test 结果

执行日期：2026-07-08

## 1. 环境

- 机器架构：`arm64`
- macOS：`26.2`
- Release app：`.build/release/Aural.app` 存在
- 包内 Python runtime：存在
- 包内 segmented worker：存在
- 包内 direct worker：存在
- `say`：存在
- `afconvert`：存在

模型缓存：

```text
~/Library/Application Support/Aural/Models
```

已检查到：

| 资源 | 状态 | 完整标记 |
| --- | --- | --- |
| `qwen3-asr-0.6b-4bit` | present | yes |
| `qwen3-asr-1.7b-4bit` | present | yes |
| `qwen3-asr-1.7b-bf16` | present | yes |
| `qwen3-forcedaligner-0.6b-4bit-mlx` | present | yes |

## 2. 执行结果

### S1：Direct Worker 基线

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-direct-bundle-worker.sh
```

结果：Pass

证据摘要：

- worker 输出 progress event。
- worker 输出 completed event。
- 生成 `transcript.json`。
- 输出 `direct bundle worker smoke passed`。
- `codesign --verify` 通过。
- `metadata.timestamp_method = "text_length_proportional"`。

执行时 transcript 路径：

```text
.build/direct-worker-smoke/task/transcript.json
```

### S2 / S3：App Queue + Segmented Worker + Alignment 开启

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
scripts/smoke-app-queue-bundle.sh
```

结果：Pass

证据摘要：

- 使用 worker：`worker_qwen_segmented_bundle.py`。
- `aural-e2e` 构建完成。
- 成功任务输出 `status=转写完成`。
- 成功任务输出 `segments=1`。
- 成功任务生成 `transcript.json`。
- `metadata.timestamp_method = "qwen3_forced_aligner_paragraph"`。
- 坏音频任务输出 `status=转写失败`。
- 坏音频任务输出 `error_log=`。
- `codesign --verify` 通过。

结论：

- Swift queue、app-owned audio copy、segmented worker、真实 ASR、forced alignment 和坏音频失败路径已闭环。

### S4：Alignment 关闭

命令：

```bash
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
AURAL_ALIGNMENT_ENABLED=0 \
AURAL_SMOKE_WORKER="$PWD/.build/release/Aural.app/Contents/Resources/AuralASRWorker/worker_qwen_segmented_bundle.py" \
AURAL_EXPECTED_TIMESTAMP_METHOD="vad_speech_weighted_paragraph" \
scripts/smoke-app-queue-bundle.sh
```

结果：Pass

证据摘要：

- 使用 worker：`worker_qwen_segmented_bundle.py`。
- 成功任务输出 `status=转写完成`。
- 成功任务输出 `segments=1`。
- `metadata.timestamp_method = "vad_speech_weighted_paragraph"`。
- 坏音频任务输出 `status=转写失败`。
- 坏音频任务输出 `error_log=`。
- `codesign --verify` 通过。

结论：

- 用户关闭字幕时间戳对齐后，segmented worker 可正常完成转写，并回退到估算时间戳。

## 3. 追加验证与未覆盖项

### S6：raw ASR repetition bad-case 回归

命令：

```bash
env PYTHONDONTWRITEBYTECODE=1 \
.build/release/Aural.app/Contents/Resources/runtime/bin/python3 \
work/chunk-hallucination/scripts/run_bad_case_parameter_matrix.py \
  --cases work/chunk-hallucination/results/bad_chunk_cases_latest.json \
  --configs work/chunk-hallucination/configs/v0_1_0_default_4bit.json \
  --case-type asr_repetition_with_alignment_reject \
  --output-jsonl work/chunk-hallucination/results/v0_1_0_default_4bit.jsonl \
  --output-md work/chunk-hallucination/results/v0_1_0_default_4bit.md
```

结果：Pass

证据摘要：

- 当时验证的 4bit 策略：`chunk_duration=30s`、`max_tokens=8192`、固定 `repetition_penalty=1.10`、`repetition_context_size=32`。
- 18 个历史 `asr_repetition_with_alignment_reject` bad-case。
- `bad=0`，`bad_rate=0.0%`。
- 最大重复覆盖率：0.0849。
- 平均单 chunk 生成耗时：约 4.6 秒。

补充验证：

- 已将最新 direct/segmented worker 同步到 `.build/release/Aural.app` 并重新 ad-hoc codesign 后复跑 `scripts/smoke-direct-bundle-worker.sh` 和 `scripts/smoke-app-queue-bundle.sh`。
- 两个 smoke 均通过。
- 当时 smoke transcript metadata 写入 `chunk_duration_sec=30.0`、`max_tokens=8192`、`repetition_penalty=1.1`、`repetition_context_size=32`。

结论：

- 该记录证明固定 `1.10` 策略可以关闭当时已知 hard repetition bad-case。
- 2026-07-10 当前策略已调整为 dynamic repetition retry，需重新补跑后再作为 v0.1.0 发布证据。

| 项目 | 状态 | 原因 | 建议 |
| --- | --- | --- | --- |
| S5 视频抽音频路径 | Not run | 当前 `aural-e2e` 入口只调用 `createTask(fromAudioURL:)`，不能直接验证视频导入 | 补一个视频 e2e 入口或脚本化样例 |
| 英文短音频 smoke | Not run | 当前两个 smoke 脚本内置中文 `say -v Tingting` 样例 | 补英文样例或参数化 smoke 文本/voice |
| aligner 缺失/损坏 fallback | Not run | 当前模型缓存完整，且没有独立脚本临时隔离 aligner | 增加临时 model root 或显式禁用/损坏 aligner 的 smoke |

## 4. 发布判断

当前真实模型 smoke 结论：

- Direct worker：Pass。
- App queue + segmented worker：Pass。
- Alignment 开启：Pass。
- Alignment 关闭：Pass。
- 坏音频失败路径：Pass。
- Raw ASR repetition bad-case 回归：Pass。
- Codesign 验证：Pass。

不阻塞 0.1.0 的部分：

- 已证明真实 ASR 主链路和队列链路可以在当前机器闭环。
- 已证明 alignment 开启/关闭两种 timestamp method 都可完成。
- 已证明当前默认 4bit 解码策略不会在已知 18 个 raw ASR blocker case 上出现 hard repetition。

发布前仍建议补齐：

- 视频抽音频 e2e smoke。
- 英文短音频 smoke。
- aligner 缺失/损坏 fallback smoke。

## 5. 证据与生成物说明

本次执行生成物位于 `.build/` 下，例如：

```text
.build/direct-worker-smoke/
.build/app-queue-smoke/
```

这些文件是本地执行产物，不应提交到 Git。
