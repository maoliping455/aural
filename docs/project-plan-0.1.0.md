# Aural 0.1.0 项目执行计划

更新时间：2026-07-08

本文档用于跟踪 Aural 0.1.0 从当前代码状态到公开发布的执行路径。PRD 定义“要交付什么”，本文档定义“怎么推进、谁验收、什么阻塞发布”。

## 0. 执行原则

0.1.0 发布推进必须遵守 `docs/engineering/project_workflow_principles.md`：

- 每个 milestone、backlog item、bugfix、QA 补测、release action 都必须明确角色 owner。
- 每个非平凡流程必须使用角色化子 agent 隔离上下文；主线程只做 Project Lead 协调、集成、决策和汇报。
- 每个流程必须记录输入文档、输出文档、验收命令或人工路径、停止条件。
- PM/UX 输出 acceptance criteria；Architect 输出实现方案和 file ownership；Dev 在 ownership 内实现；QA 按 acceptance criteria 验证；Reviewer/Release 检查 correctness、regression、privacy、security、release safety 和发布证据。
- 例外只允许用于单个只读命令、纯状态汇报、简单解释或用户明确要求只回答；例外必须说明原因。

## 1. 当前项目判断

Aural 0.1.0 已经具备产品主链路，当前不应继续扩展新功能。项目重点应转为收敛：

- 资源准备链路必须在干净机器上可用。
- 轻量 DMG 发布形态必须可重复构建和验证。
- 导入、队列、转写、播放、导出、删除必须稳定。
- ITN、真实模型 smoke test、Developer ID notarization 和 ASR 质量底线必须给出明确发布决策。
- 文档必须支持用户安装、开发构建、QA 验收和开源发布。

## 2. 发布策略建议

默认发布策略：

- 0.1.0 发布轻量 DMG。
- DMG 包含 App、Python runtime、worker scripts 和可选 ITN 资源。
- DMG 不内置 ASR / aligner 模型权重。
- 首次启动准备模型资源，缓存到用户本机。
- 默认配置为“平衡 + 字幕时间戳对齐”，除非 PM 明确改动。

当前不建议发布完整离线模型包。原因：

- 包体大，分发和 GitHub Release 维护成本高。
- 模型升级会导致重复下载完整 App。
- 0.1.0 更需要验证轻量包和资源准备链路。

## 3. 里程碑

### M0：产品和项目文档收敛

状态：进行中。

目标：

- 有 PM 可接手的当前状态文档。
- 有 0.1.0 PRD。
- 有 0.1.0 项目执行计划。
- docs 入口能让开发、QA、维护者找到对应材料。

交付物：

- `docs/product-current-state.md`
- `docs/prd-0.1.0.md`
- `docs/project-plan-0.1.0.md`
- `docs/README.md`

完成标准：

- `scripts/audit-open-source.sh` 通过。
- 文档不包含模型权重、用户媒体、生成 transcript、runtime、私有路径或凭据。

### M1：发布阻塞项决策

状态：进行中；notarization 和 raw ASR blocker 已由用户确认。

目标：

- 明确 ITN FST 不阻塞 0.1.0，并记录为低优先级优化。
- 执行 Developer ID signing / notarization 发布 gate。
- 明确真实模型 smoke test 最小样例集合。
- 明确 ASR 质量问题发布底线。

完成标准：

- PM 决策表有结论。
- 每个阻塞项都有 owner、下一步和验收命令或手工路径。

### M2：开发收敛

状态：待 M1 决策后执行。

目标：

- 处理 P0/P1 技术和打包问题。
- 不新增非必要功能。
- 对资源准备、runtime 兼容性、worker 异常和导出路径做必要修复。

完成标准：

- 开发给出改动说明、自测结果和 QA 回归建议。
- 不改变 PRD 范围，除非 PM 明确批准。

### M3：QA 回归和真实模型 smoke

状态：待开发收敛后执行。

目标：

- 快速 CI 基线通过。
- 轻量扩展验证通过。
- 发布包构建和 runtime 审计通过。
- 真实模型 smoke test 有结论。
- 主链路手工验收完成。

完成标准：

- QA 输出 0.1.0 验收结果。
- 未解决问题都有优先级和发布阻塞判断。

### M4：发布准备

状态：待 M3 通过后执行。

目标：

- Release DMG 可发布。
- README、release notes、third-party notices 和安全文档一致。
- GitHub Release 资产和安装说明准备完成。

完成标准：

