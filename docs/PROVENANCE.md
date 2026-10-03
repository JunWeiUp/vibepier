# Provenance and asset sources / 项目与素材来源

VibePier derives from [ihavespoons/vibed](https://github.com/ihavespoons/vibed), Ben Gittins's MIT-licensed Ulanzi Vibe Key driver project. The original copyright and permission notice remain intact in [LICENSE](../LICENSE). [NOTICE](../NOTICE) records the new project's identity and broader contributions.

The consolidated initial commit is a new publication history, not a claim that the upstream work was newly authored here. Preserve the upstream notice in source and binary distributions. Do not copy private development history, machine configuration or personal conversation transcripts into the new repository.

## Material shipped here

| Material | Source / maintenance |
| --- | --- |
| AU05 protocol/driver lineage | Upstream MIT work and subsequent source changes; retain source notices. |
| Mac app, phone companion, provider adapters, relay | Source in this repository, distributed under its MIT license. |
| Brand vector/icon geometry | Original native generator and SVG under `scripts/dev` and `assets/brand`; see [DESIGN.md](../DESIGN.md). |
| README scene illustrations and editorial covers | AI-generated concept artwork; covers have exact prompts/tool provenance in [GENERATION-PROMPTS.md](../assets/GENERATION-PROMPTS.md). They are not screenshots. |
| Native phone UI previews | Original emulator captures of production widgets with synthetic data; [capture provenance](../assets/previews/README.md) identifies fixtures, scope and image hashes. |
| Task-icon fixture sheets | Rendered from production AppKit drawing code with synthetic states; provenance accompanies the [previews](../assets/brand/previews/task-icon-fixtures.txt). |
| Protocol samples and UI review data | Synthetic public test fixtures, not production keys or real conversations. |

Platform SDKs, system symbols/fonts and Android/Swift/Go build tooling retain their own terms. The Gradle wrapper is build tooling, not part of the application's product claims. The JVM-only JSON test dependency is not an APK runtime dependency.

BlackHole is an optional external audio driver; it is not bundled or relicensed by this repository. Provider applications, accounts and models are also external. VibePier is an independent community project and does not imply endorsement by Ulanzi, OpenAI, Anthropic, ZCode or their owners.

## 中文说明

项目基于 Ben Gittins 的 `ihavespoons/vibed` MIT 驱动工作发展而来。压成一个初始提交只改变新仓库历史，不改变原作者署名或许可；源码与分发包均保留 LICENSE、NOTICE。

品牌矢量与图标由仓库内原生生成器维护；README 插画和封面为 AI 生成的概念图，不能代表真实界面。测试密钥、对话和图标状态均为合成样本。BlackHole、平台工具和各桌面 AI 应用为独立外部项目，不打包其账户或模型，也不宣称官方关联。
