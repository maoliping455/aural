# Aural 0.1.0 PM 决策日志

更新时间：2026-07-08

本文档记录 Aural 0.1.0 发布前需要产品经理确认的关键决策。所有未确认项都只能作为默认推进假设，不能当作最终发布承诺。

状态定义：

- `建议采用`：当前 PM 建议，可先按此推进，仍需最终确认。
- `待确认`：需要 PM 明确拍板。
- `已确认`：PM 已确认，可作为开发/QA/发布依据。
- `暂缓`：不进入 0.1.0。
- `阻塞`：未解决前不建议发布。

## 决策总览

| ID | 决策 | 建议结论 | 状态 | 发布影响 |
| --- | --- | --- | --- | --- |
| D1 | 主线目录 | 使用 `aural-open-source` | 建议采用 | 影响后续开发、QA 和发布归档 |
| D2 | 发布包形态 | 轻量 DMG + 首次下载模型 | 建议采用 | 影响打包、安装、README、模型准备 QA |
| D3 | 默认转写配置 | 平衡 + 字幕时间戳对齐 | 建议采用 | 影响首启资源大小、默认质量和播放体验 |
| D4 | ITN FST | 不把缺失 FST 作为 0.1.0 P0；作为低优先级优化暂不排期 | 已确认 | 影响中文归一化质量和验证脚本，但不阻塞首发 |
| D5 | notarization | 0.1.0 公开发布必须 Developer ID signed + notarized | 已确认 | 阻塞公开发布包 |
| D6 | 真实模型 smoke | 发布前必须跑最小 smoke 集 | 建议采用 | 影响是否能证明真实 ASR 链路可用 |
| D7 | ASR 质量底线 | 严重重复/幻听作为 release blocker；raw ASR 重复循环必须闭环 | 已确认 | 阻塞发布候选验收 |
| D8 | README 语言 | 0.1.0 中文优先，英文版不阻塞首发 | 建议采用 | 影响开源传播，但不影响首批用户验证 |
| D9 | 完整离线包 | 不进入 0.1.0 默认 release | 建议采用 | 降低包体和发布维护成本 |
| D10 | 0.1.0 新功能 | 暂停新增，优先收敛发布 | 建议采用 | 保护交付节奏 |

## D1：主线目录

建议结论：使用 `aural-open-source` 作为 0.1.0 唯一主线。

理由：

- 该目录已有 README、架构、隐私、release、packaging、worker protocol、transcript schema、QA 文档和开源审计脚本。
- 该目录已包含模型资源准备和轻量 release 包路径。
- `aural-mac-app` 更像早期技术原型，文档和 release 口径较旧。

替代选项：

- 继续双目录并行：会增加文档漂移、重复 QA 和发布混乱。
- 回到 `aural-mac-app`：会丢失已经补齐的开源/QA/release 文档结构。

需要确认：

- 是否允许后续所有 PM、开发、QA 文档默认落在 `aural-open-source`。

## D2：发布包形态

建议结论：0.1.0 默认发布轻量 DMG，不发布完整离线模型包。

默认包形态：

- App。
- Python runtime。
- worker scripts。
- 可选 ITN 资源。
- 不内置 ASR / aligner 模型权重。
- 首次启动下载并缓存模型。

理由：

- 包体更小，适合 GitHub Release。
- 模型缓存位于用户目录，App 升级可复用。
- 更容易解释“本地优先但首次需要下载模型”的产品体验。

替代选项：

- 完整离线包：首次使用更直接，但包体大、发布成本高、模型升级成本高。
- 同时发轻量包和完整包：增加 QA 和用户选择成本，不适合 0.1.0 首发。

需要确认：

- 是否接受 0.1.0 只发轻量 DMG。

## D3：默认转写配置

建议结论：默认使用“平衡 + 字幕时间戳对齐”。

理由：

- 平衡模式对应 `qwen3-asr-1.7b-4bit`，当前是质量、速度、内存和体积之间的默认折中。
- 时间戳对齐能改善播放定位和字幕导出。
- 该口径已和 README、release、PRD、project plan 保持一致。

替代选项：

- 极速 + 不开启对齐：下载小、速度快，但默认质量和定位体验下降。
- 精准 + 开启对齐：质量可能更好，但下载更大、内存要求更高，不适合作为普通默认。

需要确认：

- 是否保持当前默认配置。

## D4：ITN FST 发布策略

确认结论：不把缺失 ITN FST 定义为 0.1.0 P0 blocker；ITN 优化作为低优先级优化项目记录，暂不排期。

当前事实：

- QA 记录显示 `validate-itn-postprocess.py` 在缺少 `zh/itn/tagger_no_standalone.fst` 时失败。
- 当前主链路可以在没有完整 ITN FST 时回退 raw/基础文本，但中文日期、手机号、英文缩写等归一化质量会受影响。

发布口径：

- 0.1.0 定位为“可用的本地转写首发版”，不承诺中文格式归一化稳定。
- 缺失 FST 时保留 raw/基础文本，不阻塞主链路发布。
- 后续如重新排期 ITN，需要补齐 FST 来源、许可证、打包方式和 `validate-itn-postprocess.py` 回归。

后续记录：

- ITN 优化暂不排期。
- README / release notes 如提到中文格式归一化，应说明部分格式归一化仍在优化。

## D5：notarization

确认结论：0.1.0 公开发布必须使用 Developer ID Application 证书签名，并完成 Apple notarization。ad-hoc signed 只允许作为本地开发包或内部临时验证包。

理由：

