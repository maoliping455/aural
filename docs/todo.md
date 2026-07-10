# Aural TODO

## P1：0.2.0 支持中文 / 英文界面语言

状态：0.2.0 backlog。

目标：

- Aural 支持中文和英文两种界面语言。
- 首次启动默认按 macOS 系统语言选择：中文系统默认中文，其他语言默认英文。
- 用户可以在设置中手动修改界面语言。
- 手动选择后应持久保存，后续启动优先使用用户设置，而不是再次跟随系统语言。

验收标准：

- 中文系统首次启动显示中文界面。
- 英文或其他语言系统首次启动显示英文界面。
- 设置中可在中文 / English 之间切换。
- 重启 App 后保留用户选择。
- 语言切换不影响本地模型设置、任务队列、转写结果、导出和隐私说明。
- README、安装文档和隐私文档需要同步说明支持语言和默认选择规则。

## P1：0.2.0 支持自定义数据目录和目录迁移

状态：0.2.0 backlog。

目标：

- 用户可以在设置中选择 Aural 数据保存目录。
- Aural 的任务数据、导入后的音频副本、转写结果、alignment、导出 sidecar 和任务元数据可以保存到自定义目录。
- 支持把默认数据目录迁移到新目录，也支持从一个自定义目录迁移到另一个自定义目录。
- 目录迁移必须保留任务列表、任务状态、文件引用、转写结果、播放核对状态和导出能力。
- 模型缓存目录是否一起迁移需要单独决策；默认先不把模型缓存迁移混入任务数据目录迁移，避免大文件和下载状态复杂化。

验收标准：

- 设置中可以查看当前数据目录，并选择新的数据目录。
- 新导入任务会写入用户选择的数据目录。
- 迁移前必须提示目标目录、预计迁移内容、风险和磁盘空间需求。
- 迁移过程可失败恢复：失败后旧目录数据仍可用，不出现任务丢失。
- 迁移成功后，重启 App 仍能读取原有任务、转写结果和音频副本。
- 删除任务仍只删除 Aural 管理的数据，不删除用户原始导入文件。
- 隐私说明、安装与故障排查文档需要同步说明默认目录、自定义目录和迁移行为。

## P1：跟进 Cohere Transcribe / Parakeet unified 0.6B 模型评测

状态：待评测。该任务不是只看 WER / CER / leaderboard 分数，而是判断这些模型是否值得进入 Aural 的产品路线、开发者基准或外部对照组。当前默认本地路线仍以 Qwen3-ASR + 本地时间戳对齐为基线。

资料基线（2026-07-08）：

- Cohere Transcribe：官方模型名 `cohere-transcribe-03-2026`，2B ASR，支持 14 种语言，API 单文件上限 25 MB；官方说明不提供时间戳和说话人分离，且更适合预先指定单一语言。Aural 评测时应先作为云端/企业外部对照组，不默认进入本地离线主路径。
- NVIDIA `nvidia/parakeet-unified-en-0.6b`：英文 ASR，600M，Unified-FastConformer-RNNT，统一支持离线和流式推理，输出支持英文大小写和标点；官方集成路径主要是 NeMo，支持硬件/系统重点在 Linux + NVIDIA GPU。Aural 评测时应先作为英文和低延迟方向候选，不把它当作中文或 Apple Silicon 本地默认模型候选。

评测原则：

- 分数只是一项：保留 WER / CER / MER、专名命中率、数字/日期/金额/代码词错误率，但不得只凭总分排序。
- 必须评估产品适配：是否本地离线、是否需要 API key、是否会上传音频、是否有成本和速率限制、是否符合 Aural 的隐私承诺。
- 必须评估时间戳能力：是否原生输出段落/词级时间戳，是否能稳定接入当前 `alignment.json` / 播放高亮 / seek 预览链路；没有时间戳时，要记录 forced alignment 补救成本。
- 必须评估运行成本：RTF、峰值内存、模型/依赖体积、首次准备耗时、失败重试、离线复用、打包后 DMG 体积影响。
- 必须评估平台成本：Apple Silicon / macOS 14 路径是否可行，是否强依赖 Linux、CUDA、NeMo、服务端部署或厂商云。
- 必须评估语言和场景边界：中文、英文、中英混合、长音频、公开视频/讲座、会议口语、强口音、低频外文专名、噪声和音乐背景。
- 必须做人工复听抽查：对高分但体验差的情况单独记录，例如断句差、标点过度、重复漏句、幻听补全、专名替换、字幕阅读体验差。
- 必须评估集成复杂度：worker 协议改动量、资源准备逻辑、导出格式、错误提示、开源许可证、商业使用限制和维护风险。

