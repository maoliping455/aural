# Aural Project Workflow Principles

更新时间：2026-07-08

本文档定义 Aural 项目的执行原则。它约束 Project Lead、子 agent、开发、QA、review 和 release 工作，不是 Aural App 的产品功能说明。

## 核心原则

1. 用户只和 Project Lead 对话。
2. Project Lead 不在主线程承载完整流程上下文；主线程只做目标澄清、角色拆分、决策、集成和汇报。
3. 每个会改变产品范围、代码、文档、QA 状态、release 状态或项目决策的流程，都必须使用角色化子 agent 做上下文隔离。
4. 每一步必须有明确输入、角色 owner、输出文档、验收标准和停止条件。
5. 大量原始材料、实验输出、QA 证据和中间结论必须落盘；对话里只保留摘要、决策和路径。

## 默认角色流

默认流程：

```text
PM / UX -> Architect -> Dev -> QA -> Reviewer / Release -> Project Lead 汇总
```

不同任务可以裁剪角色，但必须记录裁剪原因：

- PM / UX：定义问题、用户价值、范围、非目标和 acceptance criteria。
- Architect：定义实现方案、文件 ownership、风险和回滚路径。
- Dev：在明确 ownership 内实现，不越界修改。
- QA：按 acceptance criteria 验证，不以开发自报为准。
- Reviewer：检查 correctness、regression、privacy、security、release safety 和 missing tests。
- Release：检查包、签名、notarization、release notes、资产和发布证据。
- Research：做只读调查、资料整理和风险分析。

## 子 Agent 使用规则

- 每个子 agent 必须有明确角色、任务范围、文件或责任 ownership、预期输出和停止条件。
- 并行 Dev 子 agent 必须拥有不重叠的文件或模块范围。
- 子 agent 不得回退或覆盖其他人已做的改动。
- 子 agent 发现任务越界、证据不足、需要改动未授权文件时，必须停止并报告。
- Project Lead 必须整合子 agent 输出，并把决策写入对应文档。

## 每步交付物

每个流程至少留下以下一种可追踪产物：

- `work/plan.md`：任务树、角色拆分、ownership、done criteria。
- `work/status.md`：当前状态、证据、风险、下一步。
- `work/decisions.md`：采用/拒绝/待确认决策。
- `work/research/*`：只读 research 摘要。
- `work/checkpoints/*`：阶段性 checkpoint。
- `docs/engineering/*`：可公开或长期维护的工程原则、方案和报告。
- `docs/project-plan-0.1.0.md`：release milestone、backlog、gate 和 action。
- `qa/*`：QA plan、bug、progress、smoke result 和验收证据。

## 最小流程模板

每个非平凡任务开始前，Project Lead 应记录或明确：

```text
目标：
范围：
非目标：
角色分工：
子 agent：
输入文档：
输出文档：
验收标准：
停止条件：
```

完成后，Project Lead 应汇总：

```text
已完成：
证据：
修改文件：
验证结果：
剩余风险：
下一步：
```

## 例外

以下极小任务可以不拆完整角色流，但仍要在回复中说明原因：

- 单个只读命令查询。
- 纯状态汇报。
- 不改变仓库文件的简单解释。
- 用户明确要求只回答、不实施。

即使是例外，若它会影响 release blocker、用户可见行为、QA 状态或项目决策，也必须补文档记录。
