# MacDown2.0 技术方案

> 版本:2026-10-03 初稿 · 面向"一名熟练开发者 + AI 辅助"直接开工。
> 文中 `⚠未验证` = 查了但没拿到一手确证的点,开工前在对应 spike 里补证。
> 已拍板、不再讨论的前提:全新项目(非 fork)、Swift 6 零 ObjC、最低 macOS 26、仅 Apple Silicon、左源码右预览分栏、Developer ID + 公证 + Sparkle 2 + GitHub Releases 分发、**渲染核心 = markdown-it(方案 B)**、**项目许可 AGPL-3.0**。

---

## 0. 一页速览

| 维度 | 结论 |
|---|---|
| 语言/工具链 | Swift 6 语言模式(严格并发),Xcode 27(本机 macOS 27.2;Xcode 27 于 2026-09-14 发布,带 Swift 6.4),deployment target macOS 26,arm64 only。零 ObjC、零 Rust。 |
| App 骨架 | SwiftUI App 生命周期 + `DocumentGroup` + `ReferenceFileDocument`;`Settings` 场景;`@Observable` 模型。 |
| 编辑器 | TextKit 2 `NSTextView` 经 `NSViewRepresentable` 包进 SwiftUI(**唯一** AppKit UI 组件)。语法高亮 = tree-sitter-markdown(block+inline 双语法)经 ChimeHQ `SwiftTreeSitter` + `Neon` 增量高亮。 |
| 渲染核心 | **markdown-it 15**(+ 插件)打成单文件 JS bundle(esbuild,产物 vendor 进仓)。预览在 WebView 内渲染 + 块级 DOM patch;Quick Look / CLI / 导出 / 测试用系统 **JavaScriptCore** 跑同一份 bundle 出静态 HTML。 |
| 预览 | SwiftUI `WebView` + `WebPage`(macOS 26 WebKit for SwiftUI);`URLSchemeHandler` 加载文档旁相对图片;`data-line` 驱动双向滚动同步;KaTeX 在渲染期静态输出,Mermaid 按需懒加载。 |
| 代码高亮 | highlight.js 11(class 输出 + CSS 主题,同步、无 DOM、JSC 可跑)。Shiki 作为可替换升级路径。 |
| 扩展机制 | Quarto 与 qmd 搜索做成**内置可选扩展**(Obsidian "核心插件"式:随 App 编译签名,只能开/关,不支持第三方/下载插件)。核心只定义 `MacDown2Extension` / `DocumentFlavor` / `SearchProvider` 三个接缝;每个扩展一个 SPM 模块,只有 App target 注册;关闭 = 零开销(不探测、不读环境、不加载 JS chunk、不起进程、无 UI)。见 §4.17。 |
| Quarto `.qmd` | `QuartoExtension`,**默认开**。两档:近似预览(markdown-it + 复用 quarto-dev/quarto 的 markdown-it 插件,拆成独立 `quarto.chunk.js` 按需加载;代码单元只高亮不执行);真渲染(扩展内子开关,默认开;用户显式切换后起 `quarto preview --no-browser`,预览栏显示其输出)。扩展关闭时 `.qmd` 按普通 Markdown 打开。 |
| 本地搜索 | 核心内置全文搜索始终可用;`QmdSearchExtension`(tobi/qmd,**默认关**)启用后调其 **CLI**(`--format json`)做关键词/语义搜索,注册 collection 前征得用户同意。关闭时界面无任何 qmd 字样。 |
| 分发 | Developer ID 签名 + hardened runtime + 公证 + staple → DMG → Sparkle 2(SPM,EdDSA)appcast 挂 GitHub Release。不上 App Store、不强制沙盒(QL 扩展除外,扩展必须沙盒)。 |
| 测试 | Swift Testing(含经 JSC 跑的渲染快照测试,语料取自 macdown3000 Fixtures)+ `node --test` 测 JS 纯函数 + XCTest `measure` 性能基准 + 少量 XCUITest。 |
| 许可 | **AGPL-3.0**;README 声明与 MacDown / MacDown 3000 无隶属关系;Mou 来源 CSS 不复用。 |

---

## 1. 目标 / 非目标

### 1.1 目标

1. 一个在 macOS 26+ 上**原生、轻快、现代**的 Markdown 分栏编辑器:左源码(语法高亮、自动配对、列表续写、查找替换)右实时预览(双向滚动同步、相对图片、公式、图表、任务列表可点)。
2. 严格 CommonMark + GFM 语义,Hoedown 时代的常用非标准语法(`==mark==`、`^sup^`、`~sub~`、脚注、智能引号、`[TOC]`、front matter)以**可开关扩展**形式保留。
3. 同一渲染 bundle 服务四个出口:App 预览、Quick Look、CLI、HTML/PDF 导出——所见即所导。
4. Quarto `.qmd` 支持作为**内置可选扩展**(默认开):近似预览零依赖;本机有 Quarto 时一键真渲染(子开关)。
5. 文件夹工作区 + 本地搜索(内置全文始终可用;tobi/qmd 关键词/语义搜索为内置可选扩展,默认关)。
6. 用最新平台能力:Liquid Glass、Icon Composer 图标、WebKit for SwiftUI、TextKit 2、Swift 6 严格并发。
7. 可持续发版:一条 `git tag` 到用户收到 Sparkle 更新全自动。

### 1.2 非目标(明确砍掉的 MacDown 历史功能及理由)

| 砍掉项 | 理由 |
|---|---|
| Intel / 旧 macOS 支持 | macOS 27 已不支持 Intel;最低 macOS 26 是前提。 |
| MathJax 2 | 2017 年代码、需 eval、慢、CDN 依赖。KaTeX `renderToString` 渲染期静态输出,无运行时依赖,QL/导出同样可用。MathJax 特有宏(如 `\require`)不兼容,文档里说明。 |
| Graphviz(viz.js) | ~2MB wasm 只服务极少用户;Mermaid 12 的 flowchart/graph 覆盖主要场景。 |
| Hoedown `quote` 扩展(`"x"` → `<q>`) | CommonMark 无对应、markdown-it 无成熟插件、实际使用罕见。 |
| "Intra-word emphasis" 开关 | CommonMark 已定义(`*` 词内生效、`_` 词内不生效),不再做 Hoedown 式开关。 |
| peg-markdown-highlight `.style` 编辑器主题格式 / Mou 来源主题 | 授权来源不清(Mou),格式绑定 PEG 高亮器。重新设计 JSON 主题格式,内置主题全部重写。 |
| 自定义 Handlebars HTML 模板 | 用户几乎不用;导出改为固定模板 + 用户 CSS 注入。 |
| AppleScript(`MacDown.sdef`) | 使用率低、维护成本高、SwiftUI 生命周期下实现别扭。URL scheme(`macdown2://`)覆盖自动化需求。 |
| Homebrew 检测 / Terminal 偏好页的 brew 逻辑 | 只保留"安装命令行工具"一个按钮。 |
| PDF 内部锚点注入(`MPPDFAnchorInjector`) | WebKit 打印输出的 PDF 内链靠 WebKit 自己;不再手工后处理。 |
| 多语言本地化(首发) | M3 只做 zh-Hans + en;其余社区贡献。 |
| 所见即所得模式 | 形态已定为分栏。 |

---

## 2. 总体架构

### 2.1 模块图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ MacDown2.app (SwiftUI App, @main)                                           │
│                                                                             │
│  DocumentGroup<MarkdownDocument>                     Settings 场景(含「扩展」页)│
│   └─ DocumentWindow (NavigationSplitView)            SparkleUpdater         │
│       ├─ WorkspaceSidebar  ── SearchPanel ──► SearchService(actor)          │
│       │                                        ├─ BuiltinSearchBackend(核心)│
│       │                                        └─ [SearchProvider 由扩展注册]│
│       ├─ EditorPane  ── MarkdownTextView(NSViewRepresentable, TextKit 2)    │
│       │                  ├─ Highlighter (Neon + SwiftTreeSitter + 语法)     │
│       │                  ├─ EditingAssistant (配对/续写/缩进)               │
│       │                  └─ LineTable (行号↔UTF-16 偏移)                     │
│       ├─ PreviewPane ── WebView(WebPage)                                    │
│       │                  ├─ PreviewBridge (callJavaScript / message handler)│
│       │                  ├─ ScrollSyncController (纯函数 + 状态机)           │
│       │                  └─ [AlternatePreviewMode 由扩展提供,如 Quarto 真渲染]│
│       ├─ OutlineInspector (.inspector)                                      │
│       └─ StatusBar (行:列 / 字数 / 渲染模式)                                 │
│                                                                             │
│  ExtensionRegistry ── 唯一注册点:[QuartoExtension(默认开), QmdSearchExtension(默认关)]│
│  LoginShellEnvironment ── 首次需要时经 `$SHELL -l -c 'env -0'` 抓一次登录 shell│
│                           环境;只有已启用的扩展会触发它,核心功能从不调用     │
│                                                                             │
│  Packages (SPM, 本仓 local):                                                │
│   MarkdownCore ── protocol MarkdownRenderer; JSCRenderer(JavaScriptCore)    │
│   EditorKit    ── TextKit 2 文本视图、高亮、编辑辅助(可单测)                 │
│   PreviewKit   ── 滚动同步算法、块映射、bridge 协议(纯 Swift,可单测)        │
│   WebAssets    ── render.bundle.js / preview.bundle.js / quarto.chunk.js /  │
│                   mermaid.chunk.js / flavors.json / css / katex             │
│   ExtensionAPI ── MacDown2Extension / DocumentFlavor / SearchProvider 协议  │
│   QuartoExtension, QmdSearchExtension ── 内置扩展(只依赖 ExtensionAPI+Core)│
└─────────────────────────────────────────────────────────────────────────────┘
          │ 共用 MarkdownCore + WebAssets(不链接 *Extension 模块)   │ 共用
┌─────────────────────────┐   ┌──────────────────────────┐
│ MacDown2QuickLook.appex │   │ macdown2 (CLI, Helpers/) │
│ QLPreviewProvider →     │   │ open / workspace / render│
│ JSCRenderer → 静态 HTML │   │ stdin 管道 → 临时文件     │
│ (读 flavors.json+开关)  │   │ (同上)                   │
└─────────────────────────┘   └──────────────────────────┘

外部进程(不链接,仅由对应扩展 spawn):  quarto (QuartoExtension 真渲染)   qmd (QmdSearchExtension)
```

### 2.2 仓库目录结构

```
MacDown2.0/
├── PLAN.md  README.md  LICENSE(AGPL-3.0)  THIRD_PARTY_NOTICES.md  CHANGELOG.md
├── MacDown2.xcodeproj                 # 手写 Xcode 工程,不引入 XcodeGen/Tuist
├── App/                               # 主 App target
│   ├── MacDown2App.swift              # @main, DocumentGroup, Settings, Commands
│   ├── Extensions/ ExtensionRegistry.swift  ExtensionHostImpl.swift   # 唯一注册内置扩展的地方
│   ├── Document/   MarkdownDocument.swift  DocumentState.swift  FileTypes.swift
│   ├── Editor/     EditorPane.swift  (薄壳,逻辑在 EditorKit)
│   ├── Preview/    PreviewPane.swift  PreviewBridge.swift  ImageSchemeHandler.swift  BridgeSchemeHandler.swift(回退通道)  PreviewModeBanner.swift
│   ├── Workspace/  WorkspaceSidebar.swift  FileTree.swift  FolderWatcher.swift  SearchPanel.swift
│   ├── Search/     SearchService.swift  BuiltinSearchBackend.swift        # 核心自带的 SearchProvider
│   ├── Tools/      LoginShellEnvironment.swift                             # 懒加载,只被扩展经 ExtensionHost 触发
│   ├── Outline/    OutlineInspector.swift
│   ├── Export/     HTMLExporter.swift  PDFExporter.swift  (PDF 用离屏 WKWebView 打印)
│   ├── Settings/   AppSettings.swift  GeneralPane.swift  EditorPane.swift  MarkdownPane.swift  RenderingPane.swift  ExtensionsPane.swift  UpdatesPane.swift
│   ├── Updates/    SparkleController.swift
│   ├── Themes/     EditorTheme.swift  PreviewStyle.swift  ThemeLibrary.swift
│   ├── Resources/  Assets.xcassets  AppIcon.icon  Localizable.xcstrings  help.md
│   ├── MacDown2.entitlements  Info.plist
│   └── Supporting/ 
├── QuickLook/                         # Quick Look 扩展 target(沙盒;不链接 *Extension 模块)
│   ├── PreviewProvider.swift  Info.plist  MacDown2QuickLook.entitlements
├── CLI/                               # macdown2 可执行 target(不链接 *Extension 模块)
│   └── main.swift  Commands.swift
├── Packages/
│   ├── MarkdownCore/   Sources/MarkdownCore/{MarkdownRenderer.swift, RenderOptions.swift, RenderResult.swift, JSCRenderer.swift, FlavorManifest.swift, HoedownCompat.swift}
│   │                   Tests/MarkdownCoreTests/{Snapshots/, Fixtures/ (来自 macdown3000, 带来源说明)}
│   ├── EditorKit/      Sources/EditorKit/{MarkdownTextView.swift, Highlighter.swift, EditingAssistant.swift, LineTable.swift, Grammar/}
│   ├── PreviewKit/     Sources/PreviewKit/{ScrollSync.swift, BlockMap.swift, BridgeMessage.swift}
│   ├── WebAssets/      Sources/WebAssets/Resources/{render.bundle.js, preview.bundle.js, quarto.chunk.js, mermaid.chunk.js, flavors.json, katex/, hljs-themes/, preview-styles/, quarto-approx.css}
│   ├── ExtensionAPI/   Sources/ExtensionAPI/{MacDown2Extension.swift, ExtensionHost.swift, DocumentFlavor.swift, SearchProvider.swift, AlternatePreviewMode.swift}
│   ├── QuartoExtension/    Sources/QuartoExtension/{QuartoExtension.swift, QuartoFlavor.swift, QuartoDecorations.swift, QuartoLocator.swift, QuartoPreviewProcess.swift, QuartoLivePreviewMode.swift, QuartoSettingsPane.swift}
│   └── QmdSearchExtension/ Sources/QmdSearchExtension/{QmdSearchExtension.swift, QmdLocator.swift, QmdSearchProvider.swift, QmdCollectionManager.swift, QmdDaemon.swift, QmdSettingsPane.swift}
├── Web/                               # JS 源码与构建(只在改 JS 时需要 Node)
│   ├── package.json  package-lock.json  esbuild.config.mjs  tsconfig.json
│   ├── src/render/   index.ts  options.ts  flavors.ts(chunk 注册表)  plugins/{underline.ts, toc.ts, data-line.ts, front-matter.ts, cjk-emphasis.ts, stats.ts}
│   ├── src/quarto/   manifest.json  index.ts(注册 "quarto" flavor)  code-cell.ts  include.ts  pandoc-blank-line.ts  vendored/(quarto-dev/quarto packages/core/src/markdownit, 保留版权头 + VENDORED.md 记录 commit 与改动)
│   ├── src/preview/  main.ts  dom-patch.ts  geometry.ts  bridge.ts  tasklist.ts  chunk-loader.ts  mermaid-loader.ts
│   ├── test/         *.test.mjs (node --test)
│   └── dist/ → 构建后复制到 Packages/WebAssets/Sources/WebAssets/Resources/ (产物提交进仓)
├── Scripts/  build-web.sh  check-web-drift.sh  check-module-boundaries.sh  make-dmg.sh  sign-and-notarize.sh  make-appcast.sh  bump-version.sh
├── Tests/UITests/                     # XCUITest
└── .github/workflows/  ci.yml  release.yml
```

### 2.3 SPM 包划分与依赖

| 包 | 依赖 | 说明 |
|---|---|---|
| `MarkdownCore` | JavaScriptCore(系统)、`WebAssets` | `MarkdownRenderer` 协议 + `JSCRenderer` 实现 + 选项/结果类型。**不**依赖 AppKit/WebKit,CLI 与 QL 可用。 |
| `EditorKit` | AppKit、`SwiftTreeSitter`(ChimeHQ)、`Neon`、`TreeSitterMarkdown`(+Inline) | 文本视图、高亮、编辑辅助。 |
| `PreviewKit` | 无(Foundation) | 滚动同步/块映射纯算法,100% 可单测。 |
| `WebAssets` | 无 | 只装资源(JS/CSS/字体/`flavors.json`)。 |
| `ExtensionAPI` | `MarkdownCore` | 扩展协议与值类型(`MacDown2Extension`、`ExtensionHost`、`DocumentFlavor`、`SearchProvider`、`AlternatePreviewMode`),无 UI、无进程。 |
| `QuartoExtension` | `ExtensionAPI`、`MarkdownCore`、AppKit/SwiftUI | 内置扩展(默认开):Quarto flavor、装饰高亮、真渲染进程、设置子页。 |
| `QmdSearchExtension` | `ExtensionAPI`、`MarkdownCore` | 内置扩展(默认关):qmd 定位、collection 管理、搜索 provider、常驻服务、设置子页。 |
| App | 以上全部 + `Sparkle`(SPM) | **唯一** import `*Extension` 模块并注册它们的地方。 |

依赖方向单向:核心包(`MarkdownCore`/`EditorKit`/`PreviewKit`/`WebAssets`/`ExtensionAPI`)、`QuickLook`、`CLI` 不得 import 任何 `*Extension` 模块,两个扩展模块互不依赖;`Scripts/check-module-boundaries.sh` 在 CI 守卫(§6.2)。第三方 SPM 依赖全部 pin 到精确版本(`exact:`),Renovate/Dependabot 升级走 PR。

### 2.4 数据流:按键 → 预览 → 滚动同步

```
键入 ──► NSTextView(TextKit 2) ──textDidChange──► DocumentState.text (MainActor)
  │                                                  │
  │ ① 同步:Neon/TreeSitter 增量重解析,高亮可见区   │ ② 防抖 Task(80ms,大文档 150ms)
  │    (hasMarkedText 时跳过,组字结束后补刷)         ▼
  │                                        PreviewBridge.render(text, opts)
  │                                          = page.callJavaScript("return MacDown2.renderAndPatch(md, opts)",
  │                                                                arguments: ["md": text, "opts": json])
  │                                                  │ (WebView 内 JS,主线程 await,不阻塞打字)
  │                                                  ▼
  │                              render.bundle.js: markdown-it 解析 → token 流
  │                                → 顶层块切分(level 0 open…close)→ 每块 HTML + hash
  │                                → dom-patch: 公共前后缀裁剪 + LCS → 只替换变化块
  │                                → 变化块内:Mermaid 懒加载重绘;KaTeX 已是静态 HTML;hljs 已在渲染期完成
  │                                → 返回 { blocks:[{line0,line1,top,height}], outline:[…], stats:{…}, frontMatter }
  │                                                  │
  │                                                  ▼
  │                              Swift: 更新 OutlineInspector / StatusBar / ScrollSync.blockTable
  │ ③ 若"跟随光标"开:ScrollSync.editorLine(caret) → previewY → scrollPosition.scrollTo(y:)
  ▼
