# Aural 文档

这里是 Aural 的项目文档入口。公开仓库中的文档必须安全可发布：不要包含模型权重、生成 transcript、开发者本地绝对路径、用户媒体、私有实验材料或凭据。

除非用户明确指定英文或其他语言，Aural 项目文档默认使用简体中文。产品名、API 名、文件名、命令、模型 ID 和代码标识保持原文。

## 用户文档

- [用户安装与故障排查](user-install-troubleshooting.md)：安装、首次模型准备、常见问题、清理和卸载。
- [隐私说明](privacy.md)：本地优先行为、导入/删除规则、存储和网络使用。
- [发布说明与安装](release.md)：发布包形态、兼容性、安装说明和发布检查。

## 产品与计划

- [产品当前状态](product-current-state.md)：产品范围、0.1.0 交付边界、优先级、QA gate 和开放问题。
- [Aural 0.1.0 PRD](prd-0.1.0.md)：产品需求、用户场景、验收标准、发布 gate、风险和 PM 决策。
- [Aural 0.1.0 项目计划](project-plan-0.1.0.md)：milestone、P0/P1 backlog、release gate、交接模板和 PM 决策跟踪。
- [Aural 0.1.0 PM 决策](pm-decisions-0.1.0.md)：推荐默认值、备选方案、影响和确认状态。
- [Aural TODO](todo.md)：维护者视角的 roadmap 和评估 backlog。

## 开发者与贡献者文档

- [开发者文档](development.md)：本地开发、源码构建、验证命令、仓库结构和开发约束。
- [架构说明](architecture.md)：系统边界、runtime flow、存储布局和模型资源处理。
- [本地 App 打包](packaging.md)：打包形态、runtime 规则、模型缓存行为和验证命令。
- [项目执行原则](engineering/project_workflow_principles.md)：Project Lead、角色化子 agent、文档、QA、review 和 release 执行规则。

## 集成参考

- [Worker Protocol](worker-protocol.md)：Swift 和 Python ASR worker 之间的 JSONL stdin/stdout 协议。
- [Transcript Schema](transcript-schema.md)：持久化的 `transcript.json` 和 `alignment.json` 格式。
- [Qwen Worker Dev Adapter](qwen-worker-dev.md)：用于验证 Swift/worker 边界的开发 adapter 说明。

## QA 与研究

- [Research Notes](research/README.md)：模型和产品评估报告入口。
- [Raw ASR Repetition Root Cause](research/asr-repetition-root-cause-0.1.0.md)：0.1.0 raw ASR repetition blocker 的根因、缓解和发布退出标准。
- [Real Model Smoke Test Plan](../qa/real-model-smoke-0.1.0.md)：打包 runtime、模型缓存、真实 ASR worker、alignment 和 app queue 的 smoke test 计划。

## 发布文档前检查

- 运行 `scripts/audit-open-source.sh`。
- 示例路径使用 `/path/to/...` 这类占位符，不写开发者本地路径。
- 不提交生成媒体、transcript、task 目录、模型缓存、runtime 目录、App bundle 或 DMG。
- 描述实验模型或 workflow 时，标明它是公开发布路径的一部分，还是研究候选。