- 用户已申请 Apple Developer Program，0.1.0 可以进入正式签名/notarization 流程。
- Gatekeeper 拦截会显著增加普通用户安装阻力和支持成本。
- 公开 release 文档不应再默认要求用户通过右键打开绕过 Gatekeeper。

执行要求：

- `scripts/build-local-app.sh` release 构建必须传入 `AURAL_CODESIGN_IDENTITY` 或 `--codesign-identity`。
- release 机器必须使用有效的 `Developer ID Application` identity；具体 identity 记录在本地 release checkpoint，不写入公开发布文档。
- release 构建必须启用 hardened runtime 和 timestamp。
- DMG 必须通过 `scripts/notarize-release-dmg.sh` 提交、staple 和 Gatekeeper 验证。
- GitHub Release 只上传已 notarized 的 DMG。

未完成前状态：

- 未取得 Developer ID 证书、未配置 notarytool profile、或 notarization 未通过时，不发布公开 0.1.0 DMG。

## D6：真实模型 smoke test

建议结论：发布前必须跑最小真实模型 smoke 集。

最小集合建议：

- 1 个短中文音频。
- 1 个短英文音频。
- 1 个视频抽音频任务。
- alignment 开启。
- alignment 关闭。
- 缺失或损坏 aligner 的 fallback。

理由：

- `aural-test` 和 `aural-validate` 能证明逻辑和 stub 链路，但不能证明真实 Qwen ASR、runtime、模型缓存、alignment 和打包后的 worker 链路。
- 0.1.0 是本地 ASR App，真实模型 smoke 是发布可信度底线。

需要确认：

- 最小 smoke 样例是否按上述集合执行。
- 是否允许使用本地生成的短音频作为 smoke 输入，还是必须加入真实用户场景样例。

## D7：ASR 质量发布底线

确认结论：严重重复、明显幻听、整段漏转、字幕时间大面积错位应作为 release blocker；轻微错字、标点差异、个别专名错误作为已知限制。遗留 raw ASR 大段重复问题必须在 v0.1.0 发布前完成根因说明、默认策略修复和回归验证。

当前 raw ASR 结论：

- 根因不在 UI、ITN、导出或 forced alignment，而在 Qwen3-ASR 长音频解码阶段的 repetition loop。
- 已有公开安全摘要见 `docs/research/asr-repetition-root-cause-0.1.0.md`。
- 默认 4bit 策略应只使用 Aural 外层 60/90s chunking，首轮不传内部 `chunk_duration`，并使用 neutral `repetition_penalty=1.0`；当 chunk 命中 hard repetition signal 时，再用 `repetition_penalty=1.10` 和 `repetition_context_size=32` 重试。
- 固定 `1.10` 旧策略曾在 18 个历史 raw ASR bad-case 上回归 `bad=0`；动态 retry 策略需要重新补跑历史 bad-case 和 direct/app queue 真实模型 smoke，完成前仍作为 P0 gate。

建议分级：

| 等级 | 示例 | 发布判断 |
| --- | --- | --- |
| P0 | 大段重复、明显幻听、整段漏转、任务成功但 transcript 无有效文本 | 阻塞发布 |
| P1 | 关键专名多次错误、时间戳明显偏移、长音频稳定性差 | 发布前评估，可能阻塞 |
| P2 | 标点不自然、个别错字、格式归一化不完美 | 可作为已知限制 |

需要确认：

- 固定 ASR 质量回归集是否在 0.1.0 内做到脚本化，还是先以已有 bad-case 回归记录和 smoke test 作为首发验收证据。

## D8：README 语言

建议结论：0.1.0 中文优先，英文版不阻塞首发。

理由：

- 当前 README 中文表达已经更贴近首批用户和产品定位。
- 工程文档部分已有英文标题和英文协议文档。
- 完整英文版有利于开源传播，但不应阻塞本地产品主链路验证。

需要确认：

- 是否在 0.1.0 之前补完整 `README_EN.md` 或英文首页。

## D9：完整离线包

建议结论：完整离线包不进入 0.1.0 默认 release。

理由：

- 完整包体大，用户下载和 GitHub Release 维护成本高。
- 同时维护轻量包和完整包会扩大 QA 矩阵。
- 当前产品策略更适合验证轻量包 + 本地模型缓存。

需要确认：

- 是否保留完整离线包只作为开发/特殊分发路径。

## D10：0.1.0 新功能冻结

建议结论：0.1.0 进入功能冻结，只处理发布阻塞、文档、QA 和回归问题。

冻结范围：

- 不新增实时转写。
- 不新增云端 ASR。
- 不新增说话人分离。
- 不新增总结/纪要。
- 不新增视频 OCR。
- 不新增 Intel / CPU-only 后端。

允许范围：

- 修复 P0/P1 bug。
- 完善 release 文档和用户安装说明。
- 补充 QA 验证和真实模型 smoke。
- 修复打包、runtime、模型准备、导出、删除、失败恢复问题。

需要确认：

- 是否从现在开始按功能冻结推进 0.1.0。

## 下一步

当前仍需确认或准备的最小事项：

1. D1 主线目录。
2. D2 发布包形态。
3. D3 默认转写配置。
4. D4 ITN FST 已确认不阻塞，后续作为低优先级优化。
5. D5 / Action A-001：Developer ID 证书和 notarytool keychain profile 在 release 机器就绪。
6. D6 真实模型 smoke 最小集。
7. D7 raw ASR bad-case 回归和真实模型 smoke 是否已通过。

确认后，开发和 QA 可以直接按 `project-plan-0.1.0.md` 推进 M2 / M3。