第一阶段工作项：

- 建立 `docs/research/model_eval_cohere_parakeet.md`，记录模型信息、来源链接、许可、部署方式和适配结论。
- 在 ASR 评测集里选一组 Aural 产品相关样例：中文长讲座、英文讲座、中英混合、会议口语、强口音、专名密集、低音质视频抽音频。
- 对 Cohere Transcribe 跑 API 对照测试，单独记录上传/隐私/成本/25 MB 文件限制；如果文件必须切分，记录切分对文本连续性和时间戳补救的影响。
- 对 Parakeet unified 0.6B 先做可运行性验证：本地 macOS 是否可行；若不可行，记录 Linux/NVIDIA GPU 环境需求，不把不可复现分数混入 Aural 本地默认模型比较。
- 将两个模型与当前 Aural 默认链路对比：`Qwen3-ASR-1.7B 4bit`、可选 `Qwen3-ASR-1.7B bf16`、时间戳对齐开启/关闭。
- 输出产品结论：默认模型候选、外部质量上限参考、英文专项候选、流式专项候选、或暂不跟进，并说明原因。

验收标准：

- 有一份中文评测报告，结论包含“是否适合 Aural 默认本地转写路径”，而不只是分数表。
- 每个模型至少有质量、速度、内存/成本、时间戳、隐私、平台、集成复杂度、许可证/商业风险八个维度。
- 每个模型至少包含 3 个高价值人工复听案例，记录真实用户体验问题。
- 明确哪些结果可复现于本机 Apple Silicon，哪些只是云端/API/服务器环境对照。
- 如果建议进入产品路线，必须给出资源准备、失败回退、UI 暴露方式和开源发布边界。

## P3：ITN FST 与中文格式归一化优化

状态：低优先级优化，暂不排期。

当前结论：

- 0.1.0 不把缺失 ITN FST 作为发布阻塞项。
- 当前包缺少 `custom_wetext_fsts/zh/itn/tagger_no_standalone.fst`，`scripts/validate-itn-postprocess.py` 会失败。
- 主转写链路可以在 ITN 缺失时回退 raw/基础文本，不影响导入、转写、播放、导出和删除主流程。
- 影响范围主要是中文日期、手机号、数字、英文缩写等格式归一化质量。

后续若排期，需要补齐：

- FST 来源、许可证和是否适合开源分发。
- `--itn-fst-source` 打包路径和 release 构建说明。
- `scripts/validate-itn-postprocess.py` 回归通过。
- 缺失 FST 时的用户可见口径和 metadata 记录。
- 中文格式归一化样例集，例如日期、手机号、金额、英文缩写和中英混合。

## P2：开源发布前文档优化

状态：已完成第一轮 docs 结构整理，后续需要继续按 GitHub 公开发布标准打磨。

目标：

- 让新用户能快速理解 Aural 是什么、适合什么场景、当前限制是什么。
- 让开发者能从源码构建、理解架构、定位 worker 协议和 transcript schema。
- 让维护者能按 release checklist 重复构建、审计、打包和发布。
- 保持文档公开安全，不包含本机路径、私有实验素材、生成转写结果、模型权重或凭据。

后续方向：

- 检查 `README.md`、`docs/README.md`、`docs/architecture.md`、`docs/packaging.md`、`docs/release.md` 是否有重复、过时或互相冲突的说明。
- 为普通用户补充更直接的安装、首次模型准备、Gatekeeper 打开、卸载和模型缓存清理说明。
- 为开发者补充最小源码构建路径、常见失败原因、runtime / model 资源准备边界。
- 为贡献者补充 issue 模板、release 前文档检查清单、隐私和大文件提交注意事项。
- 在发布前统一中文/英文文档策略：面向用户的 README 优先中文，工程协议和 schema 可保留英文，但术语要稳定。