滚动编辑器 ──NSScrollView bounds 变化──► ScrollSync.previewY(for: topVisibleLine) ──► WebView 滚动
滚动预览   ──.webViewOnScrollGeometryChange(contentOffset.y)──► ScrollSync.editorLine(for: y) ──► NSTextView scroll
(两方向共用一个 source 锁 + 150ms 静默窗,防 ping-pong)
```

### 2.5 并发模型

| 隔离域 | 内容 | 原因 |
|---|---|---|
| `@MainActor` | SwiftUI 视图、`DocumentState`、`NSTextView` 及高亮应用、`WebPage`(SwiftUI 的 `WebPage` 本身 MainActor)、`PreviewBridge`、`ScrollSyncController`、Sparkle 控制器 | AppKit/WebKit/SwiftUI 都要求主线程;`callJavaScript` 是 `async`,await 期间主线程不阻塞。 |
| `actor JSCRendererActor` | 持有一个 `JSContext`(非 Sendable,用 `nonisolated(unsafe)` 包在 actor 内) | QL / CLI / 导出 / 测试的渲染;一个 actor 一个 context,串行即正确。 |
| `actor SearchService` | 调度已注册的 `SearchProvider`(核心 `builtin`;`qmd` 由 QmdSearchExtension 注册时才存在)、结果缓存 | 进程 IO 与文件遍历在后台;结果 `Sendable` 结构体回主线程。 |
| `actor QuartoPreviewProcess`(QuartoExtension 内) | `Process` 生命周期、stdout/stderr 流解析、端口发现 | 一个文档一个实例;扩展 `deactivate()` 时全部终止。 |
| `actor FolderWatcher` | FSEvents 流(CoreServices C API)回调 → 合并 → 主线程刷新树 | |
| `actor LoginShellEnvironment` | 首次被 `ExtensionHost.toolEnvironment` 访问时 spawn 登录 shell 抓环境,带 5 s 超时;结果 `[String: String]` 缓存,扩展起的外部进程从这里取 `environment`(见 §4.16);两个扩展都关闭时永不执行 | GUI App 由 launchd 启动只有 `/usr/bin:/bin:/usr/sbin:/sbin`,不这么做 quarto/qmd/conda/R 全找不到 |
| Neon 内部 | `TreeSitterClient` 混合同步/异步:文档 < 1 MB 走同步路径(按键内完成),更大走后台解析再回主线程 | 避免大文档卡键入。 |

严格并发规则:跨域传递的全部是 `struct`/`enum`(`Sendable`);`NSAttributedString`、`JSContext`、`Process` 不出其隔离域。Xcode 27 新建 target 默认 `Default Actor Isolation = MainActor`,App target 保留该默认;所有 SPM 包(四个核心包、`ExtensionAPI`、两个 `*Extension`)显式 `swiftSettings: [.defaultIsolation(nil)]`(nonisolated),避免库代码被隐式 MainActor 化;扩展模块里需要主线程的类型(`MacDown2Extension`、`AlternatePreviewMode` 实现)自行标 `@MainActor`。

---

## 3. 渲染核心选型

**结论:选 B(markdown-it 打包为单文件 JS,预览内渲染 + JavaScriptCore 复用);A(Rust comrak)在本项目的收益不足以抵消双工具链和 FFI 成本;C(swift-markdown)扩展覆盖不够,直接出局。**

### 3.1 候选

- **A. Rust**:comrak 0.55.0(2026-09-06,MSRV 1.85)+ syntect,UniFFI 0.32.2 生成 Swift 绑定,打 xcframework 作 SPM `binaryTarget`。
- **B. markdown-it**:markdown-it 15.0.2(2026-09-11)+ 插件,esbuild 打成 IIFE bundle vendor 进仓;预览在 WebView 内渲染并增量 patch DOM;QL/CLI/导出用 JavaScriptCore 跑同一 bundle;块级 `token.map` 行号做滚动同步(VS Code 预览同款做法);编辑区高亮独立走 tree-sitter。
- **C. 纯 Swift**:apple/swift-markdown(cmark-gfm)。

### 3.2 对比

| 维度 | A · Rust comrak | B · markdown-it | C · swift-markdown |
|---|---|---|---|
| 渲染保真度 | CommonMark 规范级;GFM 全套 | CommonMark 规范级(官方测试套件 100%);GFM 由核心规则 + 插件 | CommonMark+GFM(cmark-gfm) |
| Hoedown 非标准语法覆盖 | `highlight`(0.48+)、`superscript`、`subscript`、`underline`、`footnotes`、`smart`、`front_matter_delimiter`、`math_dollars/math_latex`、`header_id_prefix`、`alerts`、`cjk_friendly_emphasis` 全有;`[TOC]` 需自写 | `==mark==`(@mdit/plugin-mark)、`^sup^`/`~sub~`(@mdit/plugin-sup/sub)、脚注(@mdit/plugin-footnote)、智能引号(内建 `typographer`)、front matter(markdown-it-front-matter)、KaTeX(@mdit/plugin-katex,数学先于强调解析,`_` 不被吃)、任务列表(@mdit/plugin-tasklist);`_x_`→`<u>` 与 `[TOC]` 自写(各 <60 行) | 无 mark/sup/sub/underline/math;footnote 有;smart 无。需大量自写 |
| 编辑区高亮精度/增量 | 从 comrak AST + sourcepos 推 token:无分隔符节点、需字节→UTF-16 换算、每键全量重解析 | **与渲染器解耦**:tree-sitter-markdown 增量解析,inline 语法有 `emphasis_delimiter` 等节点,SwiftTreeSitter 直接按 UTF-16 产 `NSRange`,零换算 | 同 A 的问题(SourceRange 字符偏移) |
| 工程/工具链 | rustup + cargo + uniffi-bindgen + xcframework 脚本进每次构建与 CI;UniFFI 对 Swift 6.2 默认 MainActor 隔离有未解 issue(#2818),async 绑定不 Sendable(#2448) | 仅改 JS 时需要 Node;产物提交进仓,日常 `xcodebuild` 零额外依赖;Xcode 原生调试 + Safari Web Inspector 调 JS | 纯 SPM,最简 |
| 供应链 | cargo 依赖树中等;编译进二进制 | npm 小插件多、维护参差(用 2026-09 仍活跃的 @mdit/* 替代 2023 停更的 markdown-it-mark/sup/sub);靠 lockfile + vendored 产物 + 升级审阅缓解 | Apple 维护,最小 |
| QL / CLI / 导出复用 | 同一 xcframework 四处链接;QL 扩展里 Rust 静态库无额外限制 | 同一 bundle 经 JSC 复用;QL 扩展(沙盒、无 JIT)走解释器,100 KB 文档量级可接受(`⚠未验证` 具体耗时,见 S5) | 同 A |
| 调试难度 | lldb 跨 FFI 弱;panic 跨边界需兜底 | Web Inspector 可直接断点预览内 JS;JSC 路径可在 Node 里复现 | 最易 |
| 性能(1 MB 文档) | 最快(估 20–40 ms 解析+渲染) | WebView JIT 实测 61–85 ms(S2:release、M5 Pro、合成 1 MB;冷启动首次 139 ms;全量刷新含 `innerHTML`+布局约 350 ms);配合 80–150 ms 防抖与块级 patch,用户感知差异小 | 快 |
| KaTeX/Mermaid 整合 | 仍要在 WebView 侧跑 JS 后处理 | 同一 JS 运行时内完成,KaTeX 渲染期静态输出 | 同 A |

### 3.3 决策理由(一句话版)

预览本来就是 WebView,KaTeX/Mermaid 本来就是 JS——把 Markdown 解析也放进同一个运行时,**删掉**了 FFI、字节偏移换算、xcframework 构建和第二套工具链;编辑区高亮改用 tree-sitter 后反而比 A 的"从渲染 AST 反推 token"更精确、更增量。A 的性能优势在"每键一次、有防抖"的交互模型下不可感知。保留的代价是两套解析器(markdown-it vs tree-sitter)在边角语法上可能不一致——VS Code 多年如此,可接受。

### 3.4 可替换边界

渲染实现藏在 `MarkdownCore.MarkdownRenderer` 协议后(见 §4.1)。若日后换回 A,只需新增 `RustRenderer` 实现 + 预览侧改为"Swift 渲染 → `callJavaScript("MacDown2.patchBlocks", arguments: blocks)`",其余章节不动。

---

## 4. 各子系统设计

### 4.1 渲染层(MarkdownCore + Web/)

#### 4.1.1 Swift 协议(与实现解耦)

```swift
// Packages/MarkdownCore
public struct RenderOptions: Sendable, Codable, Hashable {
    public var flavor: FlavorID               // "markdown"(核心)或已启用扩展注册的 id,如 "quarto"
    public var renderChunks: [String]         // flavor 要求额外加载的 JS chunk,如 ["quarto.chunk.js"];空 = 只用主 bundle
    public var extensions: ExtensionSet       // tables, strikethrough, autolink, mark, sup, sub, underline,
                                              // footnotes, taskLists, smartPunctuation, math, toc, frontMatter
    public var hardBreaks: Bool
    public var allowRawHTML: Bool             // markdown-it `html: true`
    public var codeHighlighting: Bool
    public var codeLineNumbers: Bool
    public var headingAnchors: Bool
    public var mathDelimiters: MathDelimiters // .dollars | .brackets | .both   ⚠未验证 @mdit/plugin-katex 的 delimiters 选项名
    public var frontMatterDisplay: FrontMatterDisplay // .hidden | .table
    public var baseURL: URL?                  // 相对资源解析基准(文档所在目录)
    public var target: Target                 // .preview | .export | .quickLook | .cli(决定 mermaid 是否降级为代码块、是否内联资源)
}

public struct RenderResult: Sendable, Codable {
    public var html: String?                  // .preview 目标返回 nil(HTML 留在 WebView 内),其余返回完整片段
    public var blocks: [BlockMap]             // 顶层块 → 源码行区间
    public var outline: [OutlineItem]         // 标题层级 + 行号 + slug
    public var stats: TextStats               // words, characters, charactersNoSpaces(CJK 逐字计)
    public var frontMatter: String?
    public var diagnostics: [Diagnostic]      // 例如 YAML 解析失败、未知 shortcode
}
public struct BlockMap: Sendable, Codable, Hashable { public var lineStart: Int; public var lineEnd: Int; public var hash: UInt64 }
public struct OutlineItem: Sendable, Codable, Hashable { public var level: Int; public var text: String; public var slug: String; public var line: Int }
public struct TextStats: Sendable, Codable, Hashable { public var words, characters, charactersNoSpaces: Int }

