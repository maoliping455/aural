# Aural

Aural 是一款本地优先的 macOS 音频/视频转写 App。

我做它的原因很简单：很多个人笔记、访谈录音、课程录音和视频素材，并不适合先上传到云端再处理。Aural 希望把“导入文件 -> 本地转写 -> 播放核对 -> 导出结果”做得足够简单，让普通用户不用理解模型、参数和技术栈，也能获得可靠的本地转写体验。

这个项目会保持永久免费和开源。如果你觉得它有用，欢迎给项目点 Star；如果遇到问题，欢迎在 GitHub Issue 里反馈，也可以通过小红书或邮箱联系我。

## 它解决什么问题

- 不想把私人音视频上传到云端，但又需要转写成文字。
- 希望批量导入文件后自动排队处理，不想反复点开始。
- 需要边听边核对转写结果，快速跳转到对应时间点。
- 需要把结果导出为字幕、纯文字或带时间戳文本，再交给其他工具继续整理。

## 适合谁

- 个人笔记、访谈、课程录音、播客素材和公开视频素材整理。
- 希望结果留在本机、不想注册账号或订阅云服务的用户。
- 能接受本地模型首次下载时间，换取后续离线转写体验的用户。

## 暂时不适合什么

- 实时会议字幕或麦克风直播转写。
- 需要多人发言人分离、自动总结、章节摘要的完整会议助手场景。
- Intel Mac 或纯 CPU 环境。0.1.0 先把 Apple Silicon 本地链路做好。

## 设计思路

- **本地优先**：音视频、转写结果和模型资源都保存在本机。
- **极简交互**：默认配置就是推荐配置，不在主界面暴露模型选择和复杂参数。
- **清晰状态**：任务只有未开始、转写中、已停止、转写完成、转写失败等直接状态。
- **可长期维护**：模型资源放在用户目录中，App 升级时尽量复用，避免重复下载。
- **开放扩展**：总结、纪要和行动项更适合作为后续智能体 Skill，而不是强行塞进转写主流程。

## 当前能力

- 支持音频：`mp3`、`m4a`、`wav`、`aac`、`flac`
- 支持视频：`mp4`、`mov`、`m4v`，导入后只保留提取出的音频副本
- 本地转写队列：默认一次处理 1 个任务
- 任务停止、重新开始、删除、重命名和搜索
- 音频播放、拖动进度、跟随播放位置、段落高亮
- 导出格式：
  - 字幕 SRT
  - 纯文字 TXT
  - 带分段时间 TXT
- 无账号、无遥测、无云端转写

## 下载安装

0.1.0 起，Release 包采用轻量安装包：App 内置本地运行环境，但不把大模型权重打进 DMG。

首次打开 Aural 时会检查本地转写资源：

- 如果资源已经存在，会直接复用。
- 如果资源不存在，会先说明需要准备本地模型。
- 可以选择三种本地转写模式：
  - **极速**：更快完成，资源占用更低。
  - **平衡**：默认推荐，平衡速度和准确性。
  - **精准**：更追求准确性，占用更高；需要 16GB 及以上内存。
- “字幕时间戳对齐”默认推荐开启，播放定位和字幕导出会更准确；也可以关闭以减少下载资源。
- 点击“开始准备”后开始下载，并显示整体百分比进度。
- 下载支持断点续传；已下载的部分会保留，重试时继续下载。
- 资源准备完成前不能导入或转写文件。
- 后续可以在 Aural 的本地转写设置中修改默认模式、开启或关闭时间戳对齐，并下载缺失资源。

模型默认保存在：

```text
~/Library/Application Support/Aural/Models
```

打开 DMG 后，把 `Aural.app` 拖到 Applications 即可。GitHub Releases 中公开下载的 v0.1.0 DMG 应在上传前完成 Developer ID 签名、Apple notarization、staple 和 Gatekeeper 验证；只有本地开发包或内部临时包可能因为 ad-hoc 签名而需要在 Finder 里右键选择“打开”。