- 发布 checklist 完成。
- PM 明确批准发布。

## 4. P0 Backlog

| ID | 事项 | 当前判断 | Owner | 验收方式 |
| --- | --- | --- | --- | --- |
| P0-1 | 轻量 DMG 构建链路 | 必须发布前通过 | Dev | `build-local-app.sh --include-runtime`、runtime audit、codesign verify |
| P0-2 | 首次模型资源准备 | 必须真实验证 | Dev + QA | 干净模型缓存启动、下载、失败重试、缓存复用 |
| P0-3 | 核心主链路 | 必须手工通过 | QA | 导入、转写、播放、导出、删除 |
| P0-4 | worker 失败收敛 | 自动化已有覆盖，发布前复跑 | Dev + QA | `swift run aural-test`、`swift run aural-validate` |
| P0-5 | 开源审计 | 必须发布前通过 | Dev | `scripts/audit-open-source.sh` |
| P0-6 | ITN FST 发布策略 | 已确认不阻塞 0.1.0；作为低优先级优化暂不排期 | PM + Dev | 当前记录非阻塞 raw text fallback；后续排期时再补 FST、许可证、打包和 `validate-itn-postprocess.py` 回归 |
| P0-7 | ASR 质量发布底线 | 当前 ASR blocker 已接受为 0.1.0 RC；规则继续阻塞新增 hard bad | PM + QA + Dev | 根因文档、当前策略修复、direct/segmented validation、真实模型 smoke、用户基本功能验证 |
| P0-8 | Developer ID signing + notarization | 必须公开发布前通过；Developer ID Application identity 和 notarytool profile 已就绪，仍需实跑 signed/notarized DMG 验证 | Dev + Release | Developer ID signed app、notarized DMG、staple 和 Gatekeeper 验证 |

## 4.1 Release Actions

| ID | Action | 状态 | Owner | 完成标准 |
| --- | --- | --- | --- | --- |
| A-001 | 配置 release 机器 Developer ID signing 和 notarytool keychain profile | Done for 0.1.0 RC | Release | release 机器已确认有效 `Developer ID Application` identity；最终 `Aural-0.1.0.dmg` submission `c4c8b838-e96a-4efe-ad32-71cfa96650ef` 已 `Accepted`，staple、stapler validate 和 Gatekeeper 验证通过 |

## 5. P1 Backlog

| ID | 事项 | 当前判断 | Owner | 验收方式 |
| --- | --- | --- | --- | --- |
| P1-1 | 真实模型 smoke test 最小集 | 强烈建议发布前完成 | QA + Dev | 音频、视频抽音频、alignment 开关、失败 fallback |
| P1-2 | 用户安装和故障排查说明 | 强烈建议发布前完成 | PM | 覆盖 Gatekeeper、模型下载失败、缓存清理、卸载 |
| P1-3 | 安装文档与 Gatekeeper 口径 | 发布前完成 | PM + Dev | 文档只把 ad-hoc 作为开发包说明，公开 DMG 按 notarized 口径 |
| P1-4 | Release notes 走读 | 发布前完成 | PM + Dev | README、release、privacy、packaging 说法一致 |
| P1-5 | 导出回归 | 发布前完成 | QA | SRT、纯文本、带分段时间 TXT |
| P1-6 | 模型下载失败文案和重试体验 | 发布前验证 | QA | 断网、下载中断、已有 partial cache |
| P1-7 | README 公开软件截图 | 发布前建议完成 | QA + Operations | 用隔离 `AURAL_DATA_ROOT` 和可公开 demo 数据截图，避免暴露真实文件名、转写内容或本地路径；截图放入 `docs/assets/` 后再在 README 引用 |

## 6. P2 Backlog

| ID | 事项 | 当前判断 | Owner | 验收方式 |
| --- | --- | --- | --- | --- |
| P2-1 | issue 模板 | 可 0.1.x | PM + Dev | Bug、功能建议、兼容性、ASR 质量问题分流 |
| P2-2 | UI 自动化或截图回归 | 可 0.1.x | QA | 覆盖首次准备、主界面、导出 |
| P2-3 | ASR 质量回归集扩展 | 可持续推进 | PM + QA | 长音频、噪声、强口音、中英混合 |
| P2-4 | 包体继续瘦身 | 可 0.1.x | Dev | 包体报告、runtime 依赖审计 |

## 7. 当前不排入 0.1.0