验收标准：

- GitHub 首页阅读路径清晰，用户不用先进源码就能知道是否适合安装。
- docs 入口能覆盖架构、隐私、打包、发布、worker 协议、transcript schema 和研究报告目录。
- `scripts/audit-open-source.sh` 通过，且 docs 中没有本机绝对路径、私有样例或生成物。
- release checklist 与实际脚本保持一致，不出现已经废弃的分包或模型内置默认路径描述。

## P3：接入 Qwen3-ForcedAligner 做时间戳精修

状态：第一版已接入 packaged segmented worker。技术调研和本地 4bit POC 已完成；当前作为 P3，后续重点是用更多真实长音频评估时间戳质量。0.1.0 会保留 aligner 能力，但模型权重通过首次启动资源准备进入本地缓存，不默认打进 DMG。

当前结论：

- 当前 `Qwen3-ASR-1.7B 4bit` 的本地 MLX 调用链路没有暴露可靠的词级时间戳接口。
- Aural 当前使用包内音频分段生成段落级 `start_sec` / `end_sec` / `text`。
- 播放时的蓝色文字推进效果已经优先读取 `alignment.json` 的字/词级时间；没有对齐数据或匹配失败时，才按当前段落时间范围做线性估算。
- `mlx-community/Qwen3-ForcedAligner-0.6B-4bit` 已从 ModelScope 下载并在本机跑通英文、中文 POC。
- packaged smoke 已验证新任务会生成 `alignment.json`，并写入 `metadata.timestamp_method = "qwen3_forced_aligner_paragraph"`。

第一阶段实现范围：

- 保持 Qwen3-ASR 负责文本转写。
- 增加本地 forced alignment 步骤，把每个音频 chunk 的 raw transcript 对齐回音频。
- 使用对齐 token 重建段落级 `start_sec` / `end_sec`，并在 UI 内用于正文播放高亮。
- 写入独立 `alignment.json`，并在 `transcript.json` metadata 中记录 `timestamp_method = "qwen3_forced_aligner_paragraph"`。
- 单个 alignment chunk 控制在 `120-180s`，硬上限 `300s`。
- 对齐失败时任务不失败，回退当前估算时间戳，并记录 `alignment.status = "error_fallback_estimated"`。
- 集成调研和本地 POC 先不随 0.1.0 开源发布；后续如公开，需要先清理本机路径和实验素材。

验收标准：

- 进度条 seek 后能定位到准确的文本区域。
- 播放过程中当前文本高亮与音频听感基本同步。
- 整体仍保持本地处理，不向用户暴露模型和复杂配置。
- 完成首次模型准备后，离线状态下可完成转写和对齐。
- 人为删除或损坏 aligner 模型时，任务仍可完成并回退估算时间戳。

## P3：词级/字级播放高亮

状态：第一版已接入 UI。正文播放高亮优先使用 `alignment.json` 的字/词级时间，边界按标点单元控制；进度条 hover 仍保持整段开头预览，避免过碎。

后续方向：

- 中文优先评估字级高亮，英文优先评估词级高亮。
- 继续完善 raw transcript 与 ITN 后 normalized transcript 的 span mapping，降低匹配失败回退比例。
- 对中英混合、日期、金额、手机号、专有名词做回归测试。
- 控制长文本高亮渲染成本，避免一次性渲染全量字级 token。

## P3：本地视频 OCR 上下文增强 ASR

状态：暂停集成。当前产品包不包含 OCR 代码、OCR 依赖或 OCR 模型；后续只作为独立 POC 重新评估。

产品判断：

- 对课堂、讲座、公开视频，画面/PPT/字幕中经常已经出现专名和术语。
- audio-only ASR 对重口音和低频外文专名很难稳定识别，例如 `Kodaira`、`Iyanaga`。
- 第一阶段不需要 LLM。轻量 OCR 加规则术语抽取已经能提供有价值的 `context_terms`。
- OCR context 结果必须和 audio-only zero-shot 分开评估，不能混入模型裸能力排行。

