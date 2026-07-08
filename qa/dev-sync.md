# Aural QA / 开发同步

## 同步原则

- QA 只提交证据、复现命令、失败验证和风险判断，不直接修改业务实现。
- 开发修复前先确认预期行为和影响范围，避免 QA 与开发在不同目标上推进。
- 修复完成后，开发把改动范围和建议回归命令同步给 QA；QA 复测后更新 `qa/bugs.md` 状态。

## 当前需要开发确认

### QA-2026-07-08-002: ITN 验证缺少中文 FST 规则

- 状态: `New`
- 严重级别: Major
- 优先级: P1
- 复现命令:

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py
```

- 当前实际结果:

```text
validation failed: required ITN FST missing: .build/release/Aural.app/Contents/Resources/itn/custom_wetext_fsts/zh/itn/tagger_no_standalone.fst
```

- QA 判断: 这是资源/打包策略待确认问题。当前代码允许无 FST 时回退 raw text，但验证脚本的目标是确认 ITN 能正常执行，因此需要开发明确 0.1.0 包是否应包含中文 ITN FST。
- 需要开发回答:
  - 0.1.0 release bundle 是否必须包含 `custom_wetext_fsts/zh/itn/tagger_no_standalone.fst`？
  - 如果必须包含，FST 来源目录和构建命令应是什么？
  - 如果不必须包含，`scripts/validate-itn-postprocess.py` 是否应改为可选验证，或只在设置 `AURAL_ITN_FST_ROOT` 时运行？
- 修复后 QA 回归:

```bash
swift build
swift run aural-test
swift run aural-validate
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py
scripts/audit-open-source.sh
```

## 当前已验证关闭

- `QA-2026-07-08-001`: `aural-validate` 不再生成 Python `__pycache__`，CI 顺序下开源审计通过。

## CI 建议

当前 CI 应执行：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

QA 已按上述顺序完成本地回归验证。

ITN 验证暂不建议直接加入默认 CI，除非 CI 环境能稳定提供完整 `custom_wetext_fsts`。
