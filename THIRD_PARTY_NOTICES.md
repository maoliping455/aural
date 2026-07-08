# Third-Party Notices

This file summarizes the major third-party components used by Aural source and release builds. It is not a substitute for the upstream license files. Before publishing a bundled release, regenerate dependency notices from the exact runtime environment used for that release.

## Source Dependencies

| Component | Purpose | Upstream |
| --- | --- | --- |
| Swift Argument Parser | CLI argument parsing for validation tools | https://github.com/apple/swift-argument-parser |
| Python | Bundled runtime for release builds with local ASR | https://www.python.org/ |
| MLX | Apple Silicon tensor runtime | https://github.com/ml-explore/mlx |
| mlx-audio | Local Qwen ASR model execution path | https://github.com/Blaizzy/mlx-audio |
| NumPy / SciPy / soundfile | Audio loading and segmentation helpers | https://numpy.org/ / https://scipy.org/ / https://python-soundfile.readthedocs.io/ |
| silero-vad | Optional speech activity detection dependency | https://github.com/snakers4/silero-vad |
| WeTextProcessing / kaldifst | Optional ITN post-processing rules/runtime | https://github.com/wenet-e2e/WeTextProcessing |

## Model Dependencies

The Git repository does not include model weights. The default 0.1.0 Release DMG also does not bundle model weights; the app downloads them into the local Application Support model cache on first launch when missing. Full offline development builds may bundle:

| Model | Purpose | Notes |
| --- | --- | --- |
| Qwen3-ASR-0.6B / 1.7B MLX conversions | Local ASR model resources for fast, balanced, and accurate modes | Review the upstream model cards and conversion licenses before release. |
| Qwen3-ForcedAligner-0.6B, 4-bit MLX conversion | Optional local timestamp refinement | Review the upstream model card and conversion license before release. |

Recommended model sources should be recorded in each release note, including exact model IDs, conversion repos, checksums, and local build inputs.

## Runtime License Inventory

For a release bundle, generate a package-level Python dependency inventory from the runtime venv:

```bash
python -m pip install pip-licenses
pip-licenses --format=markdown --with-urls --with-license-file > THIRD_PARTY_PYTHON_LICENSES.md
```

Attach the generated inventory to the GitHub Release together with this file.

## Optional Components

The 0.1.0 default release path does not bundle OCR dependencies or OCR models.

The optional ffmpeg development path is not part of the default release package. If a future release bundles ffmpeg or related native libraries, add the exact build, license, and redistribution details here before publishing.