第一阶段方向：

- 在独立 POC 中评估本地轻量 OCR，例如 RapidOCR / PP-OCR ONNX。
- 视频输入时抽帧，做去重后 OCR。
- 只抽取高价值短术语：拉丁词、大写缩写、中英混合词、日文片假名、少量高置信中文专名。
- 不把 OCR 全文传给 ASR，不让模型根据画面补全音频没说的话。
- 将最终术语通过 Qwen3-ASR `system_prompt` 注入，并在 `transcript.json` metadata 中记录。
- OCR 失败时不影响正常 ASR。

资源目标：

- 不影响当前 Aural 包体。
- 如果重新集成，新增磁盘小于 300 MB。
- 新增短时内存小于 1 GB。
- 默认不强依赖 GPU。
- OCR 在 ASR 前运行并释放，避免和 ASR 模型内存峰值叠加。

验收标准：

- 当前产品路径不包含 OCR；视频任务只抽音频转写。
- 重新集成前，需要先证明术语收益稳定且误注入可控。
- 丘成桐样例中，能从视频页 OCR 提取 `Kodaira`、`Iyanaga`、`Seiko` 等术语。
- 注入术语后，Qwen3-ASR 4bit 对关键专名明显优于 audio-only。
- 普通纯音频任务不会触发 OCR。
- POC 阶段将 OCR 结果、候选术语、最终注入术语写入 sidecar，便于调试。

技术方案先不随 0.1.0 开源发布；后续如公开，需要先清理本机路径、样例素材和实验结论边界。

## P1：0.2.0 支持 `aural-cli` 与智能体 Skill

状态：0.2.0 backlog。

产品判断：

- Aural 本体继续聚焦本地音视频转写、播放定位、转写结果管理和导出。
- `aural-cli` 提供稳定的数据访问和操作边界，让脚本、Agent 和自动化工具可以操作音视频任务与转写结果。
- 总结、纪要、行动项、改写等属于 LLM 后处理，优先以智能体 Skill 形式实现，不直接塞进 App 主流程。
- Skill 通过 `aural-cli` 读取 Aural artifact，再由智能体使用配套 LLM 能力完成总结，并把结果保存为 sidecar 或用户指定输出。

目标：

- 提供 `aural-cli`，支持列出任务、查看任务状态、读取转写文本、读取带时间戳段落、导出字幕/文本。
- 支持通过 CLI 对音视频任务做基本操作，例如导入文件、触发转写、停止/重试、删除 Aural 管理的任务数据。
- 定义稳定的 transcript / alignment / metadata artifact 读取格式，供外部 Agent 使用。
- 提供 Aural Skill：获取转写内容，生成总结、纪要、行动项或自定义摘要。
- Skill 需要明确隐私边界：Aural 仍本地处理音视频；总结是否调用云端 LLM 由用户选择的智能体环境决定。

验收标准：

- `aural-cli list` 能列出本地任务及状态。
- `aural-cli transcript <task>` 能读取转写文本和带时间戳段落。
- `aural-cli export <task>` 能导出 SRT、纯文本和带时间戳文本。
- `aural-cli import <media>` 能把音频/视频加入 Aural 管理目录，并可触发本地转写。
- Aural Skill 能通过 CLI 读取一个任务并生成总结文件。
- CLI 和 Skill 不绕过 Aural 的本地数据边界，不上传音视频；如总结步骤使用外部 LLM，必须在 Skill 文档中明确说明。
- README、开发者文档和隐私文档同步说明 CLI / Skill 的能力边界。

## P3：安装包体积优化

状态：0.1.0 已改为轻量 Release 包。App 内置 runtime，不内置 ASR / aligner 模型；首次启动检查 `~/Library/Application Support/Aural/Models`，缺失时先进入本地模型准备流程。当前支持“极速 / 平衡 / 精准”三档本地转写模式，默认推荐“平衡 + 字幕时间戳对齐”；精准模式需要 16GB 及以上内存。字幕时间戳对齐作为独立可选资源，初次准备和后续本地转写设置里都可以开启或关闭。下载完成前不允许使用主功能。

