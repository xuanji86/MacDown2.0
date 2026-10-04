# MacDown2.0 App Icon — 方向 C「Glass 2」分层说明

画布 1024×1024，macOS 图标网格（系统按 824px 连续曲率 squircle 裁切并加 Liquid Glass 材质，图层文件本身**不含**圆角蒙版、阴影或高光）。所有层都对齐同一坐标系，直接叠放即可。

## 图层（自下而上）

| 层 | 文件 | 内容 | 材质 / 透明度意图 |
|---|---|---|---|
| L1 背景 | `01-background.svg` / `.png`（Light）<br>`01-background-dark.svg` / `.png`（Dark） | 对角线性渐变，左上→右下：Light `#5EEAEA → #1A8BDC(45%) → #0B3AA6`；Dark `#1F9FCC → #0D56A5(45%) → #061B54` | 完全不透明，不参与玻璃效果。Light / Dark 各一张，由外观切换。 |
| L2 玻璃「2」 | `02-glass-2.svg` / `.png` | 白色描边数字 2（描边宽 ≈141px，圆头圆角），靠右下、被图标边缘裁切 | 磨砂半透明玻璃：最终观感约 **26% 白** 叠在渐变上，顶缘一道细高光。Clear / Tinted 外观下只保留轮廓光。 |
| L3 字形 M↓ | `03-glyph.svg` / `.png` | Markdown Mark「M↓」白色实心（CC0，Dustin Curtis），圆角化描边 | 不透明白，带自然投影，始终在最上层。Tinted 外观由系统着色。 |

PNG 为 1024px 带 alpha 的栅格版（`01-background*.png` 不透明），SVG 为矢量源文件；两者内容一致。实测 Icon Composer / actool 的 SVG 导入不可靠：带 `<linearGradient>` 的背景 SVG 直接报错，字形与玻璃 2 的 SVG 虽能编译但渲染为空。**在 .icon 里三层都用 PNG**，SVG 只作可编辑源文件。

## Icon Composer 建议设置

| 组 | Specular | Shadow | Translucency | Blur | Lighting |
|---|---|---|---|---|---|
| Background | off | Off | off | — | Combined，层级 Glass 关 |
| Glass 2 | on | Off | on，≈0.7 | Material ≈0.5 | Combined |
| Glyph | on | Natural，≈0.5 | off | — | Individual |

背景也可以不放图层、直接用 Icon Composer 的 Fill：Linear gradient `#5EEAEA → #0B3AA6`（Dark：`#1F9FCC → #061B54`）；只是少了中间停驻点，色调略灰，建议仍用 PNG 图层。

玻璃「2」如果想更含蓄，先降 Translucency 到 0.5，再考虑给层加 opacity；不要动描边粗细。

## `App/AppIcon.icon`（仓库内位置；Design 里不再放第二份）

已按上述设置组装好的 Icon Composer 包（`icon.json` + `Assets/`，三层均为 PNG），用 Xcode 27.0 (27A266a) 自带的 `actool --app-icon MacDown2 --platform macosx --minimum-deployment-target 26.0` 编译通过，产出 `Assets.car` 与回退 `.icns`；actool 渲染出的 Liquid Glass 效果见 （预览图未入库）（M↓ 与磨砂「2」均正确显示）。注意 `icon.json` 的 `groups` 顺序是**首项在最上层**（Glyph → Glass 2 → Background），写反了背景会盖住前景。schema 依据：Xcode 模板 `Icon Composer Icon.xctemplate/___FILEBASENAME___.icon/icon.json`（fill / groups / supported-platforms）＋ 社区逆向整理的 group / layer 键（peterpoliwoda/icon-composer-template README），每个用到的键都单独过了 actool 探针。在 Icon Composer 里打开后请核对一遍 Dark 外观的背景切换和玻璃 2 的强度。

## 小尺寸（appiconset 兜底）

`../appiconset/AppIcon.appiconset/` 里 16×16@1x/@2x 与 32×32@1x 用的是**无「2」的小尺寸版**（M↓ 居中放大，源文件 `../svg/macdown2-C-small-*.svg`），64px 起用完整版，并烘焙了一层轻微投影（与原版 MacDown PNG 一致）。`.icon` 走系统渲染，不需要也不支持按尺寸换稿。

## 来源与许可

- 「M↓」字形：Dustin Curtis 的 Markdown Mark，CC0 公共领域，可自由改绘；本稿按其 208×128 网格重绘并圆角化。
- 原版 MacDown 图标（MIT，Tzu-ping Chung；图标作者 Matt Zanchelli）仅作风格参照，未复用任何像素。

## 运行时图标样式(设置 › 通用 › App 图标)

`App/IconStyles/appicon-{light,dark,clear,tinted}.png`(384 px)由 `Scripts/render-icon-variants.sh` 生成;`.icon` 改动后重跑并提交。Light / Dark 是 Icon Composer `ictool` 的真实渲染;Clear / Tinted 因 ictool 只给出系统派生规则(不透明纯灰 / 纯青绿),改由脚本用 `.icon` 里的 glyph 与「2」两层(位置取自 `icon.json`)加自绘材质合成(需要 python3 + Pillow):Clear 是磨砂白玻璃面板加蓝/薄荷/粉的柔和底色(Dock 里图标背后没有东西可透出,颜色必须烘进去),Tinted 是近黑藏蓝面板、青色发光 M↓、灰蓝「2」。运行时由 `App/Settings/IconStyle.swift` 经 `NSApp.applicationIconImage` 覆盖 Dock 图标,「跟随系统」即不覆盖;磁盘上的图标不改(`NSWorkspace.setIcon` 会破坏签名与 Sparkle 更新)。
