# Third-Party Licenses

Pomvox is MIT-licensed (see [LICENSE](LICENSE)). It builds on the open-source
work below. This file lists the third-party components Pomvox depends on, their
versions, and their licenses.

Versions reflect the pins in the committed `Package.resolved` (native app) and
`uv.lock` / `pyproject.toml` (Python reference engine) at the time of writing;
the resolved manifests are the source of truth if they drift.

---

## Native app — Swift Package Manager

These packages are resolved and linked into `Pomvox.app`.

### Direct dependencies

| Package | Version | License | Source |
| --- | --- | --- | --- |
| FluidAudio | 0.15.4 | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| mlx-swift-lm | 3.31.4 | MIT | https://github.com/ml-explore/mlx-swift-lm |
| swift-huggingface-mlx | 0.2.0 | Apache-2.0 | https://github.com/DePasqualeOrg/swift-huggingface-mlx |
| swift-tokenizers-mlx | 0.3.0 | Apache-2.0 | https://github.com/DePasqualeOrg/swift-tokenizers-mlx |
| swift-tokenizers | 0.5.0 | Apache-2.0 | https://github.com/DePasqualeOrg/swift-tokenizers |
| Sparkle | 2.9.4+ | MIT | https://github.com/sparkle-project/Sparkle |

### Transitive dependencies

| Package | Version | License | Source |
| --- | --- | --- | --- |
| mlx-swift | 0.31.4 | MIT | https://github.com/ml-explore/mlx-swift |
| EventSource | 1.4.1 | MIT | https://github.com/mattt/EventSource |
| swift-huggingface | 0.9.0 | Apache-2.0 | https://github.com/huggingface/swift-huggingface |
| swift-asn1 | 1.7.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| swift-atomics | 1.3.1 | Apache-2.0 | https://github.com/apple/swift-atomics |
| swift-collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.0 | Apache-2.0 | https://github.com/apple/swift-crypto |
| swift-nio | 2.101.2 | Apache-2.0 | https://github.com/apple/swift-nio |
| swift-numerics | 1.1.1 | Apache-2.0 | https://github.com/apple/swift-numerics |
| swift-syntax | 603.0.2 | Apache-2.0 (with Runtime Library Exception) | https://github.com/swiftlang/swift-syntax |
| swift-system | 1.7.2 | Apache-2.0 | https://github.com/apple/swift-system |

---

## Python reference engine

These packages back the frozen Python reference engine (`src/pomvox/`). They are
**not** bundled in `Pomvox.app` — they're only installed when you run the Python
engine or the spec suite via `uv`. macOS-only dependencies are marked.

| Package | License | Source | Notes |
| --- | --- | --- | --- |
| parakeet-mlx | Apache-2.0 | https://pypi.org/project/parakeet-mlx/ | macOS only |
| mlx-lm | MIT | https://github.com/ml-explore/mlx-lm | macOS only |
| sounddevice | MIT | https://github.com/spatialaudio/python-sounddevice | macOS only |
| webrtcvad-wheels | MIT | https://pypi.org/project/webrtcvad-wheels/ | macOS only |
| pyobjc (Quartz, Cocoa, AVFoundation, ApplicationServices) | MIT | https://github.com/ronaldoussoren/pyobjc | macOS only |
| rumps | BSD-3-Clause | https://github.com/jaredks/rumps | macOS only |
| pytest | MIT | https://github.com/pytest-dev/pytest | dev/test |
| hatchling | MIT | https://github.com/pypa/hatch | build backend |

---

## Models (downloaded at runtime)

Pomvox downloads its speech and cleanup models from Hugging Face on first use;
they are not redistributed in this repository or the app bundle. Each model
carries its own license on its Hugging Face model card — review the card for the
specific model you configure. Defaults at the time of writing:

- **Speech-to-text:** `parakeet-tdt-0.6b-v2` (NVIDIA Parakeet family; the optional
  multilingual `parakeet-tdt-0.6b-v3` is the same family/license), via FluidAudio.
- **Cleanup LLM:** a small instruction-tuned model run locally via mlx-swift; see
  `config.example.toml` for the default and how to swap it.

---

## Regenerating this file

- **Native app:** the dependency set and versions come from
  `Pomvox/Pomvox.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
  License identifiers were taken from each project's `LICENSE` file (GitHub's
  reported SPDX id).
- **Python:** the dependency set comes from `pyproject.toml` / `uv.lock`; license
  identifiers from each project's PyPI metadata.

If you bump a dependency, update the version here (and re-check its license if
the project relicensed).
