# Aural TODO

## P3：接入 Qwen3-ForcedAligner 做时间戳精修

状态：第一版已接入 packaged segmented worker。技术调研和本地 4bit POC 已完成；当前作为 P3，后续重点是用更多真实长音频评估时间戳质量，并决定是否继续默认内置 aligner。

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
- 离线状态下可完成转写和对齐，不发生运行时模型下载。
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

## P2：总结能力与智能体 Skill

状态：先记录方向，当前 App 不内置总结。

产品判断：

- Aural 本体继续聚焦本地音视频转写、播放定位、转写结果管理和导出。
- 总结、纪要、行动项、改写等属于 LLM 后处理，先不放进 App 主流程，避免引入模型选择、联网隐私、长文本分块、失败重试和成本解释。
- 后续提供稳定的数据访问边界，让智能体 Skill 读取 Aural 的任务和转写文本，再由智能体使用配套 LLM 能力完成总结。

后续方向：

- 设计 `auralctl` 或等价本地接口，支持列出任务、读取转写文本、读取带时间戳段落、导出结果。
- 设计 Aural Skill：获取转写内容，生成总结、纪要、行动项，并把结果保存为 sidecar 文件。
- App 可以在更后续版本展示已生成的总结文件，但不直接承担 LLM 推理。
- 在 Skill 成型前，App 先提供“导出转写”能力，用户可以把结果交给任何 AI 工具继续处理。

## P3：安装包体积优化

状态：先记录，当前不优先处理。

当前包体分布（2026-07-05，`/Applications/Aural.app`）：

- 总体约 `3.9G`。
- `asr-models/qwen3-asr-1.7b-4bit` 约 `1.5G`。
- `runtime` 约 `1.5G`，其中较大依赖包括 `torch`、`mlx`、`llvmlite`、`pyarrow`、`sherpa_onnx`、`scipy`。
- `aligner-models/qwen3-forcedaligner-0.6b-4bit-mlx` 约 `931M`。
- App 可执行文件、图标、ITN 规则和 worker 脚本占用很小。
- OCR 代码和 OCR 依赖已从当前产品包移除。

后续方向：

- 构建 Aural 专用 Python runtime，只保留实际运行需要的依赖，避免复制完整开发 venv。
- 评估 `torch`、`pyarrow`、`pandas`、`sklearn`、`sherpa_onnx`、`llvmlite` 等是否仍被当前 packaged worker 需要。
- 评估 forced aligner 是否默认内置，或改成可选组件/首次本地安装资源。
- 对 runtime 做自动瘦身校验：打包后检查不应出现 OCR、数据分析、下载器等非产品路径依赖。
- 记录瘦身前后包体、启动速度、转写速度和离线可用性的变化。

验收标准：

- 不降低默认离线转写能力。
- 不向用户暴露模型或 runtime 复杂配置。
- 包体明显低于当前 `3.9G`，并有可复现的体积分布报告。