- 实时麦克风转写。
- 云端 ASR。
- 说话人分离。
- 内置总结、纪要和行动项。
- 视频 OCR 上下文增强。
- Intel Mac / CPU-only 后端。
- 多模型高级参数面板。
- 中文 / 英文界面语言切换，计划进入 0.2.0。
- `aural-cli`、智能体 Skill 和基于转写的总结能力，计划进入 0.2.0。
- 自定义数据目录和目录迁移，计划进入 0.2.0。

这些能力进入后续路线图前，需要单独 PRD 和技术方案。

## 8. 发布 Gate

### Gate A：文档安全

必须通过：

```bash
scripts/audit-open-source.sh
```

不得包含：

- 模型权重。
- runtime 目录。
- App bundle 或 DMG。
- 用户音视频。
- 生成 transcript、alignment、task data。
- 本机绝对路径、私有实验素材、凭据。

### Gate B：快速自动化

必须通过：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

### Gate C：发布包

公开发布必须通过：

```bash
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
AURAL_RUNTIME_MIN_MACOS=14.0 \
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --itn-fst-source /path/to/custom-wetext-fsts
AURAL_RUNTIME_MIN_MACOS=14.0 scripts/audit-runtime-compatibility.sh .build/release/Aural.app
codesign --verify --deep --strict --verbose=2 .build/release/Aural.app
spctl --assess --type execute --verbose=4 .build/release/Aural.app
AURAL_DMG_OUTPUT=.build/release/Aural-0.1.0.dmg \
scripts/package-local-dmg.sh
scripts/notarize-release-dmg.sh .build/release/Aural-0.1.0.dmg
```

### Gate D：真实模型 smoke

建议最小覆盖：

- 1 个短中文音频。
- 1 个短英文音频。
- 1 个视频抽音频任务。
- alignment 开启。
- alignment 关闭。
- 损坏或缺失 aligner 的 fallback。

若跳过，必须记录原因和发布风险。

### Gate E：手工主链路

必须覆盖：

- 首次启动资源准备。
- 资源准备失败和重试。
- 已有资源复用。
- 导入音频。
- 导入视频。
- 多任务串行队列。
- 停止、恢复、失败重试。
- 播放、seek、跟随播放位置。
- 三种导出。
- 删除任务且原始文件保留。

## 9. PM 决策表

| 决策 | 推荐结论 | 状态 | 说明 |
| --- | --- | --- | --- |
| 主线目录 | 使用 `aural-open-source` | 待确认 | 该目录已有开源、QA、release 和模型资源准备文档 |
| 发布形态 | 轻量 DMG + 首次下载模型 | 待确认 | 不建议 0.1.0 默认发布完整离线模型包 |
| 默认模式 | 平衡 + 字幕时间戳对齐 | 待确认 | 与当前 README / release / PRD 一致 |
| ITN FST | 不阻塞 0.1.0，作为低优先级优化暂不排期 | 已确认 | 当前 QA 记录显示 FST 缺失会导致 ITN 验证失败；0.1.0 接受 raw/基础文本 fallback |
| notarization | 公开 v0.1.0 必须 Developer ID signed + notarized | 已确认 | 未通过不上传公开 DMG |
| 真实模型 smoke | 发布前至少跑最小集 | 待确认 | 否则只能证明逻辑链路，不能证明真实 ASR 链路 |
| ASR 质量底线 | 严重重复/幻听/整段漏转为 P0 blocker | 已确认 | raw ASR 重复循环必须完成修复和回归 |
| README 语言 | 中文优先，英文可后补 | 待确认 | 面向首批用户可先中文；英文版影响开源传播 |

## 10. 每周/每轮同步格式

建议 PM 用以下格式同步项目状态：

```text
版本：Aural 0.1.0
本轮目标：
角色分工：
子 agent：
输入文档：
输出文档：
已完成：
未完成：
P0 阻塞：
P1 风险：
开发下一步：
QA 下一步：
需要 PM 决策：
预计是否影响发布：
```

## 11. 开发交付模板

```text
角色分工：
子 agent 输出：
输入文档：
输出文档：
关联需求：
改动范围：
文件 ownership：
用户可见变化：
协议/schema/存储/打包影响：
自测命令：
自测结果：
建议 QA 回归：
已知风险：
是否影响发布：
```

## 12. QA 验收模板

```text
QA 子 agent：
输入文档：
输出文档：
验收范围：
环境：
自动化结果：
手工主链路结果：
真实模型 smoke 结果：
新发现问题：
未关闭问题：
发布阻塞判断：
需要 PM 决策：
```
