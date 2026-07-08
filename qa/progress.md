# Aural QA 进展

## 2026-07-08

### 当前结论

- CI 基线中的 `swift build`、`swift run aural-validate`、`scripts/audit-open-source.sh` 已可通过。
- 当前本地 Swift 工具链缺少 `XCTest` 和 `Testing` 模块，已新增无测试框架依赖的 `aural-test` 快速验证入口。
- `swift run aural-test` 已接入 CI，并按 CI 顺序完成本地回归验证。
- `aural-test` 已扩展覆盖 worker JSON 协议、transcript schema、metadata、alignment sidecar 和 fractional timestamp。
- `aural-test` 已扩展覆盖 TaskStore 的 running 恢复、invalid completed 修复、failed+valid transcript 修复。
- `aural-test` 已扩展覆盖 TaskStore 暂停/恢复状态机：pending/running 可暂停、paused/failed 可恢复、done 不受影响、failed 重启清理 stale 输出。
- `aural-test` 已扩展覆盖 ASRWorkerClient 的非零退出、缺少 terminal event、timeout，以及队列处理 worker failed event。
- `aural-test` 已扩展覆盖队列处理 invalid completed event 和 ASRWorkerClient cancel。
- `aural-test` 已扩展覆盖队列运行中的 progress 落盘、完成后 progress 清理，以及运行中暂停不被 worker 后续状态覆盖。
- `aural-test` 已扩展覆盖 malformed worker stdout 的 client/queue 收敛路径。
- `aural-test` 已扩展覆盖模型资源状态纯逻辑：默认配置、下载预估、兼容性阻断、accurate profile 内存降级和 progress event 解码。
- `aural-test` 已扩展覆盖 ModelResourcePreparer 缺少准备脚本、准备脚本失败、stderr/退出码保留和有效 progress event 保留。
- QA 章程已补充与指导者同步的确认点：产品预期、优先级、发布取舍、越界风险和冲突证据。
- `scripts/validate-itn-postprocess.py` 当前仍需要完整 ITN FST 资源；缺失时应作为待开发处理的资源/打包问题跟进。
- `aural-validate` 已避免在源码目录生成 Python `__pycache__`，不会再阻断后续开源审计。
- 真实模型 smoke 已完成第一轮：direct worker、app queue + segmented worker、alignment 开启、alignment 关闭、坏音频失败路径和 codesign 均通过；结果见 `qa/real-model-smoke-results-20260708.md`。
- raw ASR 大段重复 P0 blocker 已完成根因说明和默认策略回归：当前默认 4bit 策略为 `chunk_duration=30s`、`repetition_penalty=1.10`、`repetition_context_size=32`；18 个历史 `asr_repetition_with_alignment_reject` bad-case 回归 `bad=0`，最新 direct/app queue 真实模型 smoke 通过且 metadata 记录新参数。
- 真实模型 smoke 仍未覆盖视频抽音频、英文短音频、aligner 缺失/损坏 fallback。

### 本轮测试结果

| 命令 | 结果 | 备注 |
| --- | --- | --- |
| `swift build` | Pass | Swift targets 编译通过 |
| `swift run aural-validate` | Pass | 核心验证入口通过 |
| `scripts/audit-open-source.sh` | Pass | `aural-validate` 后复跑通过，无 pycache 残留 |
| `swift run aural-test` | Pass | 已纳入 CI，覆盖文件类型识别、导出渲染、TaskStore 生命周期/暂停/恢复/修复、队列 progress/暂停保护、worker 协议、异常 worker/cancel 路径、模型资源状态/准备失败路径和 transcript schema |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py` | Pass | 直接 worker 分段辅助逻辑通过 |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py` | Pass | 分段 worker 辅助逻辑通过 |
| `.build/release/Aural.app/.../python3 work/chunk-hallucination/scripts/run_bad_case_parameter_matrix.py ...` | Pass | 当前默认 4bit 策略 18 个 raw ASR bad-case 回归 `bad=0` |
| `env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py` | Fail | 已前置报出缺少 `zh/itn/tagger_no_standalone.fst` |
| `scripts/smoke-direct-bundle-worker.sh` | Pass | 真实模型 direct worker smoke 通过，metadata 记录当前 ASR generate 参数 |
| `scripts/smoke-app-queue-bundle.sh` | Pass | 真实模型 app queue + segmented worker + alignment 开启 smoke 通过，metadata 记录当前 ASR generate 参数 |
| `AURAL_ALIGNMENT_ENABLED=0 ... scripts/smoke-app-queue-bundle.sh` | Pass | alignment 关闭后回退估算时间戳，坏音频失败路径通过 |

### 新增测试资产

- `Sources/AuralTests/main.swift`
- `Sources/AuralValidation/main.swift`
- `.github/workflows/ci.yml`
- `qa/bug-template.md`
- `qa/qa-charter.md`
- `qa/dev-sync.md`
- `qa/qa-dev-contract.md`
- `qa/regression-checklist.md`
- `qa/test-coverage-map.md`
- `qa/bugs.md`
- `qa/progress.md`
- `qa/real-model-smoke-0.1.0.md`
- `qa/real-model-smoke-results-20260708.md`
- `docs/research/asr-repetition-root-cause-0.1.0.md`

### 下一步

- 开发补齐或明确 ITN FST 打包策略后，QA 复跑 ITN 验证。
- release 机器准备 Developer ID 证书和 notarytool profile 后，QA 记录 signed/notarized DMG 验证结果。
- 继续评估 runtime probe 失败等资源准备兼容性分支是否需要测试钩子，缩短失败定位时间。
- 补齐视频抽音频 e2e smoke、英文短音频 smoke、aligner 缺失/损坏 fallback smoke。
