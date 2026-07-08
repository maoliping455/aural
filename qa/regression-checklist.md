# Aural QA 回归清单

## 默认 CI 回归

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

## 本地轻量扩展回归

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py
```

## ITN 条件回归

前置条件：本地或 bundle 中存在完整 `custom_wetext_fsts`，至少包含 `zh/itn/tagger_no_standalone.fst`。

```bash
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-itn-postprocess.py
```

## 发布前建议回归

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
scripts/audit-runtime-compatibility.sh .build/release/Aural.app
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
```

真实模型 smoke test 仅在 runtime、模型缓存和本机资源完整时运行：

```bash
scripts/smoke-direct-bundle-worker.sh
scripts/smoke-app-queue-bundle.sh
```

执行范围、跳过规则、失败分级和结果记录模板见 [real-model-smoke-0.1.0.md](real-model-smoke-0.1.0.md)。

## 手工路径

- 首次启动资源检查：无模型、有部分模型、已有完整模型。
- 导入音频：`mp3`、`m4a`、`wav`、`aac`、`flac`。
- 导入视频：`mp4`、`mov`、`m4v`，确认只保留 app-owned audio copy。
- 队列行为：多个任务顺序处理，运行中停止，失败后重试。
- 播放核对：拖动进度、段落高亮、跳转到段落时间。
- 导出：SRT、纯文本、带分段时间文本。
- 删除任务：删除 app-owned 副本和 transcript，不删除用户原始文件。
