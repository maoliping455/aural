# Aural QA 测试覆盖地图

## 目标

这份覆盖地图用于和开发、产品经理同步：当前哪些质量风险已经有自动化验证，哪些仍需要补齐，哪些需要产品确认优先级。

## 快速基线

| 入口 | 覆盖范围 | 当前状态 |
| --- | --- | --- |
| `swift build` | Swift targets 编译、依赖解析 | 已纳入 CI |
| `swift run aural-test` | 纯逻辑和轻量进程级快速测试：文件类型、导出、任务存储、worker 协议、模型资源准备、transcript schema | 已纳入 CI |
| `swift run aural-validate` | 核心集成验证：任务队列、worker stub、失败/重试、恢复、删除、模型资源状态 | 已纳入 CI |
| `scripts/audit-open-source.sh` | 本地路径、敏感文本、生成物审计 | 已纳入 CI |

## 条件验证

| 入口 | 前置条件 | 当前状态 |
| --- | --- | --- |
| `scripts/validate-direct-segments.py` | 无模型，Python 可运行 | 本地通过 |
| `scripts/validate-segmented-worker.py` | 无模型，Python 可运行 | 本地通过 |
| `scripts/validate-itn-postprocess.py` | 完整 `custom_wetext_fsts` | 当前缺中文 FST，待开发/产品确认 |
| `scripts/smoke-direct-bundle-worker.sh` | 完整 runtime 与模型缓存；执行口径见 `qa/real-model-smoke-0.1.0.md` | 未纳入默认快速基线 |
| `scripts/smoke-app-queue-bundle.sh` | 完整 runtime 与模型缓存；执行口径见 `qa/real-model-smoke-0.1.0.md` | 未纳入默认快速基线 |

## 已覆盖风险

- 支持的音频/视频扩展名大小写识别。
- 不支持文件类型拒绝。
- 导出纯文本、带时间文本、SRT 的文本清理和时间兜底。
- 空 segment 时纯文本导出回退到 top-level transcript text。
- TaskStore 创建、重命名、失败任务重启、删除任务时不删除原始文件。
- TaskStore pending/running 暂停、paused/failed 恢复、done 任务不受暂停/恢复影响。
- TaskStore failed 任务重新入队时清理 stale transcript/alignment/error log，同时保留 source audio。
- App 启动后 running 任务可恢复到 pending，并清理不可信运行态字段。
- done 任务缺失或不可用 transcript 时可修复为 failed，并写入错误日志。
- failed 任务已有可用 transcript 时可修复为 done，并清理 stale error/progress。
- 旧 task JSON 缺少 `mediaKind` 时默认按 audio 解码。
- Worker request/event 使用 snake_case JSON 协议。
- ASRWorkerClient 非零退出时保留 stderr 和 error log。
- ASRWorkerClient 缺少 terminal event 时抛出 missing completion。
- ASRWorkerClient timeout 时终止 worker 并写入 error log。
- TranscriptionQueue 收到 worker failed event 时持久化 failed 状态和 error log path。
- TranscriptionQueue 收到 invalid completed event 时落 failed，并写明 transcript 缺失原因。
- TranscriptionQueue 收到 progress event 时会在 running 状态中途持久化进度，并在完成后清理 transient progress。
- TranscriptionQueue 中运行中的任务被暂停后不会被后续 worker 状态覆盖成 done/failed。
- ASRWorkerClient cancel 时抛出 cancelled 并保留 task id。
- ASRWorkerClient malformed stdout 会在缺少 terminal event 前暴露 JSON 解码失败。
- TranscriptionQueue 遇到 malformed worker stdout 时落 failed 并写 error log。
- 模型资源默认 profile/alignment、下载预估、兼容性阻断、accurate profile 内存降级。
- ModelResourceEvent snake_case download progress 解码。
- ModelResourcePreparer 缺少准备脚本时应失败并报告脚本路径，且不创建 model root。
- ModelResourcePreparer 子进程失败时应保留 stderr、退出码和已解析的 progress event。
- TranscriptStore 保存/读取 snake_case transcript。
- Transcript metadata、raw text、normalized text、alignment item index 保留。
- 缺少 `alignment.json` 时 reader 可容忍。
- 存在 `alignment.json` 时可加载 chunk/item timing。
- Python 生成的带小数秒 ISO 8601 `created_at` 可解码。
- `aural-validate` 后不会留下 Python `__pycache__` 阻断开源审计。

## 待补覆盖

- runtime probe 失败等模型资源准备兼容性分支。
- 视频导入音频提取路径的可重复测试样本。
- 导出文件命名、覆盖冲突和特殊文件名处理。
- 搜索、重命名、删除、重试在 UI 层的端到端验证。
- 真实模型 smoke test 的视频样例、alignment 缺失/损坏样例和英文短音频样例。
- ITN FST 打包策略确定后的中文日期、手机号和英文缩写回归。

## 优先级建议

| 优先级 | 下一步 |
| --- | --- |
| P1 | 明确 ITN FST 是否属于 0.1.0 release 必备资源，并决定验证脚本是否进入默认 CI |
| P1 | 继续评估 runtime probe 失败等资源准备兼容性分支是否需要测试钩子，缩短失败定位时间 |
| P2 | 按 `qa/real-model-smoke-0.1.0.md` 补齐视频、alignment 缺失/损坏和英文短音频 smoke 样例 |
| P2 | 为 UI 关键路径建立手工/自动化回归清单 |