安装、首次模型准备、磁盘清理和常见问题见 [docs/user-install-troubleshooting.md](docs/user-install-troubleshooting.md)。

## 兼容性

0.1.0 的本地转写链路面向 Apple Silicon Mac。

- 推荐：Apple Silicon Mac，macOS 14 或更新版本
- 暂不支持：Intel Mac
- 不需要独立显卡：Apple Silicon Mac 内置的 GPU / Metal 能力就是当前默认运行环境
- CPU-only 后端：后续单独评估，不混入 0.1.0 的默认链路

如果当前设备、系统版本或本地推理运行时不满足运行条件，Aural 会在启动时提示，不会等下载模型后才失败。

## 隐私

Aural 不会上传你的音视频和转写文本。

导入文件后，Aural 会在自己的本地目录中创建音频副本；删除任务时，会删除应用内记录、音频副本、转写结果和相关 sidecar 文件，但不会删除你的原始文件。

详细说明见 [docs/privacy.md](docs/privacy.md)。

## 从源码构建

要求：

- macOS 14 或更新版本
- Xcode Command Line Tools 或 Xcode
- Swift 6 兼容工具链

验证源码：

```bash
swift build
swift run aural-test
swift run aural-validate
scripts/audit-open-source.sh
```

构建一个不带 runtime / 模型的开发 App：

```bash
scripts/build-local-app.sh
```

构建公开发布包时，需要先把 MLX runtime wheel 固定到目标最低系统，再打包：

```bash
scripts/pin-mlx-runtime-platform.sh /path/to/asr-python-venv macosx_14_0_arm64
AURAL_RUNTIME_MIN_MACOS=14.0 \
AURAL_CODESIGN_REQUIRE_DEVELOPER_ID=1 \
AURAL_CODESIGN_IDENTITY="Developer ID Application: Example Name (TEAMID)" \
scripts/build-local-app.sh --include-runtime \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12
```

打包脚本会检查 Python wheel、Mach-O 二进制和 Metal library 的最低系统版本，避免在新 macOS 上误打出只能在新系统运行的 runtime。

构建 0.1.0 风格的轻量 Release App：内置 Python runtime，不内置模型，首次运行时下载模型资源。

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --require-developer-id \
  --codesign-identity "Developer ID Application: Example Name (TEAMID)" \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12
```

如果本次发布包含中文 ITN 规则，可以额外传入 `--itn-fst-source /path/to/custom-wetext-fsts`；如果缺少规则，worker 会保留原始 ASR 文本并记录 fallback metadata。

生成 DMG 并提交 Apple notarization：

```bash
scripts/package-local-dmg.sh
AURAL_NOTARYTOOL_PROFILE=AuralNotaryProfile \
scripts/notarize-release-dmg.sh .build/release/Aural-0.1.0-<timestamp>.dmg
```

如果你仍想构建完整离线包，也可以显式加入模型：

```bash
scripts/build-local-app.sh \
  --include-runtime \
  --include-model \
  --venv-source /path/to/asr-python-venv \
  --python-base-source /path/to/cpython-3.12 \
  --model-source /path/to/qwen3-asr-1.7b-4bit \
  --aligner-model-source /path/to/qwen3-forcedaligner-0.6b-4bit-mlx \
  --itn-fst-source /path/to/custom-wetext-fsts
```

## 仓库结构

```text
AuralASRWorker/        本地 ASR worker 和模型资源准备脚本
Resources/             App 图标资源
Sources/AuralCore/     任务存储、导入、队列、导出、worker 协议
Sources/AuralUIPrototype/
                       SwiftUI macOS App
scripts/               构建、验证、打包和发布脚本
docs/                  工程文档入口，见 docs/README.md
```

## 反馈

- Bug / 功能建议：请提 GitHub Issue
- 小红书：欢迎搜索 Aural 相关更新
- 邮箱：`maoliping455@users.noreply.github.com`

## License

Aural 源码使用 Apache-2.0 协议，见 [LICENSE](LICENSE)。

模型和第三方依赖有各自的许可证与使用限制，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