旧完整包体分布（2026-07-05，`/Applications/Aural.app`）：

- 总体约 `3.9G`。
- `asr-models/qwen3-asr-1.7b-4bit` 约 `1.5G`。
- `asr-models/qwen3-asr-1.7b-bf16` 约 `3.8G`，当前仅作为精准模式首启下载资源，不打进默认 DMG。
- `runtime` 约 `1.5G`，其中较大依赖包括 `torch`、`mlx`、`llvmlite`、`pyarrow`、`sherpa_onnx`、`scipy`。
- `aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx` 约 `931M`。
- App 可执行文件、图标、ITN 规则和 worker 脚本占用很小。
- OCR 代码和 OCR 依赖已从当前产品包移除。

当前轻量包体实测（2026-07-06，本地 ad-hoc build）：

- `Aural.app` 约 `603M`。
- 本地验证 DMG 约 `288M`。
- `runtime` 约 `589M`。
- `asr-models` 和 `aligner-models` 不进入 DMG，仅保留空目录。

已完成：

- 模型资源准备脚本 `model_resource_prepare.py`。
- ModelScope 优先、Hugging Face 兜底。
- 下载完成写 `.aural-complete.json`，升级后复用缓存。
- App 启动时强制检查资源，缺失时展示准备页，用户点击后开始下载，下载成功前不启动转写队列。
- 准备页显示整体百分比进度，失败重试时复用已下载部分。
- Intel / 非 Apple Silicon 当前直接提示不支持，避免下载后失败。
- 打包脚本清理 `torch`、`pyarrow`、`pandas`、`sklearn`、`sherpa_onnx`、`llvmlite` 等当前运行链路不需要的依赖。

后续方向：

- 构建更干净的 Aural 专用 Python runtime，不再从开发 venv 裁剪。
- 进一步验证 runtime 依赖裁剪不会影响真实下载、转写、ITN 和 aligner。
- Intel Mac / CPU-only 后端单独评估，避免和 MLX 默认链路混在一起。
- 对 runtime 做自动瘦身校验：打包后检查不应出现 OCR、数据分析、下载器等非产品路径依赖。
- 记录瘦身前后包体、启动速度、转写速度和离线可用性的变化。

验收标准：

- 首次联网下载后，不降低默认本地转写能力。
- 不向用户暴露模型或 runtime 复杂配置。
- GitHub Release 默认不需要拆分 DMG。
- 包体明显低于旧完整包 `3.9G`，并有可复现的体积分布报告。

## P3：兼容性与 CPU 后端

状态：0.1.0 先明确支持 Apple Silicon Mac + macOS 14 或更新版本；启动时会先检查 macOS 版本、CPU 架构和 MLX runtime 是否能加载，不满足条件时直接提示，不进入模型下载。

当前决策：

- Apple Silicon Mac 不需要独立显卡，使用芯片内置 GPU / Metal 能力作为默认本地推理环境。
- Intel Mac 暂不支持，避免用户下载大模型后才发现 MLX 默认链路不可用。
- CPU-only 后端不混入 0.1.0 默认链路；后续需要单独评估模型格式、运行时、速度、内存和包体。
- 发布包 runtime 必须使用目标最低系统兼容的 MLX wheel；打包时会审计 Python wheel tag、Mach-O `minos` 和 Metal library 版本，避免从新系统打出只能在新系统运行的包。

后续方向：

- 调研 Intel Mac 上可接受的 CPU ASR 后端，例如 whisper.cpp / Core ML / ONNX Runtime / CTranslate2。
- 明确 CPU 后端是否继续支持 Qwen3-ASR，或作为较低质量但可用的 fallback。
- 设计运行时能力检测：芯片架构、macOS 版本、Metal 可用性、内存阈值、模型缓存完整性。
- 如果支持多后端，仍保持 UI 极简，不让用户在主流程选择模型和参数。