public protocol MarkdownRenderer: Sendable {
    func render(_ source: String, options: RenderOptions) async throws -> RenderResult
}
```

实现:
- `JSCRenderer`(MarkdownCore):`actor` 内持 `JSContext`,`evaluateScript(render.bundle.js)` 一次,之后调用 `globalThis.MacDown2.render(md, optsJSON)`,返回 JSON 字串解码为 `RenderResult`。QL/CLI/导出/测试用。若 `options.renderChunks` 非空,先在同一 context 里 `evaluateScript` 对应 chunk(每个 context 每个 chunk 只加载一次;chunk 自己调用 `MacDown2.flavors.register(id, setup)`)。QL/CLI 不链接扩展模块,靠 `FlavorManifest`(读 `WebAssets/flavors.json` + App Group 里的扩展开关)决定 flavor 与 chunk(§4.17)。
- `PreviewRenderer`(App/Preview):`callJavaScript("return MacDown2.renderAndPatch(md, opts)", arguments: ["md": text, "opts": json])`,JS 在页面内渲染 + patch,返回元数据(不回传 HTML)。预览用。
- 两者吃同一个 `render.bundle.js`,差别只在"HTML 去哪儿"。

#### 4.1.2 JS bundle 组成(`Web/src/render`)

| 组件 | 版本(2026-10-03 查证) | 许可 | 作用 |
|---|---|---|---|
| markdown-it | 15.0.2 | MIT | 核心;`html: true, linkify: true, typographer: <smart>, breaks: <hardBreaks>` |
| markdown-it-attrs | 4.5.x | MIT | `{.class #id key=val}` 属性;Quarto 插件依赖它 → **随 `quarto.chunk.js` 打包,主 bundle 不含** |
| markdown-it-anchor | 10.0.0 | Unlicense | 标题 id(GitHub 风格 slugify,自写 slugify 保证与大纲一致) |
| @mdit/plugin-mark / -sup / -sub / -footnote / -tasklist / -katex | 1.x–2.x(2026-09-26 发布) | MIT | 对应 Hoedown 扩展;原版 markdown-it-mark/sup/sub 2023-12 后停更,不用 |
| markdown-it-front-matter | 0.2.4(2024-04) | MIT | `---` front matter 抽出为 token;`.qmd` 改用 Quarto `yaml.ts` |
| highlight.js | 11.12.0(2026-08) | BSD-3 | 代码块高亮(class 输出);`⚠` 上游维护节奏已放缓,接口稳定 |
| KaTeX | 0.19.0(2026-10-01) | MIT | `renderToString`,渲染期静态输出;CSS + 字体随包 |
| Mermaid | 12.1.0(2026-10-02) | MIT | 仅预览;单独 ESM chunk,首次遇到 `mermaid` 代码块时 `import()` |
| js-yaml | 4.x/5.x | MIT | Quarto yaml 插件依赖、front matter 表格化 |
| 自写规则(核心) | — | AGPL(本项目) | `underline`(`_x_`→`<u>`,仅 markup 为 `_` 的 em)、`toc`(`[TOC]` 段落替换为嵌套列表)、`data-line`(core rule:所有 `token.map && !inline` 的 token 加 `data-line`/`data-line-end`)、`cjk-emphasis`(CJK 友好强调)、`stats`(字数) |
| Quarto 插件(vendored,**只进 `quarto.chunk.js`**) | quarto-dev/quarto `packages/core/src/markdownit/` @ 固定 commit | 见 §10 | callouts、cites、divs、figure-divs、figures、gridtables、math、shortcodes、spans、table-captions、yaml;加自写 `code-cell`(代码单元头)、`include`(`{{< include >}}` 内联)、`pandoc-blank-line`(标题/引用前需空行)。主 bundle 不含任何 Quarto 代码 |

构建:`esbuild --bundle --format=iife --global-name=MacDown2 --target=safari26 --minify --sourcemap`,TS 直接编译。产物:`render.bundle.js`(目标 **≤ 800 KB** min,不含 Mermaid 与任何 flavor chunk)、`quarto.chunk.js`(目标 ≤ 120 KB,Quarto 插件 + markdown-it-attrs + 自写 Quarto 规则;只在 flavor=quarto 且 Quarto 扩展启用时由预览页 `chunk-loader.ts` 或 `JSCRenderer` 加载)、`preview.bundle.js`(DOM patch/bridge/geometry/chunk-loader,~30 KB)、`mermaid.chunk.js`(懒加载)、`flavors.json`(由各 `src/<flavor>/manifest.json` 汇总,见 §4.17)。`Scripts/check-web-drift.sh` 在 CI 重建并 `diff`,防止源码与提交产物脱节;同时断言主 bundle 不含 `quarto_callout` 等 Quarto token 名(防止 chunk 边界被打破)。

Hoedown/MacDown 选项 → markdown-it 映射见 §5 对等清单"Markdown 偏好"分组。

#### 4.1.3 安全

- `html: true`(MacDown 允许原生 HTML),但预览页用 CSP:`default-src 'none'; img-src macdown2-res: data: https:; style-src macdown2-res://app 'unsafe-inline'; script-src macdown2-res://app 'nonce-<随机>'; connect-src macdown2-bridge:`。用户 Markdown 里的 `<script>` 不会执行,`on*` 属性被 CSP 拦。各项与 S2 实测对齐的理由:
  - **`connect-src macdown2-bridge:` 只为回退通道服务**。主通道 `window.webkit.messageHandlers.<name>.postMessage` 不受 CSP 约束;回退用的 `fetch("macdown2-bridge://…")` 在 `default-src 'none'` 下会被静默拦成 `TypeError: Load failed`,必须显式放行。回退通道若最终砍掉,此项一并删除。
  - **`img-src macdown2-res:` 取代 `'self'`**。`'self'` 匹配 scheme + host + port:文档图片在 host `doc`、应用资源在 host `app`,换 host 的请求会被 `img-src` 拦掉(S2 实测:`macdown2-res://img/red.png` 被拦)。按 scheme 放行最省事,路径越界由 handler 自己守(见 §4.4.2)。
  - **`script-src` / `style-src` 同理不能用 `'self'`**:预览页自身与 `macdown2-res://app/*` 资源不一定同 host,所以写成 `macdown2-res://app`,不放开 `doc` 主机——用户文档目录里的 `.js` 不会被执行。实现时由集成测试断言脚本、样式、图片均加载成功。
  - 仓库里现有 `Web/src/preview/preview.html` 的 CSP 仍是 M0 的 `img-src 'self' …`、无 `connect-src`、无 nonce,待按本条同步(本次只改 PLAN)。
- 相对资源只允许文档所在目录及其子目录(符号链接解析后比较),防 `../../etc/passwd` 式图片读取(macdown3000 #386 同类问题)。
- 外链点击交给系统浏览器(`NavigationDeciding` 返回 `.cancel` + `NSWorkspace.open`),预览 WebView 永不导航到外部 URL(Quarto 真渲染模式只允许 `http://127.0.0.1:<port>`)。

#### 4.1.4 性能目标

| 场景 | 目标 | 测法 |
|---|---|---|
| 50 KB 典型文档,单键 → 预览更新完成 | ≤ 40 ms(渲染 ≤ 15 ms + patch ≤ 10 ms) | XCTest `measure` 经 PreviewBridge |
| 1 MB 文档,`callJavaScript` 纯桥接开销(传入 1 MB、取回约 3.4 MB 结果,扣除 JS 内耗时) | ≤ 10 ms(回归线);**S2 实测 3.5 ms(p95 4.1 ms)** | S2 spike:`DispatchTime` 包 `await page.callJavaScript` 减去 JS 内 `performance.now()` 耗时,3 次预热 + 20 次取中位 |
| 1 MB 纯文本 Markdown,纯渲染(`MacDown2.render`,不含 DOM) | ≤ 150 ms(WebView JIT);**S2 实测 85 ms(完整选项:tables/strikethrough/autolink/smartPunctuation/headingAnchors)、61 ms(精简:tables + strikethrough),冷启动首次调用 139 ms** | 同上;linkify + typographer 约占 23 ms。合成文档,真实文档(更多代码块/KaTeX/原生 HTML)会偏移 |
| 1 MB 文档,全量刷新(渲染 + `innerHTML` + 强制布局) | 无硬目标;**S2 实测约 350 ms(p95 384 ms)**,50 KB 约 19 ms | 这是用户可见的真实成本,印证防抖 + 块级 patch(§4.4.3)必要 |
| 1 MB 文档,单键局部编辑后 patch | ≤ 30 ms(只替换 1–2 块) | JS `performance.now()` 上报 |
| QL 扩展(JSC 解释器)渲染 100 KB | ≤ 500 ms `⚠未验证` | S5 |
| 编辑区高亮,1 MB 文档单键 | 可见区 ≤ 8 ms(同步),全文后台 | Neon 计时 |
| 内存:1 MB 文档稳态 | App ≤ 300 MB(含 WebContent 进程) | Instruments |

### 4.2 文档模型

- `MarkdownDocument: ReferenceFileDocument`(class,`@Observable`):`text: String`、`fileURL`、`flavor`(由已启用扩展注册的 `DocumentFlavor.matches(contentType, firstBytes)` 依次判定,无命中则 `markdown`;Quarto 扩展关闭时 `.qmd` 就是普通 Markdown;扩展开关变化时所有已打开文档重新判定并重渲染)。`snapshot(contentType:)` 返回 `String`;`fileWrapper(snapshot:)` 写 UTF-8(保留原文件是否带 BOM/换行风格:读入时记录 `\r\n`→统一为 `\n` 编辑,写回时按设置"保持原换行"还原;文件尾确保换行按设置)。
- 撤销/自动保存:`ReferenceFileDocument` 的自动保存与版本挂在 UndoManager 注册上。做法:`NSTextViewDelegate.undoManager(for:)` 返回 SwiftUI 环境里的 `undoManager`,这样 NSTextView 的每次编辑都登记到文档的 UndoManager → 自动保存、Versions("浏览所有版本")、iCloud Drive 同步全部走系统路径。**S1 spike 验证**;失败回退:App 改为 `NSDocument` 子类 + `NSHostingView` 承载 SwiftUI 内容(仅文档/窗口层用 AppKit,其余不变)。
- 外部修改:`NSFilePresenter` 由 DocumentGroup 内部处理;额外监听 `fileURL` 的 `DispatchSource.makeFileSystemObjectSource` 以在"无未保存修改"时自动重载(MacDown 行为),有修改时弹"外部已修改"提示。
- 文件类型(Info.plist):
  - 编辑器角色 `Editor`,类型 `net.daringfireball.markdown`(系统已有,conforms `public.plain-text`),扩展 `md markdown mdown mkd mkdn mdwn mdtxt mdtext text`。
  - **`.qmd`**:`UTImportedTypeDeclarations` 声明 `org.quarto.qmd` `⚠未验证`(Quarto 官方未发布 UTI;查无 `org.quarto.*` 注册。identifier 用 Quarto 域名反写、标 imported,一旦官方声明则无缝对接),`UTTypeConformsTo = [net.daringfireball.markdown]`(因而也 conforms `public.plain-text`),`UTTypeTagSpecification = { public.filename-extension: [qmd], public.mime-type: [text/x-quarto-markdown] }`。QL 扩展 `QLSupportedContentTypes` 同时列两者。该声明是**静态**的,与 Quarto 扩展开关无关(Info.plist 无法运行时撤销);开关只决定渲染 flavor。
  - `public.plain-text` 作为次要可打开类型(`.txt`),角色 `Viewer`?不——角色 `Editor` 但不设为默认。

### 4.3 编辑器(EditorKit)

#### 4.3.1 文本视图

- `MarkdownTextView: NSTextView`,`init(usingTextLayoutManager: true)`;**代码库里 grep 禁止** `.layoutManager` 访问(任何一次访问都会让 NSTextView 永久退回 TextKit 1)。CI 加一条 `grep -rn "\.layoutManager\b" Packages App && exit 1`。
- `NSViewRepresentable` 包装:`makeNSView` 创建 `NSScrollView` + 文本视图;`Coordinator` 做 `NSTextViewDelegate`/`NSTextStorageDelegate`;文本双向绑定走 `DocumentState`(避免每键把 1 MB 字串在 SwiftUI 里来回拷:视图只在外部替换文本时写回 NSTextView,键入方向由 delegate 直接更新模型)。
- TextKit 2 已知坑与对策:
  | 坑 | 对策 |
  |---|---|
  | 渲染属性(`NSTextLayoutManager.setRenderingAttributes`)有时不重绘(Apple 论坛 #817471) | 高亮**不用**渲染属性,一律写 `NSTextStorage` 属性(也因主题需要 bold/italic,渲染属性不支持字体)。 |
  | `usageBoundsForTextContainer` 滚动中抖动(Krzyżanowski 2025) | "滚动越过末尾"用 `textContainerInset` 底部留白实现,不伪造内容高度;滚动同步用可见首行而非百分比。 |
  | 只能用 `NSTextContentStorage` / `NSTextParagraph` | 不自定义 content storage。 |
  | macOS 26.x 的 `setMarkedText` 中文选区错误(FB13789916) | 只观察不干预组字期间的选区;自动配对在 `hasMarkedText` 时禁用 ASCII 配对(沿用 MacDown 判断)。 |
- 行号栏:`NSRulerView` 子类,枚举 `textLayoutManager.textViewportLayoutController` 可见 fragment 画行号(只画视口)。
- 查找/替换:用 `NSTextView` 自带 `usesFindBar = true` + `isIncrementalSearchingEnabled`(`performFindPanelAction`),⌘F/⌘⌥F/⌘G 由系统菜单接管。不自造。
- 不可见字符显示:`layoutManager` 不可用,改用 TextKit 2 的 `NSTextLayoutFragment` 子类画制表符/空格标记?成本高 → M3 用 `textStorage` 临时替换显示(`NSTextView.showsInvisibleCharacters` 在 TextKit 2 下可用,`⚠未验证`)。

#### 4.3.2 语法高亮

- 语法:`tree-sitter-markdown`(block)+ `tree-sitter-markdown-inline`(inline),MIT,官方仓 `split_parser` 分支自带 `Package.swift`(targets `TreeSitterMarkdown`、`TreeSitterMarkdownInline`,GFM 扩展编译期默认开:表格、删除线、任务列表;front matter 默认开)。注意其 `Package.swift` 测试依赖 `tree-sitter/swift-tree-sitter`,而 Neon 依赖 `ChimeHQ/SwiftTreeSitter`——两者都依赖 `tree-sitter/tree-sitter` 运行时包,SPM 解析为同一份;若冲突则 fork 一份只含两个 C target 的 `Package.swift`(`⚠未验证` 是否冲突,S4 验证)。
- 运行:ChimeHQ `SwiftTreeSitter`(BSD-3,默认 **UTF-16** 编码,`Node.range` 直接是 `NSRange`,运行时 tree-sitter 0.25)+ `SwiftTreeSitterLayer` 处理 block→inline 注入;`Neon`(BSD-3,swift-tools 6.0,支持 TextKit 1/2;README 自述 main 分支"尚未正式发布但非常可用" `⚠` 预发布风险)的 `TreeSitterClient` + 自定义 `TextSystemInterface` 把 capture 名映射为主题属性。
- fenced code / Quarto 代码单元内的语言注入:M2 加 `tree-sitter-python`、`tree-sitter-r`(Quarto 两大执行语言)与 `tree-sitter-yaml`(front matter / `#|` 单元选项),通过 `SwiftTreeSitterLayer` 的 injections 查询(`(fenced_code_block (info_string) @injection.language (code_fence_content) @injection.content)`,Quarto 的 ```` ```{python} ```` 需在 info string 匹配里剥掉花括号)。其余语言是否注入见 Q9(每个语法 +0.3–1 MB 包体)。
- 流程:`textDidChange` → `TreeSitterClient.didChangeContent(in:delta:)` → 可见区同步查询 highlights → `textStorage.beginEditing(); setAttributes(...); endEditing()`;其余区域后台解析完成后分批应用。`hasMarkedText == true` 时**不**写属性(会打断中文/日文组字),记一个 `pendingHighlight` 标志,下一次 `textDidChange` 且 `hasMarkedText == false` 时补刷整段。
- 主题属性仅 `foregroundColor`、`backgroundColor`、`font`(trait bold/italic,**不改字号**,保证行高稳定、滚动映射简单)、`underlineStyle`。

#### 4.3.3 `.qmd` 高亮

- 现状:`ck37/tree-sitter-quarto`(MIT,单一语法,含代码单元/`#|` 选项/交叉引用/shortcode/div,带 `Package.swift`)自述 alpha、测试 203/314 通过,最近推送 2025-11;官方 `quarto-dev/quarto-markdown`(MIT)自述"NOT READY FOR PRODUCTION"。
- 决策:**`.qmd` 先沿用 tree-sitter-markdown 双语法 + 一层正则"Quarto 装饰"**——装饰由 `QuartoExtension` 经 `DocumentFlavor.editorDecorations` 提供,`fenceLanguageMapper` 把 ```` ```{python} ```` 映射为 `python` 供注入高亮;Quarto 扩展关闭时无此叠加,`.qmd` 只有基础 Markdown 高亮(fence 的 `{python}`/`{r}` 语言标记、`#|` 单元选项行、`:::`/`::: {.callout-note}` 分块围栏、`{{< … >}}` shortcode、`@fig-x` 交叉引用、`[@cite]`、行内代码单元 `` `{python} expr` `` / `` `r expr` ``——这两种在真渲染时**会执行**,编辑区用与块级单元相同的"可执行"色标出),作为附加属性叠加在 tree-sitter 高亮之上(只在视口内、按行匹配,开销可忽略);代码单元内容走 §4.3.2 的 Python/R 注入。S4 同时试跑 tree-sitter-quarto;若它在我们的 `.qmd` 语料上无崩溃且高亮优于叠加方案,M2 切换。

#### 4.3.4 编辑辅助(EditingAssistant,纯 Swift,可单测)

对照 `NSTextView+Autocomplete.m` 行为重写(逻辑对等、代码不搬):
- 配对字符:`()[]{}<>""''` + Markdown `**`、`__`、`~~`、`` ` ``:插入左半时在边界(前后为空白/标点)补右半并把光标置中;输入右半且下一个字符就是它时只移光标;选区存在时用配对符包裹(`*`/`_`/`~`/`` ` ``/括号)。系统智能引号开着时不接管 `"`/`'`。退格删左半且右半紧邻时一起删。
- 列表续写:回车时按正则 `^(\s*)([-*+]\s|\d+[.)]\s|\[[ xX]\]\s)?` 续写;有序列表按设置自增;空项再回车删除标记(退出列表);任务列表续 `- [ ] `。引用 `> ` 续写;缩进代码续缩进。
- Tab:转空格(设置)、选区整体缩进/反缩进(⌘]/⌘[)。
- 智能 Home(先到行首非空白)。
- 格式命令(菜单/工具栏):H1–H6/段落、加粗/斜体/行内代码/删除线/下划线/高亮/注释 `<!-- -->`、链接/图片(有选区则包裹,剪贴板有 URL 自动填)、插入表格、有序/无序列表切换、引用切换。
- 粘贴:剪贴板是图片 → 保存到文档旁 `assets/<name>.png` 并插入 `![](assets/…)`(文档未保存则提示先保存);剪贴板是 URL 且有选区 → 变链接。

#### 4.3.5 状态栏

行:列 / 选区字数(有选区)或全文字数(`stats`,CJK 逐字计数,可切换 词/字符/不含空格字符)/ 渲染模式(Markdown · Quarto 近似 · Quarto 真渲染)/ 保存状态。玻璃胶囊样式(`.glassEffect(.regular, in: .capsule)`)。

### 4.4 预览(PreviewPane + Web/src/preview)

#### 4.4.1 WebKit for SwiftUI 能力核对

| 需求 | API | 状态 |
|---|---|---|
| Swift→JS 调用并取返回值 | `WebPage.callJavaScript(_:arguments:in:contentWorld:) async throws -> Any?`,arguments 字典在 JS 作用域可见 | 已验证(WWDC25 231 + 多篇实测) |
| 加载文档旁相对图片 | `WebPage.Configuration.urlSchemeHandlers[URLScheme("macdown2-res")] = handler`;`URLSchemeHandler.reply(for:) -> some AsyncSequence<URLSchemeTaskResult, any Error>`(`.response`/`.data`) | 已验证(S2 实测:页面本身、JS/CSS、PNG/SVG/1200×800 图片、相对路径、404 均正常;**三个坑见 §4.4.2 末**) |
| JS→Swift 推送(任务列表勾选、点击链接、错误上报) | **主通道:message handler。** `WebPage.Configuration.userContentController` 就是 `WKUserContentController`:`var cfg = WebPage.Configuration(); cfg.userContentController.add(handler, name: "macdown2")`(`handler: NSObject, WKScriptMessageHandler`),JS 端 `window.webkit.messageHandlers.macdown2.postMessage({...})`,回调在**主线程**(别在里面做重活)。不受 CSP/CORS 约束。**回退通道:** `fetch("macdown2-bridge://event?type=…&line=…")`(GET + query)→ 第二个 `URLSchemeHandler` 回 204 + `Access-Control-Allow-Origin: *`,需 CSP `connect-src macdown2-bridge:`(§4.1.3);实测 POST 的 `httpBody` 也能到,但仍选 GET。链接点击用 `NavigationDeciding.decidePolicy` 拦截。 | **已验证(S2)**,原"WebPage 无 message handler 等价物"的前提不成立,不再需要 `WKWebView` + `NSViewRepresentable` 回退。实测 100 事件/s × 10 s(1000 个):message handler 0 丢失、0 重复、顺序不乱,延迟中位 0.91 ms / p95 1.47 ms;与每 ~150 ms 一次的 1 MB 渲染并发(41 次)同样 0 丢失,中位 1.29 ms;瞬发 1000 个(8 ms 内)0 丢失、0 重复、顺序不乱。scheme fetch 回退通道同样全部 0 丢失/0 重复/顺序不乱(空闲 1.17 ms;并发渲染 1.27 ms;15 ms 内瞬发 1000 个,中位 6.1 ms / p95 8.6 ms)。未测 `addScriptMessageHandlerWithReply`。 |
| 读/设预览滚动位置 | `.webViewScrollPosition($pos)` + `pos.scrollTo(y:)`;`.webViewOnScrollGeometryChange(for:of:action:)` 读 `contentOffset.y` / `contentSize` | 已验证(TrozWare 实测;**S2 实测**:1 MB 文档(867,386 px 高)下回调约 57–60 Hz,与显示帧率同步,四种合成驱动(JS rAF `scrollBy`、JS smooth scroll、Swift `ScrollPosition.scrollTo` 120 Hz 定时器、进程内合成滚轮事件)均 ≥ 30 Hz)。合成事件绕过了系统事件通路,**真实触控板、惯性滚动、120 Hz 屏未覆盖**,需人手 30 秒确认,列入 `docs/manual-qa.md`(§6.1) |
| 页内查找 | `.findNavigator(isPresented:)` | 已验证(替换不可用,预览本来只读) |
| 禁止外部导航 | `WebPage(configuration:navigationDecider:)`,返回 `.cancel` 并 `NSWorkspace.shared.open` | 已验证 |
| PDF 导出 | `WebPage` 是 `Transferable`;`func exported(as representation: WebPage.ExportedContentConfiguration) async throws -> Data`,配置 `.pdf(region: Region = .contents, allowTransparentBackground: Bool = false)`(`Region` 为 `.rect(_:)` / `.contents`) | **签名已验证(S2)**。产出是**屏幕宽度、单页最高 14400 pt 的长条页,不是 Letter/A4 分页**(1 MB 文档 61 页 883×14400 pt、4.5 MB、1.5 s;50 KB 4 页、56 ms)。`.pdf(region: .rect(0,0,600,800))` 恰好一页;`WKWebView.pdf()` 的字节与分页和 `WebPage` 路线相同。`.image(snapshotWidth:)` 在长页面上失败,不可用于整页导出。**分页 PDF** 见 §4.7 |
| Web Inspector 调试 | `WebPage.isInspectable`(`@MainActor var isInspectable: Bool { get set }`,默认 `false`;置 `true` 后底层 `WKWebView.isInspectable` 同步为 `true`)。Debug 构建 `#if DEBUG page.isInspectable = true` | **属性存在且可读写(S2 实测)**;Safari Web Inspector 实际能否挂上 `⚠未验证`(本机 Safari 未开 Develop 菜单,需人手一次:Safari ▸ 设置 ▸ 高级 ▸ 显示网页开发者功能,开发 ▸ 本机 ▸ App ▸ 页面),见附录 A 第 2 条 |

#### 4.4.2 预览页结构

`preview.html`(随包,`loadHTMLString(_, baseURL: macdown2-res://doc/)`):
```html
<html><head><meta charset=utf-8><meta http-equiv=Content-Security-Policy content="…">
<link rel=stylesheet href="macdown2-res://app/styles/<style>.css">   <!-- 预览主题 -->
<link rel=stylesheet href="macdown2-res://app/hljs/<theme>.css">
<link rel=stylesheet href="macdown2-res://app/katex/katex.min.css">
<script nonce=… src="macdown2-res://app/render.bundle.js"></script>
<script nonce=… src="macdown2-res://app/preview.bundle.js"></script>
</head><body><article id=doc data-flavor=markdown></article></body></html>
```
`macdown2-res://app/*` 由 handler 映射到 `WebAssets` bundle 资源;`macdown2-res://doc/*` 映射到文档目录(目录越界拒绝)。主题切换 = 换 `<link href>` 并 cache-bust,不重载页面。flavor chunk 按需加载:`chunk-loader.ts` 在 `renderAndPatch` 收到 `renderChunks` 非空且尚未加载时,动态插入带同一 nonce 的 `<script src="macdown2-res://app/quarto.chunk.js">` 与对应 `<link>`(`quarto-approx.css`),等 `load` 后再渲染;扩展关闭或文档非该 flavor 时永不加载。

**`URLSchemeHandler` 的三个坑(S2 实测,真实 `preview.html` + 逐字 CSP 下得出)**:
1. **`urlSchemeHandlers` 在 `WebPage` 创建后就改不了**(`Configuration` 只在创建时生效)。所以每个文档的根目录不能配置进去,handler 必须在 `reply(for:)` 里**动态解析**:用 host(或路径前缀)当文档 id,查 `[docID: 目录]` 表。
2. **CSP 的 `'self'` 会拦掉换了 host 的请求**:`'self'` 匹配 scheme + host + port,`macdown2-res://img/red.png` 在 `img-src 'self'` 下被拦。解法:CSP 写 `img-src macdown2-res:`(§4.1.3),或把所有文档放同一 host 下用路径前缀区分。
3. **百分号编码的 `..` 能穿到 handler**:`..%2f..%2fPackage.swift` 到 handler 时是 `/img/../../Package.swift`;字面 `../..` 则被浏览器先规范化,handler 只会看到 `/Package.swift`(404)。handler 必须**自己在解码后拦截 `..` 路径分量**(并在符号链接解析后与文档根比较,§4.1.3),返回 403。

S2 的实测路径是**页面本身也由 handler 服务**(`macdown2-res://doc/index.html`),`loadHTMLString(_, baseURL:)` 这一加载方式未单独测;未测:大图流式、Range 请求、音视频。

#### 4.4.3 增量 DOM patch 策略

1. markdown-it 解析得 token 流;按 `level === 0` 的 open/close 配对切出**顶层块**(`fence`/`hr`/`html_block`/`code_block` 单 token 即一块;脚注区 `footnote_block_open…close` 是末尾一块;TOC 替换后的列表是一块)。
2. 每块 `md.renderer.render(tokens, options, env)`(env 共享引用定义/脚注编号),得 HTML;hash = FNV-1a(HTML 去掉 `data-line*` 属性后)。
3. `dom-patch.ts`:旧块 hash 数组 vs 新数组 → 裁剪公共前缀/后缀 → 中段做 LCS(编辑是局部的,中段通常 ≤ 10 块;若中段 > 2000 块退化为整段替换)→ 删除/插入/移动 `<article>` 的子节点;未变块仅更新 `data-line`。
4. 变化块内后处理:`.mermaid` → 首次 `import("./mermaid.chunk.js")`,`mermaid.run({nodes})`;KaTeX、hljs 已在渲染期完成,无后处理;任务列表 checkbox 绑定 click → bridge 事件 `toggleTask(line)`。
5. 返回 `geometry()`:遍历顶层块 `getBoundingClientRect()` + `scrollY` 得 `[{line0, line1, top, bottom}]`;连同 outline/stats 回 Swift。图片加载/字体加载导致重排时 `ResizeObserver` 置脏,Swift 下次同步前调 `callJavaScript("return MacDown2.geometry()")` 取新表(拉模型,无需推送通道)。
6. 滚动位置保持:patch 不触碰未变块,位置天然保持;整段替换时先记 `scrollY` 再 `requestAnimationFrame` 恢复。

#### 4.4.4 滚动同步算法(PreviewKit,纯函数)

MacDown 只用标题/独立图片做参考点插值;这里用**每个顶层块的源码行区间**,精度高一个量级。

```
输入:blocks[i] = {line0, line1, top, bottom}(按 line0 升序),editorLine L(可带小数:首行索引 + 该行 fragment 已滚过比例)
previewY(L):
  i = 最后一个 line0 ≤ L 的块
  若 L < blocks[i].line1:  y = top_i + (L - line0_i)/(line1_i - line0_i) * (bottom_i - top_i)     // 块内线性
  否则(落在块 i 与 i+1 之间的空行):y = bottom_i + (L - line1_i)/(line0_{i+1} - line1_i) * (top_{i+1} - bottom_i)
  边界:L 在首块前 → 0;在末块后 → 文档末尾;
editorLine(y):上式反函数,再由 LineTable 求该行 fragment 的 y,NSTextView.scroll(to:)
```
- 触发:编辑器 `NSScrollView` `boundsDidChange`(用户滚动,`inLiveScroll` 期间也同步)、键入后(跟随光标行,仅当光标行不在预览视口内时滚,避免跳动)、预览 `contentOffset` 变化。
- 防 ping-pong:`ScrollSyncController` 持 `source: .none/.editor/.preview` 与时间戳;程序化滚动前设 source 并忽略对向事件 150 ms;两侧都用 `animated: false`。
- 用户关掉同步 → 立即停止(MacDown #441 教训)。

#### 4.4.5 KaTeX / Mermaid

- KaTeX:`@mdit/plugin-katex` 在解析期 `renderToString`(`throwOnError: false`,错误用红字 `<span class="katex-error">`),输出静态 HTML,预览/QL/导出完全一致;字体通过 `macdown2-res://app/katex/fonts/`;导出时内联 CSS,字体按设置内联 base64(默认不内联,体积 300 KB+)。分隔符:`$…$`/`$$…$$` 默认;`\(…\)`/`\[…\]` 为 MathJax 兼容选项(`⚠未验证` 插件 `delimiters` 选项,否则自写 10 行 inline rule)。
- Mermaid 12:仅预览与 HTML 导出(导出时把 SVG 内联);QL 与 CLI 目标退化为高亮代码块。`securityLevel: 'strict'`,主题随亮暗。

#### 4.4.6 预览主题(CSS)

内置重写:`GitHub`(默认)、`GitHub Dark`(随系统)、`Clearness`、`Paper`、`Solarized Light/Dark`、`Academic`(衬线、适合导出 PDF)。全部用 CSS 自定义属性 + `@media (prefers-color-scheme)`,`@media print` 去掉背景与阴影。用户自定义:`~/Library/Application Support/MacDown2/Styles/*.css`、`.../HighlightThemes/*.css`、`.../EditorThemes/*.json`,文件夹变更即时刷新。

### 4.5 主题系统(编辑器)

`EditorTheme`(JSON):`{ "name", "appearance": "light|dark|auto", "font": {"name","size"}, "colors": {"background","text","caret","selection","lineNumber","currentLine"}, "tokens": { "heading": {"fg","bold"}, "emphasis": {"italic"}, "strong": {"bold"}, "code": {...}, "link": {...}, "image", "blockquote", "listMarker", "hr", "html", "footnote", "strikethrough", "table", "frontMatter", "math", "quartoCell", "quartoDiv", "quartoShortcode" } }`。capture 名(tree-sitter `highlights.scm`)→ token 名映射表在 `Grammar/CaptureMap.swift`。内置:`Default Light/Dark`、`Solarized`、`Tomorrow`、`Mono`。

### 4.6 Quarto `.qmd` 支持(内置扩展 `QuartoExtension`,默认开)

扩展形态与开关(机制见 §4.17):
- **开(默认)**:`activate()` 注册 `quarto` flavor(UTType `org.quarto.qmd` 或 front matter 含 Quarto 键即命中)、编辑区装饰、`Preview ▸ Render with Quarto` 命令与工具栏分段控件、`AlternatePreviewMode`(真渲染)、设置子页。激活本身**不**探测 `quarto`、不读登录 shell 环境——探测只在用户第一次切到真渲染(`isAvailable()`)或打开扩展子设置页时发生。
- **扩展内子开关「Quarto 真渲染」**(默认开,与原方案一致):关闭则 `alternatePreviewMode = nil`,不出现任何真渲染按钮/菜单,不探测 quarto;近似预览不受影响。
- **关**:`.qmd` 按普通 Markdown 打开与预览(UTType 声明仍在,见 §4.2);预览顶部一次性提示 "启用 Quarto 扩展以获得 callout / 交叉引用预览" [打开设置] [不再提示];QL 同样按普通 Markdown 渲染;`quarto.chunk.js`、`quarto-approx.css` 都不加载;无命令、无子设置页、零进程。
- **运行中关闭**:`deactivate()` 对每个文档 `stop()` 真渲染进程(SIGTERM→3 s→SIGKILL),预览切回核心渲染并把 `.qmd` 按普通 Markdown 重渲染,移除横幅与命令。

#### 4.6.1 近似预览(扩展启用即可用,无外部依赖,M1)

- 判定:UTType 为 `org.quarto.qmd` 或 front matter 含 `format:`/`execute:` 等 Quarto 键 → `flavor = .quarto`。
- 渲染:markdown-it 实例加载 Quarto 插件(复用 quarto-dev/quarto `packages/core/src/markdownit/`,该目录以 TypeScript 写、目标 markdown-it ^15.0.2、依赖 markdown-it-attrs/js-yaml/wcwidth):`yaml`(front matter 展示)、`divs`(`:::` 分块)、`callouts`(note/tip/warning/caution/important,含标题/折叠)、`spans`(`[text]{.class}`)、`cites`(`[@key]`、`@key` 文内引用,渲染为引用样式,不解析 bib)、`figures`/`figure-divs`/`table-captions`(图表标题与 `#fig-`/`#tbl-` 锚)、`shortcodes`(`{{< … >}}` 渲染为惰性标记)、`gridtables`、`math`。交叉引用 `@fig-x` 由 cites 插件转为指向锚点的链接(标签文字用 "Figure ?" 占位)。
- 代码单元:自写 `code-cell` 规则识别 ```` ```{python} ```` 形式的 fence,`#|` 行解析为单元选项(渲染成单元头部小表或折叠),代码主体按语言交给 highlight.js;行内单元 `` `{python} expr` ``/`` `r expr` `` 渲染为带 "code" 徽标的 `<code class="inline-cell">`;**绝不执行**。
- `{{< include file.qmd >}}`:App 不开沙盒,近似预览直接读取被包含文件并内联解析(路径限文档目录内,递归深度 ≤ 5,循环检测),这是唯一"真做"的 shortcode;其余 shortcode(`video`、`embed`、`meta`、`var`、`env`、`pagebreak`、`kbd`…)渲染为惰性徽标。
- 预览页 `article[data-flavor=quarto]` 加载 `quarto-approx.css`(callout 配色、figure caption、单元头)。
- UI 标识:状态栏与预览栏顶部徽标都写 **"Quarto · 近似预览"**,hover 解释"未执行代码、未应用项目配置";工具栏 `近似 | Quarto` 分段控件 M2 加入(仅「Quarto 真渲染」子开关开启时出现;本机找到 quarto 时可用,否则灰显并提示安装)。
- **已知偏差(Pandoc 方言 ≠ CommonMark),写进 help.md 并在诊断面板按条提示**:
  | Quarto/Pandoc 行为 | 近似预览(markdown-it)行为 | 处理 |
  |---|---|---|
  | 标题、引用块前**必须**空一行(`blank_before_header`/`blank_before_blockquote`) | CommonMark 不要求 | `.quarto` flavor 下加一条 core 前置规则:上一行非空则不识别为标题/引用(模拟 Pandoc),M2 |
  | YAML 元数据块可出现在文中任意位置(前空一行) | 只识别文首 front matter | 用 Quarto `yaml.ts` 插件(支持文中 YAML 块);解析失败显示原文 |
  | 项目上下文:上级 `_quarto.yml`(主题、crossref 前缀、bibliography、filters)、`_extensions/`、Lua 过滤器、book/website 跨文件交叉引用 | 不可还原 | 只读取文档自身 front matter;`@sec-x`/`@fig-x` 指向本文件不存在的锚时显示 `?` 占位;顶部徽标 hover 提示"项目配置未应用" |
  | 引用 `[@key]` 需 `.bib` + CSL 渲染 | 不解析 bib | 渲染为 `[@key]` 样式 span;若 front matter 给了 `bibliography:` 且文件存在,M3 可选解析 BibTeX 取作者/年份(不排版参考文献表) |
  | 定义列表、行块、example lists、`+` 跨表格等 Pandoc 扩展 | 部分不支持 | 列入 help.md "不支持列表";出现时诊断面板提示 |
  | 代码单元输出(图、表、`echo: false`) | 没有 | 徽标 + 按钮引导真渲染 |

#### 4.6.2 真渲染(扩展子开关「Quarto 真渲染」默认开;用户显式触发,M2)

- 定位 `quarto`:`QuartoLocator` 先取设置里的手动路径;否则在 `LoginShellEnvironment.PATH`(§4.16)里 `command -v quarto`,再兜底查 `/opt/homebrew/bin`、`/usr/local/bin`、`/Applications/quarto/bin`、`~/.local/bin`;运行 `quarto --version` 校验(要求 ≥ 1.4;当前最新 1.10.18,2026-07-24)。设置页 "Quarto" 显示检测到的路径/版本、`QUARTO_PYTHON`/`QUARTO_R` 等从登录 shell 抓到的变量、以及手动指定路径与 Python 解释器的入口。
- 触发:仅工具栏分段控件 `近似 | Quarto` 或菜单 `Preview ▸ Render with Quarto`(⌘⌥R)。**打开文档从不自动执行**。每个文档会话首次切换弹确认 sheet:"将用本机 Quarto 执行本文档中的代码单元——包括 ```` ```{python} ```` 代码块和 `` `{python} expr` ``、`` `r expr` `` 行内代码。只对你信任的文档这样做。" [取消] [渲染]。同一文档会话内后续切换不再问;重新打开文档再问。设置里可关 "每次询问"(默认开)。
- 进程(`actor QuartoPreviewProcess`,一个文档一个):
  ```
  quarto preview <abs-path.qmd> --no-browser --host 127.0.0.1 --port <p> --render html --log <tmp>/quarto-<uuid>.log --log-format json-stream
  ```
  - 端口:先自行 bind(0) 取一个空闲端口关掉再作为 `--port` 建议;Quarto 文档明说端口是"建议",不可用会换随机端口 → **必须解析 stdout** 中 `Browse at http://127.0.0.1:<port>/`(或 `Watching files for changes`)拿实际 URL;30 s 内未拿到 → 视为失败。
  - 运行目录 `cwd = 文档目录`;`Process.environment = LoginShellEnvironment.environment`(完整登录 shell 环境,含 `PATH`、`QUARTO_PYTHON`、`QUARTO_R`、conda/venv 变量),这是 conda/venv 里的 Python、R 能被找到的前提;App 自己不设置任何 `QUARTO_*`。
  - 预览 `WebPage.load(URLRequest(url: http://127.0.0.1:<port>/))`;`NavigationDeciding` 仅放行该 origin;Quarto 自带 live-reload:文档保存(自动保存或 ⌘S)→ Quarto 重渲染 → 页面自刷新。真渲染模式下 App 侧**不再**做 `callJavaScript` 渲染。
  - **无行号、无滚动同步(已查证)**:Pandoc 的 `sourcepos` 扩展只对 commonmark/gfm/commonmark_x 读取器生效,Quarto 走 pandoc markdown 读取器,输出 HTML 不含源码位置;且观感是 Quarto 的 Bootstrap 主题而非我们的预览主题。因此真渲染模式:滚动同步关闭、大纲改为从 Quarto 输出页的 `h1–h6` 读(`callJavaScript`,只能跳转预览不能跳编辑器)、字数仍来自 App 侧解析。
  - **切换体验**:预览栏顶部常驻一条细横幅:`[近似 | Quarto]` 分段控件 · "上次渲染 12:03:21" · 状态点(渲染中旋转 / 成功 / 失败)· [日志]。近似→Quarto:确认 → 预览区显示进度(进程启动 + 首次渲染通常 3–15 s)→ 载入。Quarto→近似:**立即 SIGTERM 进程**(不保留后台执行;重新切换重新启动,代价几秒),并把预览滚到编辑器当前行。编辑期间 Quarto 模式的预览只反映"最后一次保存",横幅在有未保存修改时显示 "未保存的修改尚未渲染"。文档关闭/App 退出同样杀进程。
  - **副产物**:`quarto preview` 会在文档旁生成 `<name>.html`、`<name>_files/`、`.quarto/`、`_freeze/`(项目)等;文件夹侧栏默认隐藏这些(§4.11),FolderWatcher 对它们的变更不触发刷新。不自动清理(是用户的产物)。
  - 退出:用户切回近似模式、文档窗口关闭、App 退出(`NSApplication.willTerminateNotification` + `atexit` 兜底)→ `SIGTERM`,3 s 未退 `SIGKILL`;`terminationHandler` 清理日志临时文件。崩溃/非零退出 → 预览栏顶部横幅 "Quarto 已退出(code N)" + "查看日志" 按钮(展示 json-stream 日志里的 error 条目)。
  - 多窗口同一文件:复用同一进程(以规范化路径为键)。
- 不用 `quarto render` 单次渲染的原因:preview 内建 watch + 增量重渲染 + 服务静态资源(图片/输出目录),省去我们管输出目录与资源路径。

### 4.7 导出

- **HTML**:`JSCRenderer.render(target: .export)` → 套固定模板:内联预览主题 CSS、hljs CSS、KaTeX CSS(字体按设置内联);图片按设置 内联 base64 / 保持相对路径 / 复制到 `<name>_files/`;Mermaid 用预览里已渲好的 SVG(从 WebView `callJavaScript("return MacDown2.exportSVGs()")` 取回替换)。
- **PDF**:需分页(Letter/A4、页边距)。S2 实测:`WebPage.exported(as: .pdf(region:allowTransparentBackground:)) async throws -> Data` 产出的是**屏幕宽度、单页最高 14400 pt 的长条页**(1 MB 文档 61 页 883×14400 pt、1.5 s),不是 Letter/A4 分页;`WKWebView.pdf()` 结果相同,`.image(snapshotWidth:)` 在长页面上直接失败。**「导出 PDF」是接受长条页(实现最简单:一行 API、17 ms–1.5 s),还是改走分页打印路线,列为 `⚠未验证` 待拍板项(附录 A 第 16 条)**;方案默认仍按分页打印路线设计(`NSPrintOperation` 路线 S2 未测):App 内一个**离屏 `WKWebView`**(非 UI 组件,不进视图层级)加载导出 HTML,`printOperation(with: NSPrintInfo)`,`jobDisposition = .save`、`NSPrintSavePath` 指向目标文件,`runModal(for:)`。⌘P 同路径走系统打印面板。Quarto 真渲染模式下导出 = 调 `quarto render --to pdf/html`(需用户确认,因会执行代码)。
- **复制 HTML**(⌘⇧C):渲染片段进剪贴板(`public.html` + 纯文本)。

### 4.8 设置(Settings 场景)

`AppSettings: @Observable`,属性经 `UserDefaults(suiteName: "<TEAMID>.io.github.xuanji86.MacDown2.shared")`(App Group,QL 扩展可读)持久化,KVO 监听外部变更。分页:

| 页 | 项(默认值) |
|---|---|
| General | 启动时不建空白文档(off)、更新含预发布(off)、默认打开为预览模式(off)、命令行工具安装按钮、工作区搜索忽略规则(`.git`, `node_modules`, `_site`, `_freeze`, `*_files`)、外部工具环境(抓取来源 shell/耗时/PATH 条目数、"重新抓取";仅当某个已启用扩展触发过抓取时显示,否则显示"尚未需要") |
| Editor | 字体(SF Mono 13)、行距、水平/垂直内边距、限宽(off,760px)、编辑器在右(off)、自动配对(on)、列表自增(on)、Tab 转空格(on, 4)、智能 Home(on)、块内续前缀(on)、滚动越过末尾(off)、文件尾保证换行(on)、显示不可见字符(off)、无序列表标记(`-`)、编辑器主题、显示行号(on)、显示字数(on)+ 计数类型、滚动同步(on)、跟随光标(on) |
| Markdown | 表格(on)、自动链接(on)、删除线(on)、高亮 `==`(on)、上标 `^`(off)、下标 `~`(off)、下划线 `_`(off)、脚注(on)、任务列表(on)、智能标点(off)、`[TOC]`(on)、front matter(检测 on,显示:隐藏/表格)、原生 HTML(on)、硬换行(off)、CJK 友好强调(on,已定默认开;markdown-it 侧自写 inline 规则,M1) |
| Rendering | 预览主题、代码高亮(on)+ 主题、行号(off)、代码块语言标签(on)、数学(on)+ 分隔符模式、Mermaid(on)、预览缩放、默认导出目录 |
| 扩展 | 每个内置扩展一行:名称、一句说明、开关(存 App Group `extension.<id>.enabled`,QL 也读);展开显示该扩展的 `settingsPane()`,关闭时子设置折叠隐藏且不做任何探测。**Quarto(on)**:子开关「Quarto 真渲染」(on;关则不探测 quarto、无按钮/菜单)、检测到的路径/版本(含来源:手动/登录 shell PATH/兜底目录;首次展开才探测)、手动指定 quarto 路径、`QUARTO_PYTHON`/`QUARTO_R` 当前值(只读显示 + 可覆盖)、"渲染前每次询问"(on)、真渲染 `--render` 格式(html)、侧栏显示 Quarto 输出(off)。**qmd 搜索(off)**:检测到的 `qmd` 路径/版本、手动指定 qmd 路径、语义搜索(off;开启时说明 ~2 GB 模型下载)、CJK 嵌入模型(off → 设 `QMD_EMBED_MODEL` 为 Qwen3-Embedding,提示需 `qmd embed -f`)、自动 `qmd embed`(空闲时,on)、重排(off)、常驻 qmd 服务(off,带安全说明) |
| Updates | Sparkle 自动检查(on)、自动下载(off)、立即检查 |

### 4.9 Quick Look 扩展

- `QLPreviewProvider` 子类(数据式),`providePreview(for:)` 读文件 → `JSCRenderer.render(target: .quickLook)` → 组静态 HTML(内联 CSS;KaTeX 字体用 `cid:` 附件 `QLPreviewReplyAttachment`;文档旁图片读入作 `cid:` 附件,上限 20 张/10 MB)→ `QLPreviewReply(dataOfContentType: .html, contentSize:)`。
- Quick Look 的 HTML 预览**不执行 JavaScript**(二手实证,`⚠未验证` 官方文档未明说;设计上已不依赖 JS):Mermaid 降级为代码块,任务列表只显示。
- 扩展必须沙盒;读文档旁图片需 `com.apple.security.files.user-selected.read-only`?QL 扩展对被预览文件所在目录有隐式读权限(`⚠未验证` 对同目录其他文件,S5 验证;不行就只渲染被预览文件,图片占位)。
- 读取用户主题/选项:App Group 共享 `UserDefaults`;QL 永远关闭 Mermaid。
- 扩展开关:QL **不链接**任何 `*Extension` 模块。每次 `providePreview` 读 App Group 的 `extension.quarto.enabled` 与 `WebAssets/flavors.json`:开且文件 UTType 匹配 → `RenderOptions(flavor: "quarto", renderChunks: ["quarto.chunk.js"])` + `quarto-approx.css`;关 → 按普通 Markdown。不在 QL 进程内缓存开关值。qmd 扩展与 QL 无关。
- JSC 在扩展内无 JIT(解释器),100 KB 以内文档可接受;>1 MB 的文件 QL 只渲染前 1 MB 并提示。

### 4.10 CLI(`macdown2`)

- Swift 可执行 target,产物放 `MacDown2.app/Contents/Helpers/macdown2`,随 App 签名公证。
- 子命令(swift-argument-parser **不**引入,手写 20 行参数解析):
  - `macdown2 [file…]`:`NSWorkspace.shared.open(urls, withApplicationAt: <自身所在 .app>)`。
  - `macdown2 .` / `macdown2 <dir>`:打开文件夹工作区 → `open "macdown2://workspace?path=<percent-encoded>"`,App 的 `onOpenURL` 处理(新窗口 + 侧栏)。
  - `echo … | macdown2`:stdin 非 TTY 时读到 EOF 写 `~/Library/Caches/MacDown2/piped-<uuid>.md` 再打开。
  - `macdown2 render <in.md|in.qmd> [-o out.html] [--style NAME] [--self-contained]`:直接用 `MarkdownCore.JSCRenderer`,不启动 App;退出码非 0 表示解析失败(用于 CI/脚本)。
  - `--version`、`--help`。
- 安装:设置 General "安装命令行工具" → 尝试 `ln -sf` 到首个可写的 `/opt/homebrew/bin` / `/usr/local/bin` / `~/.local/bin`;都不可写则显示命令让用户复制(不提权)。

### 4.11 文件夹工作区侧边栏

- `NavigationSplitView` 侧栏(⌘\ 切换),每个**窗口**一个工作区根(`@SceneStorage("workspaceRoot")` 持久化);Quarto 扩展启用时识别 Quarto 项目目录(`_quarto.yml`)并显示徽标(扩展关闭时无此徽标)。
- 树:只列目录与 `.md/.markdown/.qmd/.txt`,忽略 `.git`、`node_modules`、`_site`、`_book`、`_freeze`、`.quarto`、`*_files/`(Quarto/Pandoc 渲染副产物目录)、`.Rproj.user`、`__pycache__`、`.venv`;渲染出的 `.html` 本来就不在列出类型内。忽略规则可在设置里加减;"显示 Quarto 输出" 开关(Quarto 扩展子设置)默认关(Q13)。懒加载子目录;FSEvents 监听整树,`kFSEventStreamCreateFlagIgnoreSelf` + 自己保存后手动刷新(MacDown 教训);被忽略目录内的事件直接丢弃,避免真渲染时 `_files/` 刷屏。
- 打开:双击/回车 → `openDocument(at:)`,目标是**同窗口新标签**。SwiftUI DocumentGroup 在 macOS 用 NSDocument 架构,原生标签遵循系统"打开文档时优先使用标签页"偏好;我们在窗口创建时拿到 `NSWindow`(经 `NSViewRepresentable` 的 `window` 访问器)设 `tabbingMode = .preferred`、`tabbingIdentifier = 工作区根路径`,使同工作区文档归入同一标签组(**S3 验证**;失败回退:不强制标签,新窗口打开)。
- 右键:在 Finder 显示、拷贝路径、新建文件/文件夹、重命名、移到废纸篓。
- 搜索面板(⌘⇧F,侧栏顶部):见 §4.12。

### 4.12 本地搜索(核心内置全文搜索 + 内置扩展 `QmdSearchExtension`,默认关)

**结构**:`SearchService` 调度一组 `SearchProvider`(§4.17)。核心自带 `BuiltinSearchBackend`(id `builtin`),始终可用;`QmdSearchExtension` 启用时注册 id `qmd` 的 provider。
- **关(默认)**:搜索面板只有内置后端;界面无任何 "qmd" 字样、无安装提示;不探测、不读登录 shell 环境、不起进程。
- **开**:`activate()` 只注册 provider;探测 `qmd`、征得同意、注册 collection 都在用户第一次打开搜索面板时经 `prepare(workspace:)` 发生。
- **运行中关闭**:`deactivate()` → `cancelAll()` 杀在途 qmd 进程、停止**由 App 拉起的**常驻服务、面板即时切回内置后端;**不删除**已注册的 collection(用户数据,侧栏右键另有 "停用 qmd 索引")。

**决策:调用 `qmd` CLI,不实现 MCP 客户端;语义查询可选走其常驻 HTTP `/query` 端点(默认关,见下文)。** 理由:(1)CLI 一次一进程、无状态,App 不用实现 MCP 客户端、不用管一个常驻子进程的生命周期;(2)`qmd search`(BM25)不需要任何模型,首次即用;MCP 侧的 `query` 工具会加载重排/扩写模型(0.6–1.7 GB 下载)并常驻显存,对编辑器属过度;(3)`--format json` 为脚本设计,字段稳定。

- 检测:设置里的手动路径优先;否则在 `LoginShellEnvironment.PATH` 里 `command -v qmd`(npm/Bun 全局目录如 `~/.bun/bin`、`/opt/homebrew/bin` 只在登录 shell PATH 里),`qmd --version` 校验(记录最低支持版本,低于则视为未装)。所有 qmd 子进程用登录 shell 环境(含 `QMD_EMBED_MODEL`、`XDG_*`、`QMD_CONFIG_DIR`)。未装 → 回退内置搜索,**扩展子设置页**(仅扩展开启时存在)给安装提示:`npm i -g @tobilu/qmd`(需 Node ≥ 22 或 Bun ≥ 1)+ `brew install sqlite`(系统 SQLite 不能加载扩展,qmd 依赖 sqlite-vec)。
- **索引是全局共享的**:`~/.cache/qmd/index.sqlite` 与用户自己的 collection、其他 agent 共用一个库。因此:
  - 注册前必须征得同意。搜索前 `qmd collection list --format json`(`⚠未验证` 该子命令是否支持 `--format json`;不支持则解析文本或逐个 `qmd collection show`),判断工作区根是否已被某 collection 覆盖(规范化路径前缀,含用户自建的)。已覆盖 → 直接用该 collection,不新建。
  - 未覆盖 → sheet:"把 `<folder>` 注册为 qmd collection `macdown2-<slug>`?qmd 会把这些文件的内容写入它的本地索引 `~/.cache/qmd/index.sqlite`(与你其他 qmd collection 共用)。MacDown2.0 会把它设为不参与你在终端里的默认查询。" [使用内置搜索] [注册]。
  - 注册命令:`qmd collection add <path> --name macdown2-<slug> --mask "**/*.{md,markdown,qmd}"`(**默认 mask 是 `**/*.md`,不含 `.qmd`,必须显式给**),随后 `qmd collection exclude macdown2-<slug>`(README 有 `include/exclude`:排除后不参与用户无 `-c` 的默认查询,避免污染其终端/agent 的结果);我们自己的查询总是带 `-c macdown2-<slug>`。
  - 用户在侧栏右键 "停用 qmd 索引" → `qmd collection remove macdown2-<slug>`(只删我们建的)。
- **索引更新不自动发生**:文件改了要 `qmd update`(重建 BM25,增量、较快)和 `qmd embed`(向量,**重 CPU/GPU**)。策略:搜索前若距上次 `qmd update` > 60 s 且工作区有变更(FolderWatcher 计数)则先跑 `qmd update -c macdown2-<slug>`(`⚠未验证` `update` 是否支持 `-c`;不支持则全量 update);`qmd embed` **绝不**在搜索路径里跑——只在语义搜索开启、App 空闲(无键入 ≥ 2 min、接电源或电量 > 50%)、距上次 ≥ 30 min 时后台跑一次,`qualityOfService = .utility`,用户可在设置里关掉自动嵌入改手动。
- **模型下载**:`vsearch`/`query` 首次使用会自动下载三个 GGUF 模型(embedding ~300 MB、reranker ~640 MB、query-expansion ~1.1 GB,共约 2 GB)到 `~/.cache/qmd/models/`。App 在用户第一次开启 "语义搜索" 时弹说明(体积、位置、耗时),默认关闭。中文语料:默认 embeddinggemma 偏英文,设置页提供一键写 `QMD_EMBED_MODEL=hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf` 到 qmd 子进程环境(**只作用于 App 启动的 qmd 进程**,不改用户 shell;并提示换模型后需 `qmd embed -f` 全量重嵌,由用户确认后执行)。
- **查询分两档**:
  - 边输入边搜(每次按键防抖 250 ms):`qmd search "<q>" -c macdown2-<slug> -n 50 --format json --full-path`(BM25,无模型,冷启动约百毫秒级)。
  - 回车 / 点 "语义" 按钮:`qmd query "<q>" -c … -n 30 --format json --full-path --no-rerank`(扩展 + 向量;重排默认关,需额外模型;开启重排在设置里)。每次 CLI 调用都要加载模型,冷启动慢(秒级),UI 显示进度并可取消(`Process.terminate`)。
  - 结果 JSON → `SearchHit{path, docid, title, score, snippet, line?}`(字段名 `⚠未验证`,S7 对真实输出固化解码器,未知字段忽略)。超时 10 s(search)/ 60 s(query);stderr 进诊断面板。
- **常驻服务(默认关)**:`qmd mcp --http --daemon`(默认 `localhost:8181`,`POST /query`、`/search` 端点,PID 写 `~/.cache/qmd/mcp.pid`,`qmd mcp stop` 停止)能让模型常驻内存、语义查询从秒级降到百毫秒。但其端点**没有鉴权**(README 明说 "the endpoints are unauthenticated",只有 loopback 绑定 + Origin/Host 校验)。方案:设置页提供 "保持 qmd 服务常驻(更快的语义搜索)" 开关,**默认关**,开启时展示安全说明(本机任何进程都能查询你的索引);开启后 App 启动时若 `/health` 不通则由 App 以 `--daemon` 拉起,App 退出时**只停止自己拉起的**(用 PID 文件 + 进程启动时间比对);语义查询改为 `POST http://localhost:8181/query`(请求体 `{"searches":[{"type":"lex","query":…},{"type":"vec","query":…}],"collections":["macdown2-<slug>"],"limit":30,"rerank":false}`,响应 schema `⚠未验证`,S7 固化)。关键词搜仍走 CLI(本来就快)。见 Q11。
- 内置回退:`BuiltinSearchBackend` 遍历工作区(`FileManager.enumerator`,跳过忽略目录,单文件 ≤ 5 MB),`String.range(of:options:[.caseInsensitive, .diacriticInsensitive])` 逐行匹配,返回 行号 + 片段;支持 `"短语"`、`-排除`、正则开关。后台 actor,结果流式回主线程。
- UI:结果按文件分组,点击 → 打开(标签)并定位到行,编辑器高亮匹配。搜索来源角标(qmd / 内置)。

### 4.13 大纲 Inspector

`.inspector(isPresented:)`,数据来自 `RenderResult.outline`(与预览 slug 一致);点击 → 编辑器跳行 + 预览 `scrollTo(#slug)`;当前光标所在节高亮;支持过滤框;Quarto 文档把 `#fig-`/`#tbl-` 锚也列出(次级)。

### 4.14 Sparkle 更新

- Sparkle 2.10.x(SPM,"Embed & Sign";最低 macOS 12;已移除 CocoaPods 发布),`SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)` 在 `App.init` 创建;`CommandGroup(after: .appInfo) { CheckForUpdatesView(updater) }`。
- Info.plist:`SUFeedURL = https://github.com/<owner>/MacDown2.0/releases/latest/download/appcast.xml`(GitHub 的 `latest/download/<asset>` 永久跳转到最新 release 资产),`SUPublicEDKey = <generate_keys 公钥>`,`SUEnableInstallerLauncherService` 不需要(非沙盒)。
- 预发布通道:`sparkle:channel` = `beta`,设置项控制 `allowedChannels`。
- Sparkle 组件(XPC、Autoupdate、Updater.app)经 SPM 由 Xcode 嵌入签名,公证可过(macdown3000 的 CocoaPods 重签脚本不再需要)。

### 4.15 Liquid Glass 与图标

- 窗口:标准 `toolbar` 自动获得玻璃材质;用 `ToolbarSpacer` 分组(格式 / 视图 / 扩展注册的命令,如 Quarto);侧栏与 inspector 用 `NavigationSplitView` 原生样式;状态栏胶囊 `.glassEffect`;不要在内容区大面积玻璃(编辑器/预览需要不透明底色保证可读)。
- 图标:Icon Composer(随 Xcode 26+)产出 `AppIcon.icon`,拖入工程,target General ▸ App Icon 名称与文件名一致;Xcode 编译进 Assets.car 并生成 legacy `.icns` 回退(`⚠未验证` 回退细节,对 min macOS 26 无影响)。文档图标(`.md`/`.qmd`)仍走 `CFBundleDocumentTypes.CFBundleTypeIconFile` 的 `.icns`(`⚠未验证` `.icon` 是否可用于文档图标)。设计:单色玻璃分层(背板 + "M↓"字形 + 高光),暗色/透明/着色四态在 Icon Composer 预览过。
- 外观:全部颜色走 asset catalog 语义色,支持 Increase Contrast / Reduce Transparency(玻璃自动降级)。

### 4.16 外部工具定位与环境(LoginShellEnvironment)

**问题**:从 Finder/Dock/Spawn 启动的 GUI App 由 launchd 拉起,环境里只有 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,没有用户 shell 配置里的任何东西。后果:`quarto`(`/usr/local/bin` 或 `/opt/homebrew/bin`)、`qmd`(npm/Bun 全局目录)、conda/venv 的 Python、R、以及 `QUARTO_PYTHON`、`QMD_EMBED_MODEL` 这类变量全部丢失。本机登录 shell 的 PATH 实测含 `/opt/homebrew/bin`、`~/.local/bin` 等 10+ 条目,与 launchd 默认值完全不同。

**做法**(`actor LoginShellEnvironment`,**首次需要时**后台执行一次并缓存:Quarto 扩展第一次探测真渲染可用性、qmd 扩展第一次 `prepare()`、在「扩展」页展开已启用扩展的探测信息;**只有已启用的扩展经 `ExtensionHost.toolEnvironment` 会触发它,核心功能从不调用**,两个扩展都关闭时它永不执行;不在 App 启动时跑——用户 rc 里的 conda/nvm 初始化可能吃 1–2 s CPU,从不用 Quarto/qmd 的用户应零开销):
1. `shell = ProcessInfo.environment["SHELL"] ?? "/bin/zsh"`;spawn `shell -l -c '/usr/bin/env -0'`(`-l` 登录 shell 读 `.zprofile`/`.zshrc` 的 PATH 设置;`-0` 以 NUL 分隔,值含换行也能正确解析——macOS 自带 `env` 支持 `-0`,已本机验证),`cwd = HOME`,stdin 关闭,超时 5 s(用户 rc 文件里有阻塞命令时不能卡死 App)。
2. 解析为 `[String: String]`;过滤掉 `_`、`SHLVL`、`PWD`、`OLDPWD`、`TERM*`;若失败/超时 → 回退 `ProcessInfo.environment` + 追加 `/opt/homebrew/bin:/usr/local/bin:~/.local/bin` 到 PATH,并在设置页显示 "环境抓取失败(原因)",给 "重试" 按钮。
3. `QuartoLocator`、`QmdLocator`、`QuartoPreviewProcess`、`QmdSearchProvider` 经 `ExtensionHost.toolEnvironment` 从这里取 `environment` 与 `PATH`;**不**用 `Process.launchPath` 直指二进制而不带环境——quarto 自身还要靠 PATH 找 python/R。(核心的 CLI 安装器用固定候选目录,不需要环境。)
4. 设置页 General 显示抓取来源(shell 路径、耗时、PATH 条目数;尚未抓取时显示"尚未需要")与 "重新抓取";两个扩展的子设置页都允许**手动指定可执行文件路径**(覆盖自动定位)。
5. fish 用户:`fish -l -c 'env -0'` 同样可用;`tcsh`/`csh` 不支持 `-c` 的组合时回退到 2 的兜底。

**不做**:不写 `launchctl setenv`、不改用户 `~/.MacOSX/environment.plist`(已废)、不在 App 内解析 rc 文件。

### 4.17 扩展机制(内置可选扩展)

**范围**:只做 Quarto 与 qmd 搜索这两个扩展真正需要的接缝;**不做**通用插件框架,不支持第三方插件,不支持单独下载/安装的插件,没有插件市场。理由:
1. App 开 hardened runtime 且**不加** `com.apple.security.cs.disable-library-validation`,库校验只允许加载与 App 同一 Team ID 签名的代码——第三方 dylib/bundle 装进来也加载不了,做了白做。
2. Apple 的 ExtensionKit 扩展必须进沙盒,而这两个扩展的本质是 spawn `quarto`/`qmd`/node/python/R 并读写用户目录,沙盒里做不到。
3. 对接代码很小(进程封装 + 几十行 UI 注册),真正重的是外部工具自身;再抽一层通用框架只会多出维护面。

**形态**:类似 Obsidian 的"核心插件"——随 App 一起编译、签名、公证、发布;用户只能在「扩展」设置页开/关。

**模块与依赖方向**(见 §2.3):`ExtensionAPI` 只有协议与值类型;`QuartoExtension`、`QmdSearchExtension` 各自实现,只 import `ExtensionAPI`/`MarkdownCore`/系统框架,互不依赖;核心包、`QuickLook`、`CLI` 不得 import `*Extension`;只有 **App target** 一处注册:`ExtensionRegistry.builtin = [QuartoExtension(), QmdSearchExtension()]`。

**协议**(ExtensionAPI,草案):
```swift
public struct ExtensionID: RawRepresentable, Hashable, Sendable { public let rawValue: String }

@MainActor
public protocol MacDown2Extension: AnyObject {
    static var id: ExtensionID { get }                 // "quarto" / "qmd-search"
    static var displayName: LocalizedStringResource { get }
    static var summary: LocalizedStringResource { get }
    static var enabledByDefault: Bool { get }          // Quarto: true;qmd-search: false
    init()                                             // 必须廉价:不探测、不 spawn、不读环境
    func activate(host: any ExtensionHost) async       // 注册 flavor / provider / 命令;同样不得探测外部工具
    func deactivate() async                            // 幂等:杀自己起的进程、停自己拉起的服务、撤销全部注册
    func settingsPane() -> AnyView?                    // 可选,显示在「扩展」页该项下方
}

@MainActor
public protocol ExtensionHost: AnyObject {
    func register(flavor: any DocumentFlavor)
    func register(searchProvider: any SearchProvider)
    func register(commands: [ExtensionCommand])        // 菜单项 / 工具栏项(含 keyboardShortcut),deactivate 时自动撤销
    var toolEnvironment: ToolEnvironment { get }       // §4.16 的懒加载门面;首次 await 才真正抓登录 shell 环境
    var settings: ExtensionSettingsStore { get }       // App Group 偏好,键自动加 "extension.<id>." 前缀
    func presentBanner(_ banner: PreviewBanner, in document: DocumentID)
}

public protocol DocumentFlavor: Sendable {
    var id: FlavorID { get }                           // 必须与 WebAssets/flavors.json 的 key 一致(单测校验)
    func matches(contentType: UTType, firstBytes: Data) -> Bool
    var renderChunks: [String] { get }                 // ["quarto.chunk.js"]
    var previewStylesheets: [String] { get }           // ["quarto-approx.css"]
    func editorDecorations(visibleLines: [Substring], firstLine: Int) -> [DecorationSpan]  // 正则叠加高亮(§4.3.3)
    var fenceLanguageMapper: (@Sendable (String) -> String?)? { get }   // "{python}" → "python",供注入高亮
    var alternatePreviewMode: (any AlternatePreviewMode)? { get }       // Quarto 真渲染;nil = 无
}

@MainActor
public protocol AlternatePreviewMode: AnyObject {
    var title: LocalizedStringResource { get }         // 预览横幅分段控件的标签
    func isAvailable() async -> Availability           // .available / .unavailable(reason);**这里才允许探测外部工具**
    func start(document: DocumentContext) async throws -> URL   // 返回 WebPage 要加载的 URL(如 http://127.0.0.1:<port>/)
    func stop() async                                  // 杀进程;幂等
}

public protocol SearchProvider: Sendable {
    var id: String { get }                             // "builtin" / "qmd"
    var capabilities: SearchCapabilities { get }       // .keyword / .semantic
    func prepare(workspace: URL) async throws -> SearchReadiness   // qmd:检测、征得同意、注册 collection
    func search(_ query: SearchQuery, in workspace: URL) -> AsyncThrowingStream<SearchHit, any Error>
    func cancelAll() async
}
```

**Flavor 静态清单**:`WebAssets/flavors.json`,由 esbuild 构建时从各 `Web/src/<flavor>/manifest.json` 汇总,例如 `{"quarto": {"utTypes": ["org.quarto.qmd"], "chunks": ["quarto.chunk.js"], "stylesheets": ["quarto-approx.css"], "settingKey": "extension.quarto.enabled"}}`。它让**不链接扩展模块**的 Quick Look 与 CLI 也能按同一规则渲染:读 App Group 里 `settingKey` → 开则按清单加载 chunk,关则按普通 Markdown。Swift 侧 `DocumentFlavor.id`/`renderChunks` 必须与清单一致(单测比对)。JS 侧:`render.bundle.js` 暴露 `MacDown2.flavors.register(id, setup)`,各 chunk 加载后自注册;`render(md, opts)` 按 `opts.flavor` 取 setup 构造(并缓存)对应的 markdown-it 实例。

**开关与生命周期**
- 偏好键 `extension.<id>.enabled`(App Group,QL 可读);首次启动按 `enabledByDefault` 写入。
- App 启动:`ExtensionRegistry` 对全部内置扩展调用廉价的 `init()`,只对 enabled 的调用 `activate(host:)`。
- **关闭 = 零开销**:不 activate、不出现菜单/工具栏/设置子页、不加载对应 JS chunk(预览与 JSC 都不加载)、不探测 `quarto`/`qmd`、不触发 `LoginShellEnvironment`、不启动任何进程。`init()` 与 `activate()` 都禁止探测——探测只发生在用户真正用到功能时(`isAvailable()` / `prepare()` / 展开子设置页),这是 code review 清单项,并有测试(§6.1)。
- 运行中关闭:`deactivate()`(契约:幂等、3 s 内完成)。Quarto:每个文档 `stop()`,预览切回核心渲染并把 `.qmd` 按普通 Markdown 重渲染,移除横幅与命令;qmd:`cancelAll()`、停止由 App 拉起的 `qmd mcp --http --daemon`(PID 文件 + 进程启动时间比对),搜索面板即时只剩内置后端。
- 运行中开启:`activate()`;已打开文档重新判定 flavor 并重渲染。
- 「扩展」设置页:每个扩展一行(名称、说明、开关),展开显示其 `settingsPane()`;原 "Quarto" / "Search" 独立分页并入此处(内置搜索的忽略规则留在 General)。

---

## 5. 与 macdown3000 的功能对等清单

图例:保留 = 行为对等;改进 = 更好的实现;砍掉 = 不做(理由见 §1.2 或行内)。M0–M3 = 归属里程碑。

### 5.1 General 偏好

| macdown3000 | 处置 | 实现 | M |
|---|---|---|---|
| firstVersionInstalled / latestVersionInstalled | 保留 | 首启显示 What's New,`help.md` 只开一次 | M1 |
| updateIncludesPreReleases | 保留 | Sparkle channel | M1 |
| supressesUntitledDocumentOnLaunch | 保留 | `DocumentGroup` + `NSDocumentController` 行为开关(`⚠` SwiftUI 下需 `applicationShouldOpenUntitledFile` 等价,S1 顺带验证) | M1 |
| createFileForLinkTarget(点击不存在的相对链接即建文件) | 改进 | 限制在文档目录内,询问后创建 | M2 |

### 5.2 Markdown 偏好(Hoedown 扩展 → markdown-it)

| Hoedown 扩展/选项 | 处置 | markdown-it 侧 | M |
|---|---|---|---|
| NO_INTRA_EMPHASIS 开关 | 砍掉 | CommonMark 规则 | — |
| TABLES | 保留 | 核心 `table` 规则 enable/disable | M0 |
| FENCED_CODE | 保留 | 核心(始终开) | M0 |
| AUTOLINK | 保留 | `linkify: true` | M0 |
| STRIKETHROUGH | 保留 | 核心 `strikethrough` | M0 |
| UNDERLINE(`_x_`→`<u>`) | 保留(默认关) | 自写渲染规则 | M1 |
| SUPERSCRIPT `^x^` | 保留 | @mdit/plugin-sup | M1 |
| 下标 `~x~`(macdown3000 无) | 新增 | @mdit/plugin-sub | M1 |
| HIGHLIGHT `==x==` | 保留 | @mdit/plugin-mark | M1 |
| FOOTNOTES | 保留 | @mdit/plugin-footnote | M1 |
| QUOTE(`"x"`→`<q>`) | 砍掉 | — | — |
| SmartyPants | 保留 | `typographer: true`,引号集可配 | M1 |
| markdownManualRender(手动渲染) | 保留 | ⌘R + 关闭自动渲染开关 | M2 |
| htmlTaskList | 保留+改进 | @mdit/plugin-tasklist;预览勾选写回源码(bridge) | M1 |
| htmlHardWrap | 保留 | `breaks: true` | M1 |
| htmlDetectFrontMatter | 保留+改进 | markdown-it-front-matter;隐藏/表格;YAML 解析失败显示原文 | M1 |
| htmlRendersTOC `[TOC]` | 保留 | 自写规则 | M1 |
| 标题 slug id(3000 新增) | 保留 | markdown-it-anchor + 自写 slugify | M1 |
| CJK 友好强调(新) | 新增 | 已定默认开;自写 inline 规则(约 2 天) | M1 |
| Quarto 语法(新):callout / div / span / cite / crossref / figure / shortcode / 代码单元 | 新增(`QuartoExtension`,默认开) | §4.6.1;`quarto.chunk.js` | M1 |
| Quarto `{{< include >}}` 内联(新) | 新增(`QuartoExtension`) | 直接读文件解析,目录内、深度 ≤ 5 | M1 |
| Quarto Pandoc 方言模拟(标题/引用前需空行) | 新增(`QuartoExtension`) | `quarto` flavor 前置规则 | M2 |

### 5.3 Rendering(HTML)偏好

| 项 | 处置 | M |
|---|---|---|
| htmlTemplateName(Handlebars 模板) | 砍掉 | — |
| htmlStyleName(预览 CSS)+ 用户 Styles 目录 | 保留(主题全部重写) | M1 |
| htmlMathJax / htmlMathJaxInlineDollar | 改进 → KaTeX + 分隔符模式 | M1 |
| htmlSyntaxHighlighting / htmlHighlightingThemeName(Prism) | 改进 → highlight.js + CSS 主题 | M1 |
| htmlLineNumbers | 保留(CSS counter 实现) | M1 |
| htmlCodeBlockAccessory(语言标签/自定义) | 保留(语言标签 on/off) | M1 |
| htmlGraphviz | 砍掉 | — |
| htmlMermaid | 保留(Mermaid 12,懒加载) | M2 |
| htmlDefaultDirectoryUrl(导出默认目录) | 保留 | M1 |
| previewZoomRelativeToBaseFontSize / documentZoomLevel | 保留(预览缩放 ⌘+/−/0) | M2 |
| Jekyll front matter 隐藏 | 保留 | M1 |

### 5.4 Editor 偏好与行为

| 项 | 处置 | M |
|---|---|---|
| 基础字体 / 行距 / 内边距 / 限宽 / 编辑器在右 / 预览模式启动 | 保留 | M1 |
| 自动配对、列表自增、Tab 转空格、块内续前缀、智能 Home | 保留(重写,逻辑对等) | M1 |
| 同步滚动 | 改进(块级行区间插值) | M1 |
| 字数统计 + 选区计数 + 类型 | 保留(CJK 逐字) | M1 |
| 自动保存开关 | 保留(DocumentGroup 自动保存不可关 → 菜单项改为"保存时机"说明;`⚠` 见 S1) | M1 |
| 滚动越过末尾 | 保留 | M2 |
| 文件尾换行 | 保留 | M1 |
| 显示不可见字符 | 保留(`⚠` TextKit 2 可行性) | M3 |
| 无序列表标记类型 | 保留 | M1 |
| 编辑器主题(.style) | 砍掉格式,重写 JSON 主题 | M1 |
| 语法高亮(peg-markdown-highlight) | 改进 → tree-sitter 增量 | M1 |
| 粘贴图片/URL 智能处理(3000 有部分) | 改进 | M2 |
| 格式菜单 H1–H6/段落/粗斜/代码/删除线/下划线/高亮/注释/链接/图片/表格/列表/引用/缩进 | 保留 | M1 |
| 分栏比例 1/4、3/4、均分;隐藏编辑/预览栏;工具栏切换 | 保留 | M1 |
| 查找替换 | 保留(系统 find bar) | M0 |
| CRLF 规范化 | 保留 | M0 |

### 5.5 文档/窗口/工作区

| 项 | 处置 | M |
|---|---|---|
| 多文档、原生标签页 | 保留(DocumentGroup) | M0 |
| 外部修改自动重载 / 冲突提示 | 保留 | M1 |
| 远程卷(SSHFS)原子保存绕过 | 砍掉(交给 NSDocument 默认行为;若反馈再议) | — |
| 文件夹工作区侧栏(`macdown .`、File ▸ Open Folder、⌘\、Reveal in Finder、Copy Path、FSEvents 刷新、跨标签同步宽度/展开态) | 保留+改进(加搜索、新建/重命名) | M2 |
| 大纲(3000 无) | 新增 inspector | M1 |
| 工作区搜索(3000 无) | 新增(内置全文搜索;qmd 为 `QmdSearchExtension`,默认关) | M2 |
| 版本浏览 / iCloud Drive | 新增(系统能力) | M0 |

### 5.6 导出 / 打印 / 复制

| 项 | 处置 | M |
|---|---|---|
| 导出 HTML(含样式/高亮/数学选项) | 保留 | M1 |
| 导出 PDF(打印路径) | 保留(离屏 WKWebView 分页) | M1 |
| PDF 锚点注入 | 砍掉 | — |
| 复制 HTML | 保留 | M1 |
| 打印 | 保留 | M1 |

### 5.7 Quick Look / CLI / 其他

| 项 | 处置 | M |
|---|---|---|
| Quick Look 扩展(`MacDownCore` 共享框架、读用户样式、排除 MathJax/Mermaid/Graphviz) | 保留+改进(KaTeX 可用、同一渲染 bundle;`.qmd` 按 Quarto 扩展开关渲染) | M1 |
| 内置可选扩展机制(`ExtensionAPI` 协议接缝 + 「扩展」设置页) | 新增 | M0 协议 / M1 页面 |
| `macdown` CLI(文件/文件夹/stdin,经 UserDefaults 传参) | 改进(URL scheme;新增 `render` 子命令) | M2 |
| AppleScript sdef | 砍掉 | — |
| 本地化(20 种) | 缩减为 zh-Hans + en(首发) | M3 |
| Sparkle 更新 | 保留(SPM) | M1 |
| Help 文档 `help.md` | 重写(含 Quarto/qmd 章节) | M3 |
| 深链 `macdown2://` | 新增 | M2 |
| Quarto 真渲染(`quarto preview` 子进程 + 切换横幅) | 新增(`QuartoExtension` 子开关,默认开) | M2 |
| 登录 shell 环境抓取(外部工具定位) | 新增(仅已启用扩展触发) | M2 |
| 代码单元 Python/R/YAML 注入高亮 | 新增 | M2 |

---

## 6. 测试策略与流水线

### 6.1 测试分层

| 层 | 工具 | 覆盖 |
|---|---|---|
| JS 纯函数 | `node --test`(`Web/test`) | 块切分、hash、LCS patch 计划、TOC、underline、data-line、字数、Quarto 代码单元解析 |
| 渲染快照 | Swift Testing + `JSCRenderer`(无 WebView) | 语料:macdown3000 `MacDownTests/Fixtures/*.md`(29 个 .md,MIT,带来源注记)+ 自建 Quarto 语料 + CommonMark spec 抽样。黄金文件 = 本项目 bundle 首次输出经人工审阅(macdown3000 的 `.html` 是 Hoedown 输出,只作 diff 参考,不作 oracle)。`SNAPSHOT_UPDATE=1` 重生成。 |
| Swift 单元 | Swift Testing | `ScrollSync` 数学、`LineTable`、`EditingAssistant`(用 `NSTextView` 无窗口实例驱动)、`HoedownCompat` 映射、`QuartoLocator`(QuartoExtension)、`QmdSearchProvider` JSON 解码(QmdSearchExtension,用录制的 fixture)、`BuiltinSearchBackend`、UTType 识别、`FlavorManifest` 与各扩展 `DocumentFlavor.id`/`renderChunks` 一致性 |
| 扩展开/关两态 | Swift Testing + XCUITest | 每个扩展的功能测试在 enabled / disabled 两态各跑一遍。**关闭态断言(零进程、零探测)**:注入可计数的 `ProcessSpawner` 与 `ToolEnvironment` 桩,断言 spawn 次数 = 0、环境抓取次数 = 0;`ExtensionRegistry` 未调用该扩展 `activate`;菜单/工具栏无其命令;`JSCRenderer` 渲染 `.qmd` 后 context 全局无 `MacDown2.flavors.quarto`(chunk 未加载);搜索结果来源只有 `builtin`,面板文案不含 "qmd"。**运行中关闭断言**:用 sleep 脚本冒充 `quarto preview` 起一个真渲染后 `deactivate()`,进程 3 s 内退出、横幅与命令消失;冒充的 qmd daemon(PID 文件)被停止。**QL**:同一 `.qmd` 在开/关两态下输出含 / 不含 `callout` class。 |
| 性能 | XCTest `measure`(与 Swift Testing 并存,仅性能用) | 渲染 50 KB/1 MB、高亮 1 MB、patch 单键;阈值写进测试,超 20% 失败 |
| 集成 | Swift Testing(需 WebKit) | `PreviewBridge` 往返:1 MB 文本经 `callJavaScript` 的耗时与正确性;scheme handler 图片;message handler 事件(回退 scheme 事件通道也各测一遍) |
| UI | XCUITest(≤ 8 条) | 启动建文档;打开 fixture 预览非空;键入后预览更新;⌘⇧E 导出 HTML 文件存在;.qmd 显示 Quarto 徽标;关闭 Quarto 扩展后 .qmd 顶部出现一次性提示且预览无 callout;qmd 扩展关闭时搜索面板只有内置来源;开启 qmd 扩展但未安装时显示安装提示 |
| 手工清单 | `docs/manual-qa.md` | 中文/日文 IME 组字、VoiceOver、深色模式、Increase Contrast、公证后首启 Gatekeeper;**S2 遗留的两项人手确认**:真实触控板/惯性滚动/120 Hz 屏下滚动几何回调 ≥ 30 Hz(30 秒)、Safari Web Inspector 能否挂上 `isInspectable` 页面 |

### 6.2 CI(`.github/workflows/ci.yml`)

- 触发:PR 与 `main` push。Runner `macos-26`(GA,默认 Xcode 26.4.1,arm64;`xcode-27` 标签镜像在 macOS 27 上处于 public preview `⚠`,待 GA 后切换以与本机 Xcode 27 对齐;deployment target 26 两者都能构建)。
- 步骤:checkout → `xcode-select` 固定版本 → `node 22` + `npm ci`(Web/)→ `npm test` → `Scripts/check-web-drift.sh`(重建 bundle 与提交产物逐字节比对)→ `xcodebuild -scheme MacDown2 -destination 'platform=macOS,arch=arm64' build-for-testing` → `test-without-building`(单元+集成,UI 测试在 nightly)→ 上传 `.xcresult`。`grep` 守卫:禁 `.layoutManager`、禁 `import ObjectiveC`。模块边界守卫 `Scripts/check-module-boundaries.sh`:核心包(`Packages/MarkdownCore|EditorKit|PreviewKit|WebAssets|ExtensionAPI`)、`QuickLook/`、`CLI/` 任一文件出现 `import QuartoExtension` 或 `import QmdSearchExtension` 即失败;`swift package show-dependencies --format json` 断言 `*Extension` 目标只依赖 `ExtensionAPI`/`MarkdownCore`。
- Debug 签名:`CODE_SIGN_IDENTITY=-`(ad-hoc),不需证书。

### 6.3 发版(`.github/workflows/release.yml`,触发 `v*` tag)

```
Scripts/bump-version.sh <ver>  →  git tag vX.Y.Z  →  push
CI:
 1. 构建 Release: xcodebuild archive (MARKETING_VERSION 来自 tag, CURRENT_PROJECT_VERSION 自增)
 2. 导出: exportOptions method=developer-id, signingStyle=manual
    - 证书: secrets.DEV_ID_APP_P12 / P12_PASSWORD → 临时 keychain
    - entitlements: App 仅 hardened runtime 必需项(cs.allow-jit 给 JavaScriptCore;不加 disable-library-validation)
      QL 扩展: app-sandbox + 继承只读
 3. 校验: codesign --verify --deep --strict; spctl -a -t exec -vv; 断言 QL 扩展 sandbox entitlement 仍在(不用 --deep 重签)
 4. DMG: Scripts/make-dmg.sh (hdiutil + 背景图 + Applications 链接), codesign DMG
 5. 公证: xcrun notarytool submit --keychain-profile … --wait (凭据用 App Store Connect API key: ISSUER_ID/KEY_ID/P8);
    xcrun stapler staple MacDown2.0.dmg;再 spctl -a -t open --context context:primary-signature -vv
 6. appcast: Sparkle 的 generate_appcast(私钥 secrets.SPARKLE_ED_PRIVATE_KEY 注入)→ appcast.xml(含 delta,保留最近 3 版)
    顺序必须是 公证+staple 之后 再生成(签名覆盖最终字节)
 7. GitHub Release: 上传 DMG、appcast.xml、SHA256SUMS、源码 tarball 链接(自动);release notes 来自 CHANGELOG 段
 8. 冒烟: 在 runner 上 hdiutil attach → 启动 App --version → detach
```
失败任一步不发布(不留 draft 半成品);appcast 以最新 Release 的 `latest/download/appcast.xml` 为准,老版本 App 自动拿到。

---

## 7. 里程碑

工作量按"一名熟练 Swift 开发者 + AI 辅助"估,含测试与 CI。

### M0 · 最小可跑骨架(约 1.5–2 周)

范围:Xcode 工程 + SPM 包空壳(MarkdownCore/EditorKit/PreviewKit/WebAssets + **`ExtensionAPI` 协议定稿** + 两个空的 `*Extension` 模块);`ExtensionRegistry` 与 `extension.<id>.enabled` 偏好读写(不带 UI);`DocumentGroup` 打开/保存 `.md`;TextKit 2 `NSTextView` 纯文本编辑(无高亮);`WebView` 加载预览页;markdown-it bundle(核心 + table/strikethrough/linkify)防抖全量 `innerHTML` 渲染;`flavors.json` 清单与 `JSCRenderer` 的 chunk 加载路径(用一个空 flavor 测试);一套默认预览 CSS;Settings 空页;CI 绿(单元 + drift 检查 + 模块边界守卫);ad-hoc 签名可本机运行;S1/S2 两个 spike 结论落地。
验收:打开 50 KB 文档键入,预览 100 ms 内更新;中文输入法组字不断;⌘Z/⌘S/版本浏览可用;CRLF 文件打开保存不乱;1 MB 文档可打开可编辑(预览可慢);`ExtensionAPI` 编译通过并有 `NoopExtension` 测试覆盖 activate/deactivate 与开关持久化;模块边界守卫脚本在 CI 生效。

### M1 · 可用 beta(约 5–6 周)

范围:tree-sitter 高亮 + 主题;编辑辅助全套;块级 DOM patch;双向滚动同步;相对图片 scheme handler;KaTeX;highlight.js + 行号 + 语言标签;任务列表双向;脚注/mark/sup/sub/underline/smart/TOC/front matter/anchor/**CJK 友好强调(默认开)**;大纲 inspector;状态栏字数;**「扩展」设置页 + `QuartoExtension`(默认开):Quarto 近似预览、`.qmd` UTType、装饰高亮、`quarto.chunk.js` 拆分与按需加载、扩展关闭时的一次性提示、关闭态零进程/零探测测试**;导出 HTML/PDF/复制 HTML/打印;Quick Look 扩展;Sparkle 接入;签名+公证+DMG+appcast 全自动发版(需 Developer 账号就位);首个 `v0.1.0-beta` 上 GitHub Releases。
验收:§4.1.4 性能目标中 50 KB 场景达标;macdown3000 29 个 fixture 快照通过人工审阅;10 个 Quarto 官方示例 `.qmd` 近似预览无报错;关闭 Quarto 扩展后 `.qmd` 按普通 Markdown 预览、顶部出现一次性提示、QL 同步按普通 Markdown 渲染,且 `render.bundle.js` ≤ 800 KB、预览页未请求 `quarto.chunk.js`;QL 在 Finder 空格预览 `.md`/`.qmd`;公证通过、全新 Mac 首启无 Gatekeeper 拦截;Sparkle 从 beta.1 → beta.2 自动更新成功。

### M2 · 功能完整(约 4–5 周)

范围:**LoginShellEnvironment(§4.16)**;文件夹工作区侧栏(树/监听/标签打开/右键/Quarto 副产物隐藏);内置搜索(核心 `SearchProvider`);**`QmdSearchExtension`(默认关):检测、征得同意注册 + `--mask` + `exclude`、节流 `update`、空闲 `embed`、两档查询、常驻服务开关、运行中关闭的收尾**;**Quarto 真渲染(`QuartoExtension` 子开关:`AlternatePreviewMode` 实现、进程生命周期、确认 sheet、切换横幅、日志面板)**;Quarto Pandoc 方言模拟规则;代码单元 Python/R/YAML 注入高亮;Mermaid;CLI(`open`/`.`/stdin/`render`)+ 安装按钮;`macdown2://` 深链;预览缩放;手动渲染模式;粘贴图片;用户主题目录热加载;Liquid Glass 打磨;Icon Composer 图标。
验收:**从 Finder 双击启动的 App**(非 Xcode/终端启动)能定位到 `/opt/homebrew/bin`/`~/.bun/bin` 下的 quarto 与 qmd,且 conda venv 的 Python 在真渲染中被 Quarto 使用;`macdown2 .` 开工作区并在同窗标签打开文件;qmd 扩展关闭时 `pgrep qmd` 与环境抓取计数均为 0 且面板无 "qmd" 字样;开启后 qmd 未装/已装两条路径的搜索均返回可点击结果,注册后 `qmd collection show` 显示 mask 含 `qmd` 且 `qmd search` 不带 `-c` 时不返回该 collection;真渲染:切换 → 确认 → 15 s 内显示 Quarto 输出,保存后 3 s 内刷新,切回近似模式、关窗、以及**运行中关闭 Quarto 扩展**后 `pgrep -f "quarto preview"` 均无残留;关闭「Quarto 真渲染」子开关后无按钮且不探测 quarto;`_files/` 生成不触发侧栏刷新;Mermaid 10 张图文档渲染 < 1 s;1 MB 文档单键 patch < 30 ms。

### M3 · 1.0 打磨(约 3 周)

范围:1 MB+ 文档性能(高亮后台化、patch 退化路径);VoiceOver/键盘可达性;zh-Hans + en 本地化;help.md 与 What's New;不可见字符;fenced code 内注入高亮评估;崩溃回归清零;文档站(GitHub Pages)与 README 截图。
验收:1 MB 文档键入无可感知卡顿(主线程单帧 < 16 ms 占比 > 95%);Accessibility Inspector 无错误;两种语言完整;`v1.0.0` 发布。

合计约 14–16 周。

---

## 8. 风险与对策;Spike 列表

### 8.1 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| `DocumentGroup` + `ReferenceFileDocument` 自动保存/撤销与 NSTextView 不合(自动保存绑 UndoManager;iCloud 重命名后停止保存的已知 bug) | 高:文档层返工 | S1 先验;回退 `NSDocument` + `NSHostingView`,其余模块零改动 |
| ~~`WebPage` 缺 JS→Swift 推送、缺 inspectable、1 MB 字串经 `callJavaScript` 开销~~ → S2 已消除:message handler 可用、`isInspectable` 存在、桥接开销 3.5 ms。残余:Safari Inspector 实际挂载待人手验证(附录 A 第 2 条) | 低 | `WKWebView`+`NSViewRepresentable` 回退保留但预计用不上 |
| TextKit 2 自身 bug(渲染属性不刷、视口高度抖动、IME 选区) | 中 | 不用渲染属性;不伪造高度;IME 期间不写属性;问题集中在 `MarkdownTextView` 一处可替换为 STTextView(BSD/MIT)作为最终回退 |
| Neon 处于预发布;SwiftTreeSitter 与 tree-sitter-markdown 的 `Package.swift` 依赖两套 Swift 绑定 | 中 | pin commit;必要时 fork grammar 的 Package.swift 只保留 C target;Neon 只用 `TreeSitterClient`,UI 接口自写(接口面小) |
| 两套解析器(markdown-it / tree-sitter)边角不一致 | 低 | 文档说明;高亮以"看得懂"为目标,不追求与渲染 1:1 |
| markdown-it 小插件维护参差 | 中 | 只用 2026 年仍活跃的 @mdit/*;自写规则替代停更插件(toc/underline);产物 vendored,升级走 PR 审阅 |
| Quarto 插件随 quarto-dev/quarto 演进,API 漂移 | 低 | 固定 commit vendored,`VENDORED.md` 记录;一年同步一次 |
| **GUI App 拿不到 shell PATH/环境**(launchd 只给 `/usr/bin:/bin:/usr/sbin:/sbin`):quarto、qmd、conda/venv Python、R 找不到;`QUARTO_PYTHON`、`QMD_EMBED_MODEL` 丢失。Xcode/终端里启动能跑,Finder 启动就坏,**最容易漏测** | 高 | §4.16 登录 shell 抓环境(超时 5 s + 兜底 PATH)传给所有子进程;设置里可手动指定路径;M2 验收明确要求"Finder 启动"场景;S9 |
| 用户 rc 文件慢/交互式(nvm、conda init、`echo` 到 stdout) | 中 | `env -0` 输出只取 NUL 分隔键值,忽略杂项;5 s 超时回退;显示抓取耗时供用户自查 |
| `quarto preview` 行为/输出格式变化(端口为"建议"、stdout 文案) | 中 | 同时解析 stdout 文案与 `--log-format json-stream` 日志;版本 ≥ 1.4 门槛;失败即横幅不崩 |
| Quarto 是 Pandoc 方言,近似预览天生有偏差(标题/引用前需空行、文中 YAML 块、项目级 `_quarto.yml`/Lua 过滤器/`_extensions/`/跨文件 crossref、bib/CSL 缺失) | 中(用户误以为 bug) | UI 处处标 "近似";偏差表进 help.md;M2 模拟两条最常见 Pandoc 规则;诊断面板逐条提示"项目配置未应用" |
| 真渲染执行范围含行内代码 `` `{python} expr` `` / `` `r expr` ``,用户可能只以为代码块会跑 | 中(安全认知) | 确认 sheet 明说;编辑区把行内单元标成"可执行"色 |
| 真渲染无源码行号(Pandoc `sourcepos` 仅 commonmark 读取器),无法逐行同步;观感是 Bootstrap 主题 | 中(体验落差) | 横幅明示"同步已关";切回近似模式自动回到当前行;大纲改读输出页标题 |
| 真渲染副产物(`.html`、`*_files/`、`.quarto/`、`_freeze/`)污染侧栏与 FSEvents | 低 | 默认忽略列表 + 事件过滤;不自动删除 |
| qmd 迭代极快(30k star,周更),CLI 参数/JSON 字段变动 | 中 | 版本门槛;解码器忽略未知字段;任何失败回退内置搜索且不打扰用户 |
| qmd 索引全局共享(`~/.cache/qmd`),我们注册的 collection 会出现在用户终端/agent 的默认查询里;默认 mask 不含 `.qmd` | 中 | 注册即 `collection exclude`;显式 `--mask "**/*.{md,markdown,qmd}"`;只删自己建的 collection |
| qmd 首次语义查询自动下载 ~2 GB 模型;默认嵌入模型中文弱;`qmd embed` 重 CPU/GPU;换模型需 `embed -f` 全量重嵌 | 中 | 语义搜索默认关 + 开启前说明;CJK 模型一键开关只作用于 App 子进程;`embed` 只在空闲且满足电源条件时跑;`embed -f` 必须用户确认 |
| `qmd mcp --http` 常驻服务端点无鉴权 | 中(安全) | 默认关;开启时展示风险;只停自己拉起的实例;关键词搜不依赖它 |
| 向用户索引写入的隐私/同意 | 中 | 注册前明确告知写入位置与共享性;不自动 `embed`(下载模型) |
| 扩展 "关闭即零开销" 的承诺被日后改动悄悄打破(有人在 `init()`/`activate()` 里探测工具或读环境) | 中 | §6.1 关闭态零 spawn/零环境抓取测试;code review 清单;`ExtensionHost.toolEnvironment` 首次访问打日志(含调用方)便于排查 |
| 运行中关闭扩展留下孤儿进程 / 半渲染预览 / 残留菜单 | 中 | `deactivate()` 幂等 + 3 s 契约并有测试;命令由 host 统一注册、统一撤销;预览切回核心渲染前先保留上一帧 |
| 扩展开关在 App 与 QL 之间不一致(QL 进程缓存旧值) | 低 | QL 每次 `providePreview` 重读 App Group,不缓存 |
| `flavors.json` 与 Swift `DocumentFlavor` 漂移(改了 chunk 名一边忘改) | 低 | 单测比对;drift 脚本断言主 bundle 不含 Quarto token |
| JSC 在 QL 扩展无 JIT,大文件慢 | 低 | 1 MB 截断 + 超时 2 s 显示纯文本 |
| 尚无 Apple Developer 账号 | 高:M1 发版阻塞 | 开工即申请(审核可能数天);S8 在拿到后立刻做一次端到端公证 |
| AGPL 吓退贡献者;App Store 永久关闭 | 低(已拍板) | README 写清;CLA 问题见 Q1 |
| highlight.js 维护放缓 | 低 | 接口 `CodeHighlighter` 抽象,Shiki 4(JS 正则引擎、无 WASM)可替换 |

### 8.2 Spike 列表(开工前 1–2 周内完成,每个 ≤ 1 天)

| # | 问题 | 做法 | 通过标准 | 失败回退 |
|---|---|---|---|---|
| S1 | DocumentGroup + ReferenceFileDocument + NSTextView 的撤销/自动保存/Versions/iCloud 是否顺畅;能否抑制启动空白文档 | 新建最小工程,NSTextView delegate 返回环境 UndoManager;在 iCloud Drive 建/改/重命名文档 | ⌘Z 跨保存有效;自动保存触发;Versions 可浏览;重命名后仍保存;无空白文档启动可控 | `NSDocument` 子类 + `NSHostingView` |
| S2 ✅ | `WebPage` 桥:`callJavaScript` 传 1 MB 字串往返耗时;JS→Swift 通道;`URLSchemeHandler` 服图片与事件;`webViewOnScrollGeometryChange` 频率;是否可 inspect;PDF 导出 API | 最小工程加 markdown-it bundle | 桥接开销与渲染耗时分别达标(§4.1.4);事件 100/s 不丢;滚动几何回调 ≥ 30 Hz | 未触发(`WKWebView` + `NSViewRepresentable` 回退保留) |
| S3 | 侧栏打开文档进同窗标签 | `openDocument(at:)` + `NSWindow.tabbingMode/.tabbingIdentifier` | 100% 进同一标签组且不受系统偏好影响 | 新窗口打开(功能降级,不阻塞) |
| S4 | TextKit 2 + SwiftTreeSitter + Neon:1 MB 高亮;中/日 IME;grammar 包依赖冲突;tree-sitter-quarto 试跑 | 用 10 个真实 .md/.qmd + 1 MB 生成文档 | 可见区同步高亮 < 8 ms;组字不中断;无符号冲突 | fork grammar Package.swift;IME 期间整体暂停高亮;tree-sitter-quarto 不达标则用叠加方案 |
| S5 | QL 扩展内 JSC 跑 bundle(含 KaTeX)速度;`cid:` 附件;同目录图片可读性;QL 是否执行 JS | 写最小 QL 扩展预览 100 KB 文档 | < 500 ms;图片显示;确认 JS 不执行(或执行也不依赖) | 截断 + 占位图 |
| S6 | Quarto 插件 TS 编译进 bundle;`quarto preview` 进程:端口解析、保存刷新、SIGTERM 退出干净;**从 Finder 启动的 App** 能否用抓到的环境让 Quarto 找到 conda venv 的 Python;`{{< include >}}` 内联 | 用 quarto 官方示例 + 一个 conda 环境;另做一次"运行中关闭扩展" | 10 个示例近似预览无 JS 异常;进程 100% 可回收(含 `deactivate()` 路径);Finder 启动下 `quarto check` 等价输出里 Python 路径指向 venv;Quarto 插件能独立打成 `quarto.chunk.js` 并在主 bundle 之后注册 | 插件按需裁剪;真渲染改用 `quarto render` 一次性;手动指定 Python |
| S7 | qmd CLI:`collection list` 是否有 `--format json`;`search`/`query --format json` 字段;`update` 是否支持 `-c` 与增量时长;`collection exclude` 效果;`mcp --http` 的 `/query` 请求/响应 schema 与 `/health` | 真机安装 qmd(Node 22 + brew sqlite)跑一遍,录制输出作 fixture;验证扩展关闭态面板无 qmd 痕迹、开启后首次打开面板才探测 | 固化 JSON 解码 fixture;`exclude` 后无 `-c` 的 `search` 不返回我们的 collection;关闭态 spawn 计数 0 | 解析文本输出;或仅内置搜索;常驻服务开关砍掉 |
| S8 | 签名公证全链路(需账号):hardened runtime + `allow-jit` + Sparkle SPM + QL 扩展沙盒 | 在 CI 跑一次 release.yml 到 draft | `spctl` 通过,全新用户账户首启无拦截,Sparkle 校验通过 | 调整 entitlements/重签顺序 |
| S9 | 登录 shell 环境抓取:zsh/bash/fish 三种 shell、含 nvm/conda init 的慢 rc、rc 里有 `echo`;`env -0` 解析;超时行为 | 构造三个测试账户 rc | 三种 shell 都拿到完整 PATH;慢 rc 5 s 内回退不卡 UI;值含换行的变量解析正确 | 回退 PATH 兜底 + 手动路径 |
| S10 | 真渲染切换体验原型:近似 ⇄ Quarto 切换时的预览状态保持、横幅、无行号下的大纲读取、杀进程时机 | 用 S6 的进程封装 + 一个 WebPage | 切换 10 次无残留进程、无白屏超过 1 帧(显示上一帧或进度)、切回后滚到当前行 | 简化为"Quarto 输出开新窗口"(功能降级) |

**S2 结论(已完成,2026-10-03,release、M5 Pro、合成 1 MB 文档;详见 §4.1.3 / §4.1.4 / §4.4.1 / §4.4.2 / §4.7)**:`WebPage` 桥可直接用于生产——1 MB 纯桥接开销约 3.5 ms、渲染 61–85 ms(冷启动 139 ms)、全量刷新约 350 ms;JS→Swift 主通道用 `userContentController` 的 message handler(`macdown2-bridge:` scheme 仅作回退),1000 事件 0 丢失/0 重复/顺序不乱;`URLSchemeHandler` 可服页面、JS/CSS、图片(三个坑已入 §4.4.2);滚动几何回调约 57–60 Hz;`WebPage.isInspectable` 存在;`exported(as: .pdf)` 只出长条页(§4.7 待拍板)。遗留人手确认:真实触控板/惯性/120 Hz 滚动、Safari Inspector 实际挂载(列入 `docs/manual-qa.md`)。

---

## 9. 开工前置条件

1. **Xcode 27**(App Store 或 developer.apple.com;需 macOS 26.4+,本机 27.2 可用);首启安装 macOS 26/27 SDK 与 Command Line Tools 关联(`xcode-select -s /Applications/Xcode.app`)。Icon Composer 随 Xcode 附带(Xcode ▸ Open Developer Tool)。
2. **Node.js 22 LTS**(仅改 JS 时需要;`brew install node@22`)→ `cd Web && npm ci && npm run build`。日常 Swift 开发不需要 Node。
3. **Apple Developer Program**(US$99/年)→ 创建 **Developer ID Application** 证书(导出 `.p12` 作 CI 密钥)+ **App Store Connect API Key**(Developer 角色,下载 `.p8`,记 Issuer ID/Key ID)用于 `notarytool`。本机 `xcrun notarytool store-credentials "MacDown2-Notary" --key …p8 --key-id … --issuer …`。
4. **Sparkle EdDSA 密钥**:SPM 拉下 Sparkle 后 `./bin/generate_keys`(私钥进钥匙串;`-x` 导出给 CI secret `SPARKLE_ED_PRIVATE_KEY`;公钥写 `SUPublicEDKey`)。**私钥丢失 = 老用户无法再自动更新**,离线备份一份。
5. **GitHub 仓库**(用户自建;本方案不建):Secrets:`DEV_ID_APP_P12`、`P12_PASSWORD`、`NOTARY_KEY_P8`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID`、`SPARKLE_ED_PRIVATE_KEY`;启用 Actions;分支保护 `main` 要求 CI 通过。
6. **App Group 与标识**:在 Developer 后台登记 App Group `<TEAMID>.io.github.xuanji86.MacDown2.shared`(QL 扩展共享偏好用)。
7. 可选:`quarto`(`brew install --cask quarto`)与 `qmd`(`npm i -g @tobilu/qmd`,需 Homebrew sqlite)用于开发 M1/M2 对应功能;`create-dmg` 不需要(用 `hdiutil`)。
8. 不需要:rustup、CocoaPods、Carthage。

---

## 10. 许可与命名

### 10.1 项目许可:AGPL-3.0-only

- 根目录 `LICENSE` 放 AGPL-3.0 全文;每个源码文件头 `// SPDX-License-Identifier: AGPL-3.0-only`。
- **源码提供义务**:每个 GitHub Release 页自动附带 tag 源码(`Source code (zip/tar.gz)`),Release 说明里再显式写一行"源代码:https://github.com/<owner>/MacDown2.0/tree/vX.Y.Z";App 内 **About 窗口**显示许可名称、源码地址、第三方声明入口(`THIRD_PARTY_NOTICES.md` 内容);`macdown2 --version` 也打印源码地址。Sparkle 的 release notes HTML 底部同样带链接。
- **Mac App Store**:GPL 系许可与 App Store 条款不兼容,本项目**基本不可能**上 App Store;已接受。
- **外部进程不构成链接**:Quarto CLI(GPL-2.0/MIT 混合)与 tobi/qmd(MIT)只通过 `Process` 以独立进程方式被调用、经 stdin/stdout/文件交换数据,不链接、不随本 App 分发,其许可不影响本项目,也不因本项目许可受影响。
- **扩展模块同为 AGPL-3.0**:`ExtensionAPI`、`QuartoExtension`、`QmdSearchExtension` 与 `quarto.chunk.js` 都在本仓、同一许可、随 App 一起编译签名;不存在"插件独立许可"问题(本来也不支持第三方插件)。vendored 的 Quarto markdown-it 插件只进 `quarto.chunk.js`,其版权声明随该 chunk 的 sourcemap/头注释与 `THIRD_PARTY_NOTICES.md` 一起分发。

### 10.2 依赖与 AGPL-3.0 的兼容性清单(逐项)

| 依赖 | 许可 | 与 AGPL-3.0 结合 | 备注 |
|---|---|---|---|
| markdown-it | MIT | ✓ | |
| markdown-it-attrs、markdown-it-front-matter、js-yaml、linkify-it/mdurl/uc.micro(markdown-it 依赖) | MIT | ✓ | |
| markdown-it-anchor | Unlicense(公有领域) | ✓ | |
| @mdit/plugin-mark/sup/sub/footnote/tasklist/katex(mdit-plugins) | MIT | ✓ | |
| KaTeX(含字体,SIL OFL 1.1) | MIT / OFL | ✓(字体 OFL 与 AGPL 并存,不混合) | 保留 KaTeX 版权与 OFL 声明 |
| Mermaid | MIT | ✓ | |
| highlight.js | BSD-3-Clause | ✓ | 保留版权声明与免责条款 |
| Shiki(若替换) | MIT | ✓ | |
| esbuild(仅构建工具,不进产物) | MIT | — | |
| Sparkle 2 | MIT(含少量其他宽松许可组件) | ✓ | GitHub 标 NOASSERTION,以其 LICENSE 文件为准,随 App 附 Sparkle 许可全文 |
| ChimeHQ SwiftTreeSitter / SwiftTreeSitterLayer / Neon / Rearrange | BSD-3-Clause | ✓ | |
| tree-sitter 运行时 | MIT | ✓ | |
| tree-sitter-markdown / -inline | MIT | ✓ | |
| ck37/tree-sitter-quarto(若采用) | MIT | ✓ | |
| quarto-dev/quarto `packages/core/src/markdownit/*` | 仓库级 **AGPL-3.0**;`packages/core/package.json` 标 `"license": "MIT"` 但该目录**无独立 LICENSE 文件**,源文件头仅 "Copyright (C) 2020-2023 Posit Software, PBC" | ✓(无论按 AGPL 还是 MIT 理解都与本项目 AGPL-3.0 兼容) | vendored 时每个文件保留原版权头,加 `// Vendored from quarto-dev/quarto@<commit>, path …; modifications: …`,`VENDORED.md` 汇总;`THIRD_PARTY_NOTICES.md` 以 AGPL-3.0 列出(更保守的理解) |
| macdown3000 复用的 MIT 文件(仅测试语料 `MacDownTests/Fixtures/*.md` 与若干 `.md` 文档片段;**不复用任何代码**) | MIT | ✓ | `Tests/Fixtures/LICENSE-macdown3000`(MIT 全文 + 版权) + 每个文件来源注记 |
| Mou 来源的预览 CSS / 编辑器主题 | 授权来源不清 | ✗ 不复用 | 全部重写 |
| Apple SDK 框架(SwiftUI/AppKit/WebKit/JavaScriptCore/QuickLookUI) | Apple SDK 许可(系统组件) | ✓(系统库例外) | |
| Quarto CLI、qmd | GPL-2.0+/MIT、MIT | 外部进程,不链接 | 见 §10.1 |

`THIRD_PARTY_NOTICES.md` 由 `Scripts/gen-notices.sh` 从 `Web/package-lock.json` 与 `Package.resolved` 半自动生成后人工核对,随每次 release 更新;About 窗口加载同一文件。

### 10.3 命名与声明

- 名称 **MacDown2.0**(已定)。README 首段:"MacDown2.0 is an independent project. It is **not affiliated with, endorsed by, or a fork of** MacDown (uranusjr) or MacDown 3000 (schuyler). No code from either project is used; some Markdown test fixtures from MacDown 3000 are reused under the MIT License (see Tests/Fixtures/LICENSE-macdown3000)."
- **已定标识**(2026-10-03 用户拍板):bundle id `io.github.xuanji86.MacDown2`(不占 `com.uranusjr.*` 命名空间;日后有自有域名也**不要改**——改 bundle id 会丢失用户偏好与 Sparkle 身份,开工前定死);QL 扩展 `io.github.xuanji86.MacDown2.QuickLook`;URL scheme `macdown2`;App Group `<TEAMID>.io.github.xuanji86.MacDown2.shared`;偏好域同 App Group;CLI 名 `macdown2`。
- `.qmd` UTI `org.quarto.qmd` 以 imported 方式声明(非我们所有),若 Quarto 官方日后声明官方 UTI,改为引用之。

---

## 11. 仍待用户拍板的开放问题

> 2026-10-03 用户已定:Q2、Q6 见下表;**Quarto 与 qmd 搜索做成内置可选扩展**(Quarto 默认开、其「真渲染」子开关默认开;qmd 搜索默认关;不做通用插件框架、不支持第三方插件)已定,见 §4.17;其余各项**先按方案默认值执行**(即表中"方案默认"及 §4.8 设置默认值),开发中遇到再调;Q1(CLA)等出现外部贡献者时再定。Q7/Q11/Q12 现在都是 qmd 扩展的子设置,默认值不变。

| # | 问题 | 为什么会改变实现 |
|---|---|---|
| Q1 | **外部贡献者是否签 CLA(或 DCO)?** | AGPL 下不签 CLA,日后改许可/出商业版需全部贡献者同意;签 CLA 会降低贡献意愿。决定影响仓库 `CONTRIBUTING.md` 与 PR 流程(CLA bot)。 |
| Q2 | ✅ 已定:`io.github.xuanji86.MacDown2` | 见 §10.3。 |
| Q3 | 默认是否允许原生 HTML(`html: true`)? | 关闭则更安全、与 GFM 网页一致,但 MacDown 用户习惯开。影响默认值与 CSP 策略复杂度。 |
| Q4 | 预览默认跟随光标还是只跟随滚动? | 影响 ScrollSync 触发源与设置默认值;两者都实现,只定默认。 |
| Q5 | Quarto 真渲染确认策略:每个文档会话问一次(方案默认)/ 按文件夹记住信任 / 每次都问? | 影响是否要持久化"受信任目录"列表及其 UI。 |
| Q6 | ✅ 已定:CJK 友好强调默认开,提前到 M1 | 快照基线按开启状态建立。 |
| Q7 | qmd 语义搜索(`vsearch`/`query`)是否在 UI 暴露? 需用户先 `qmd embed`(下载 ≥ 300 MB 模型) | 不暴露则只做 BM25,设置页更简单。 |
| Q8 | 是否提供 MathJax 分隔符 `\(…\)`/`\[…\]` 兼容为默认开? | 影响旧 MacDown 文档的公式是否开箱即显示;与普通文本中 `\(` 冲突概率低但非零。 |
| Q9 | 是否要 fenced code 内各语言的编辑区高亮(每语法 +0.3–1 MB)? | 影响包体与 M3 范围。 |
| Q10 | 首发本地化只做 zh-Hans + en 是否可接受? | 影响 M3 工作量与 String Catalog 流程。 |
| Q11 | 是否要提供 "常驻 qmd HTTP 服务" 开关? 它让语义搜索快一个量级,但端点无鉴权(本机任何进程可查索引),且 App 要管一个守护进程 | 不做则语义搜索永远冷启动秒级;做则多一套进程/PID 管理与安全说明 UI。 |
| Q12 | `qmd embed`(重 CPU/GPU)由 App 在空闲时自动跑,还是只手动? | 自动需电源/空闲判定与节流逻辑;手动则语义结果可能过期。 |
| Q13 | 文件夹侧栏是否提供 "显示 Quarto 输出(`.html`/`_files/`)" 开关? | 不提供则忽略列表写死,代码更少。 |
| Q14 | 真渲染默认用 `quarto preview`(常驻、保存即刷新)还是 `quarto render` 一次性(无常驻进程、每次手动)? | 方案默认 preview;改为 render 则没有后台进程与端口,但失去保存自动刷新。 |

---

## 附录 A · `⚠未验证` 汇总

> 共 16 条(原 15 条 + 新增第 16 条)。**已查证 3 条**(1、3、13,见文末「已查证」小节);**部分解决 1 条**(2,属性已证实、Safari 实际挂载仍待人手);**仍未验证 13 条**(含第 2 条与新增的第 16 条)。编号保持不变以便与旧引用对应。

1. ~~`WebPage` 是否存在 JS→Swift script message handler 等价 API~~ — **已查证(S2)**:有,`WebPage.Configuration.userContentController`;见「已查证」小节。
2. `WebPage.isInspectable` **存在**(可读写,默认 `false`;S2 已查证),**⚠ 但 Safari Web Inspector 能否真的挂上该页面仍待人手验证**(Safari ▸ 设置 ▸ 高级 ▸ 显示网页开发者功能,开发 ▸ 本机 ▸ App ▸ 页面)。**部分解决。**
3. ~~1 MB 文档 markdown-it 在 WebView 内渲染耗时~~ — **已查证(S2)**:85 ms(完整选项)/ 61 ms(精简)/ 冷启动 139 ms,≤ 150 ms 达标;见「已查证」小节。
4. QL 扩展内 JSC(无 JIT)渲染 100 KB 耗时(目标 ≤ 500 ms);QL HTML 预览不执行 JS 的官方说明;QL 扩展读取同目录图片的权限。
5. `@mdit/plugin-katex` 的 `delimiters` 选项名/是否支持 `\(…\)`。
6. `qmd collection list` 是否支持 `--format json`;`qmd search`/`query --format json` 的字段名;`qmd update -c` 是否存在;`qmd mcp --http` 的 `/query` 响应 schema。
7. `.qmd` 无官方 UTI,`org.quarto.qmd` 为本项目拟定。
8. Icon Composer `.icon` 生成 legacy `.icns` 回退的细节;`.icon` 能否用于文档图标。
9. tree-sitter-markdown 官方 `Package.swift`(依赖 `tree-sitter/swift-tree-sitter`)与 ChimeHQ SwiftTreeSitter 同时引入是否冲突。
10. TextKit 2 下 `NSTextView.showsInvisibleCharacters` 是否可用。
11. SwiftUI DocumentGroup 下抑制启动空白文档、关闭自动保存的可行性。
12. GitHub `xcode-27` runner 标签 GA 时间。
13. ~~`WebPage.exported(as: .pdf)` 的确切签名~~ — **已查证(S2)**,见「已查证」小节;其产出非分页的后续问题见新增第 16 条。
14. fish/tcsh 下 `$SHELL -l -c 'env -0'` 的行为(zsh 已本机验证)。
15. tree-sitter-markdown 的 injections 查询能否匹配 Quarto 的 ```` ```{python} ```` info string(花括号需剥离)。
16. **(新增,S2 引出)「导出 PDF」是接受 `WebPage.exported(as: .pdf)` 的长条页,还是改走分页打印路线**(离屏 `WKWebView` + `NSPrintOperation`,Letter/A4 + 页边距)。长条页路线已实测(屏幕宽度、单页 ≤ 14400 pt),分页打印路线 S2 未测,需在 M1 导出实现前原型验证并拍板(§4.7)。

### 已查证、不再标 ⚠ 的事实(便于复核)

- **S2 spike(2026-10-03,macOS 27.2、Xcode 27.0 SDK、M5 Pro、release 构建、合成 1 MB 文档)**:
  - (原第 1 条)`WebPage.Configuration.userContentController` 是 `WKUserContentController`,`.add(handler, name:)` 可用,JS 端 `window.webkit.messageHandlers.<name>.postMessage`,回调在主线程;100 事件/s × 10 s、瞬发 1000 个、并发 1 MB 渲染下均 0 丢失、0 重复、顺序不乱。`macdown2-bridge:` scheme fetch 通道同样无丢失,作为回退。
  - (原第 3 条)1 MB 纯渲染 85 ms(完整选项)/ 61 ms(精简选项),冷启动首次 139 ms;`callJavaScript` 纯桥接开销约 3.5 ms(p95 4.1 ms);1 MB 全量刷新(渲染 + `innerHTML` + 布局)约 350 ms。
  - (原第 13 条)`func exported(as representation: WebPage.ExportedContentConfiguration) async throws -> Data`,`ExportedContentConfiguration.pdf(region: Region = .contents, allowTransparentBackground: Bool = false)`;产出为屏幕宽度、单页最高 14400 pt 的长条页(1 MB 文档 61 页、1.5 s)。
  - `URLSchemeHandler` 可服页面本身、JS/CSS、PNG/SVG/大图;`urlSchemeHandlers` 创建后不可改;CSP `'self'` 匹配 scheme+host+port;百分号编码 `..` 能穿到 handler 须自行拦截(§4.4.2)。
  - 滚动几何回调约 57–60 Hz(与帧率同步);`WebPage.isInspectable` 存在、可读写、默认 `false`。

- GUI App 的 launchd 默认 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`;本机 zsh 登录 shell PATH 含 `/opt/homebrew/bin`、`~/.local/bin` 等;`/usr/bin/env -0` 可用。
- Pandoc `sourcepos` 扩展只对 commonmark/gfm/commonmark_x 读取器生效(2.11.3 加入)→ Quarto HTML 无源码位置。
- Quarto ≥ 1.4 的行内代码 `` `{python} expr` `` / `` `{r} expr` `` 会执行。
- `quarto preview` 选项:`--port`(建议值,不可用则随机 3000–8000)、`--host`、`--render`、`--no-serve`、`--no-navigate`、`--no-browser`、`--no-watch-inputs`、`--timeout`、`--log`、`--log-format json-stream`;最新 1.10.18(2026-07-24)。
- tobi/qmd(MIT):`collection add --name --mask`、`collection list/show/include/exclude/remove`、`update`、`embed [-f]`、`search`/`vsearch`/`query [--no-rerank] [-c] [-n] [--format json] [--full-path]`、`mcp --http [--daemon]`(`localhost:8181`,PID `~/.cache/qmd/mcp.pid`,端点无鉴权);索引 `~/.cache/qmd/index.sqlite`;模型 `~/.cache/qmd/models/`(三个 GGUF 共约 2 GB);`QMD_EMBED_MODEL` 可换 Qwen3-Embedding(换后 `embed -f`);需 Node ≥ 22 / Bun ≥ 1 与 Homebrew sqlite。
- quarto-dev/quarto 仓库 AGPL-3.0;`packages/core/package.json` 标 MIT 但无独立 LICENSE;源文件头版权 Posit Software, PBC;依赖 markdown-it ^15.0.2、markdown-it-attrs。
- 各依赖版本/许可见 §4.1.2 与 §10.2(2026-10-03 查 npm registry 与 GitHub)。
