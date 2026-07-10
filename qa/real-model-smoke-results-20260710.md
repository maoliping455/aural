# Aural 0.1.0 Real Model Smoke Results - 2026-07-10

## 结论

结果：Pass for 0.1.0 RC

当前验证对象：

- `.build/release/Aural.app`
- Qwen3-ASR 1.7B 4bit balanced profile
- 本机模型缓存：`~/Library/Application Support/Aural/Models`

当前 ASR 策略：

- 外层 Aural chunking：60/90s
- 首轮不传内部 `chunk_duration`
- 首轮 `repetition_penalty=1.0`
- hard repetition retry：`repetition_penalty=1.10`、`repetition_context_size=32`
- retry 默认也不改变内部 `chunk_duration`

## 自动验证

已通过：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-direct-segments.py
env PYTHONDONTWRITEBYTECODE=1 scripts/validate-segmented-worker.py
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" scripts/smoke-direct-bundle-worker.sh
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" scripts/smoke-app-queue-bundle.sh
AURAL_MODEL_ROOT="$HOME/Library/Application Support/Aural/Models" \
  AURAL_ALIGNMENT_ENABLED=0 \
  AURAL_SMOKE_WORKER="$PWD/.build/release/Aural.app/Contents/Resources/AuralASRWorker/worker_qwen_segmented_bundle.py" \
  AURAL_EXPECTED_TIMESTAMP_METHOD=vad_speech_weighted_paragraph \
  scripts/smoke-app-queue-bundle.sh
```

说明：`scripts/smoke-app-queue-bundle.sh` 自动选择 segmented worker 时会根据 aligner 缓存强制开启 alignment；因此 alignment-off smoke 需要显式传 `AURAL_SMOKE_WORKER`。

## Targeted ASR Check

样例：

- `xianxia_story_cards.mp4` 提取后的 `source.m4a`
- 输出：`/tmp/aural-no-internal-chunk-xianxia/transcript.json`

结果：

- 首段不再出现 `I've been watching you.`
- metadata 写入：

```json
{
  "chunk_duration_sec": null,
  "repetition_penalty": 1.0,
  "retry_chunk_duration_sec": null,
  "retry_repetition_penalty": 1.1,
  "retry_repetition_context_size": 32
}
```

## 手工验证

用户已在本地验证包 `Aural-0.1.0-local-verify-20260710-123709.dmg` 上反馈：基本功能没有问题。

## 发布判断

当前结果支持生成 0.1.0 release package。

已生成 notarized DMG：

- 路径：`.build/release/Aural-0.1.0.dmg`
- 桌面副本：`/Users/limao/Desktop/Aural-0.1.0.dmg`
- Notarization submission：`f1ea5ff4-5c8e-49a5-a0e1-0bde5c217048`
- 状态：`Accepted`
- 校验：`hdiutil verify`、`xcrun stapler validate`、Gatekeeper `spctl --assess --type open --context context:primary-signature` 均通过
- SHA256：`4c3cff8612b52e55e52312c60b83605835359955744f9549ae1c1336b6f05fea`

notarized DMG 仍建议做一次覆盖安装和首次打开验证。
