# Aural 开发者文档

本文档面向开发者和贡献者，记录本地开发、源码构建、验证命令、仓库结构和常见开发约束。用户主页 README 不承载这些工程细节。

## 环境要求

- macOS 14 或更新版本
- Xcode Command Line Tools 或 Xcode
- Swift 6 兼容工具链

0.1.0 默认运行链路面向 Apple Silicon Mac。本地 UI/Core 开发可以先构建不带 runtime 和模型的开发 App；真实 ASR 验证需要准备 runtime 和模型资源。

## 常用验证

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

如果改动涉及 Python worker、导出、alignment 或打包资源，还应按影响范围运行对应脚本。发布打包验证见 [本地 App 打包](packaging.md) 和 [发布说明与安装](release.md)。

## 构建开发 App

构建一个不带 runtime / 模型的开发 App：

```bash
scripts/build-local-app.sh
```

输出位置：

```text
.build/release/Aural.app
```

这个形态适合 Swift UI/Core 开发，不是用户发布包。

## 使用本地 runtime 和模型验证

如果需要测试真实本地 ASR，可以传入 runtime 和模型路径：

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx
```

可选中文 ITN 规则：

```bash
--itn-fst-source /path/to/custom-wetext-fsts
```

公开 release 的签名、公证、runtime pinning、DMG 和完整离线包说明不放在 README，统一见 [本地 App 打包](packaging.md)。

## 仓库结构

```text
AuralASRWorker/        本地 ASR worker 和模型资源准备脚本
Resources/             App 图标资源
Sources/AuralCore/     任务存储、导入、队列、导出、worker 协议
Sources/AuralUIPrototype/
                       SwiftUI macOS App
scripts/               构建、验证、打包和发布脚本
docs/                  项目文档入口
qa/                    QA 计划、bug、进展和 smoke 结果
work/                  本地过程记录、checkpoint、研究和分析产物
```

`work/` 下的本地过程材料默认不作为公开发布内容，除非明确决定整理进 `docs/`。

## 开发约束

- 主流程保持本地优先，不默认上传音视频或转写文本。
- 主界面避免暴露过多模型名称、参数和技术配置。
- worker stdout 保留给 JSON 协议事件，诊断信息写 stderr。
- 删除任务时删除 Aural 管理的音频副本、转写结果和 sidecar 文件，不删除用户原始导入文件。
- 不提交模型权重、Python runtime 目录、App bundle、DMG、用户媒体、生成 transcript、本地任务数据或实验输出。
- 改动 worker 协议、transcript schema、模型资源、打包、隐私边界或用户可见流程时，同步更新相关文档。

## 相关文档

- [贡献指南](../CONTRIBUTING.md)
- [架构说明](architecture.md)
- [Worker Protocol](worker-protocol.md)
- [Transcript Schema](transcript-schema.md)
- [本地 App 打包](packaging.md)
- [发布说明与安装](release.md)
