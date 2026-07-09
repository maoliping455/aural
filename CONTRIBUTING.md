# 贡献指南

感谢你帮助改进 Aural。

Aural 目前优先把 Apple Silicon macOS 上的本地音视频转写链路做稳定。贡献时请保持产品主线清晰：本地优先、交互简单、结果可回放校对、导出可靠。

## 开始开发

本地开发、源码构建、仓库结构和常用验证命令见：

- [开发者文档](docs/development.md)
- [本地 App 打包](docs/packaging.md)
- [发布说明与安装](docs/release.md)

最小验证命令：

```bash
swift build
swift run aural-validate
scripts/audit-open-source.sh
```

## 提交 PR 前

请至少确认：

- 改动范围清楚，避免把无关重构混进同一个 PR。
- 用户可见行为、存储格式、worker 协议、模型资源、打包逻辑或隐私边界有变化时，同步更新相关文档。
- 不提交模型权重、Python runtime 目录、App bundle、DMG、用户媒体、生成 transcript、本地任务数据或实验输出。
- 能提供验证命令和结果；如果无法验证，说明原因和剩余风险。

建议运行：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
find . -name '__pycache__' -o -name '*.pyc'
```

## 代码与产品约束

- 主流程保持本地优先，不默认上传音视频或转写文本。
- 主界面避免暴露过多模型名称、参数和技术配置。
- worker 的 stdout 保留给 JSON 协议事件，诊断日志写 stderr。
- 删除任务时只删除 Aural 自己管理的文件和记录，不删除用户原始导入文件。
- 涉及持久化、导入、队列、worker 协议、导出和删除语义的改动，需要补充或更新验证覆盖。

## 发布相关

发布包、签名、公证、runtime pinning、DMG 和完整离线包说明见 [本地 App 打包](docs/packaging.md) 和 [发布说明与安装](docs/release.md)。

Release bundle 可以包含 runtime 或模型资源，但这些大文件必须留在 Git 之外。
