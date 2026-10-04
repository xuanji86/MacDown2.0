<p align="right"><a href="README.md">English</a> · <b>简体中文</b></p>

<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="MacDown2.0 应用图标">
</p>

<h1 align="center">MacDown2.0</h1>

<p align="center"><strong>Markdown，回归 Mac 原生。从零重写。</strong></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-1a73e8?style=flat-square" alt="许可：GPL-3.0"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-000000?style=flat-square" alt="Apple Silicon 与 Intel">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
</p>

<p align="center">
  <img src="docs/images/screenshot.png" width="100%" alt="MacDown2.0 正在编辑一份 Quarto 文档：左边是深色编辑区里的 Markdown 源码，右边是实时预览，含 callout、表格、Swift 代码高亮和 KaTeX 公式">
</p>

<p align="center"><sub>默认外观：编辑区深色，预览浅色。图中是一份 <code>.qmd</code>，callout、GFM 表格、Swift 高亮与 KaTeX 公式都在实时渲染。</sub></p>

## 为什么是 MacDown2.0

十多年前，Mou（Chen Luo）定下了 Mac 上写 Markdown 的样子：左边写源码，右边看预览，中间什么都不挡。MacDown（Tzu-ping Chung）把这个样子以开源的方式延续下来，成了一代 Mac 用户顺手就打开的那个 Markdown 编辑器。MacDown2.0 是它们的精神续作——同样的两栏，同样的快捷键肌肉记忆，同样不做所见即所得，也不想变成笔记应用。

它同时也是一次彻底的告别。没有移植任何旧代码：MacDown2.0 从一个空文件开始，用 Swift 6 和 SwiftUI 写成，只面向 macOS 26（Apple Silicon 与 Intel），底下是 Liquid Glass、TextKit 2、tree-sitter 和 markdown-it。没有兼容层，没有从上个十年留下来的框架，只有一个 Markdown 编辑器在今天的 Mac 上本该有的手感。

留下来的，是真正重要的那部分：深色编辑区旁边一页白纸，手指早已记住的快捷键，以及克制——它始终只是一个 Markdown 编辑器。

## 亮点

| | |
|:--|:--|
| **编辑** | TextKit 2 加 tree-sitter 增量语法高亮。格式工具栏和快捷键与 MacDown 一致：⌘B / ⌘I / ⌘U，⌘1–⌘6 标题，⌘K 行内代码，⇧⌘K 链接，⇧⌘B 引用，⌘/ 注释。自动配对、列表续写、Tab 缩进。中文输入法组字时不会被打断。 |
| **预览** | markdown-it 渲染，只更新改动过的块：50KB 文档单次按键 9–16ms，1MB 文档一次 patch 约 20ms。编辑区与预览双向滚动同步。 |
| **语法** | GFM 表格与删除线、任务列表、脚注、`==高亮==`、`H~2~O` 下标与 `x^2^` 上标、`[TOC]`、front matter。强调对中文友好：`**「重点」**的` 也能正确加粗。 |
| **公式与代码** | KaTeX 支持 `$$…$$`、`\[…\]`、`\(…\)`，行内 `$…$` 可选开启。代码块由 highlight.js 高亮。 |
| **主题** | 编辑器 6 套、预览 8 套，各自独立选择；也可以都跟随系统深浅色。 |
| **导出** | 单文件 HTML（可内嵌图片）、按纸张分页的 PDF、打印、复制为 HTML。 |
| **Quick Look** | 在 Finder 里按空格，直接看到渲染后的效果。 |
| **Quarto** | `.qmd` 支持以内置扩展的形式提供，默认开启。近似预览 callout、`:::` 分块、交叉引用、文献引用、shortcode 和 `{{< include >}}`；代码单元只高亮，不执行。 |
| **还有** | 设置窗口、文档大纲、状态栏（行列号与字数，中文按字计数），以及 Sparkle 自动更新——等正式发版后启用。 |

## 安装

MacDown2.0 还没有发布正式版本。发版后将提供两种方式：

```sh
brew install --cask xuanji86/tap/macdown2    # 即将推出
```

或从 [GitHub Releases](https://github.com/xuanji86/MacDown2.0/releases) 下载 `.dmg`。

应用只做了 ad-hoc 签名、未经公证，而 Homebrew 官方的 `homebrew/cask` 不收未公证的应用，所以用项目自己的 tap，它安装后会顺便清掉隔离标记。手动下载的话，第一次打开 macOS 会拒绝：到「系统设置 › 隐私与安全性」里点「仍要打开」即可，之后的更新由 Sparkle 接手。

在首个版本发布之前，可以自己构建，一条命令的事。

## 从源码构建

需要 macOS 26（Apple Silicon 或 Intel）和 Xcode 27。只有在修改 `Web/` 下的 JavaScript 渲染器时才需要 Node.js 23.6+。

```sh
git clone https://github.com/xuanji86/MacDown2.0.git
cd MacDown2.0
make test    # JS 测试、资源漂移与模块边界检查、Swift 包测试
make app     # Debug 构建 → build/DerivedData/Build/Products/Debug/MacDown2.app
make web     # 仅在改过 Web/ 之后：重新生成已提交的 web 资源
```

## 路线图

**进行中**

- 文件树侧栏（浏览模式 + 工作区模式）与窗口内标签

**计划中**

- 在预览区直接做文字级编辑，选区在两栏之间双向跟随
- 调用本机安装的 `quarto` 做真正的 Quarto 渲染
- 本地语义搜索，作为基于 [tobi/qmd](https://github.com/tobi/qmd) 的扩展
- 命令行工具 `macdown2 .`
- Mermaid 图表
- 1.0

## 无隶属关系声明

MacDown2.0 是一个独立项目，与 [MacDown](https://github.com/MacDownApp/macdown) 和 [MacDown 3000](https://github.com/schuyler/macdown3000) 没有隶属关系，没有得到它们的认可，也不是它们的延续；没有使用它们的任何代码。「精神续作」说的是理念与使用体验上的传承，而不是官方意义上的继任。

## 致谢

- Mou 与 [MacDown](https://macdown.uranusjr.com)，定义了这件事该有的样子
- [MacDown 3000](https://github.com/schuyler/macdown3000)，我们的渲染快照测试使用了它的测试文档（MIT）
- Dustin Curtis 的 [Markdown Mark](https://github.com/dcurtis/markdown-mark)（CC0）；图标中的 M↓ 字形按其网格重绘
- [markdown-it](https://github.com/markdown-it/markdown-it) 与 [@mdit](https://mdit-plugins.github.io) 插件、[KaTeX](https://katex.org)、[highlight.js](https://highlightjs.org)
- [tree-sitter](https://tree-sitter.github.io) 与 [tree-sitter-markdown](https://github.com/tree-sitter-grammars/tree-sitter-markdown)；ChimeHQ 的 [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) 与 [Neon](https://github.com/ChimeHQ/Neon)
- [Sparkle](https://sparkle-project.org)
- [quarto-dev/quarto](https://github.com/quarto-dev/quarto) 的 markdown-it 插件

完整许可文本随 App 附带，见 `THIRD_PARTY_LICENSES.txt`。

## 许可

[GPL-3.0](LICENSE)。每个发布版本都附带构建它时所用的完整源码。
