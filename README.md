<p align="center"><img src="landing/assets/logo.png" width="96" alt="Hoot 猫头鹰 Logo"></p>
<h1 align="center">Hoot</h1>
<p align="center">截图、图片浏览与编辑，在 Mac 上一气呵成。</p>
<p align="center"><a href="https://hoot.xiezhaoye.site">产品主页</a> · <a href="https://github.com/xiezhaoye/Hoot/releases/latest">下载 macOS 版</a> · <a href="https://github.com/xiezhaoye/Hoot/issues">反馈问题</a> · <a href="LICENSE">MIT License</a></p>

Hoot 是一款使用 Swift、AppKit 和 SwiftUI 开发的 macOS 原生应用，集截图、图片浏览与编辑于一体。

作者希望把 Windows 上 [PicPick](https://picpick.app/) 截图与编辑的顺手体验带到 macOS，于是做了 Hoot。这是受 PicPick 启发的独立实现，并非 PicPick 的官方 macOS 版本或代码移植。

![Hoot 原生截图与编辑界面](landing/assets/hoot-editor.jpg)

## 能做什么

- **快捷截图**：全局快捷键 `⌃⌥A`，区域选择、窗口吸附、多显示器与 Retina 支持；截图后快速复制、编辑、识字、翻译或贴图。
- **标注与编辑**：矩形、椭圆、直线、箭头、画笔、荧光笔、文字、序号、马赛克、模糊、裁剪；支持撤销与重做。
- **精确调整**：可编辑标注的颜色、线宽、填充、不透明度、圆角、阴影、尺寸、位置与排列；文字支持换行和再次编辑。
- **局部覆盖**：选区复制/粘贴或直接抬起为浮动块，移动、拉伸，方向键微调；回车确认、Esc 取消。
- **图片浏览**：按分组管理本地文件夹，单图与缩略图网格，左右翻页、键盘浏览，一键送入编辑器，保留原文件。
- **本地文字识别**：使用 Apple Vision 识别中英文。翻译可使用自行配置的大模型接口，失败或未配置时回退系统本地翻译。
- **悬浮贴图**：`⌃⌥P` 钉住剪贴板图片，支持拖动、缩放和透明度。
- **本地历史**：截图保存在本地，支持搜索、保留数量、保存目录与格式设置；完整取色器、吸管和最近 10 色可用。

滚动长截图、录屏和视频剪辑尚未实现。

## 下载与运行

当前提供 **macOS 15+ / Apple Silicon** 的早期预览版：

1. 从 [GitHub Releases](https://github.com/xiezhaoye/Hoot/releases/latest) 下载并解压 ZIP。
2. 将 `Hoot.app` 拖入“应用程序”。
3. 首次截图时，在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”允许 Hoot，然后重开应用。

当前安装包未经过 Apple 公证；如果系统提示无法验证开发者，可在“系统设置 → 隐私与安全性”确认应用来源后选择“仍要打开”。

OCR 在本机完成。使用大模型翻译时，识别后的文字会发送到你配置的接口；API Key 存在 macOS 钥匙串中。

## 从源码构建

需要 macOS 15+ 与提供 Swift 6 工具链的 Xcode / Command Line Tools。

```bash
swift test
SHOTPAD_IDENTITY=- ./scripts/bundle.sh
open Hoot.app
```

上面的命令使用临时签名。开发时可用 `SHOTPAD_IDENTITY` 指定自己的稳定签名证书，以保持重建后的系统录屏授权。构建脚本默认使用作者本机的开发证书。

## 工程结构

- `Sources/ShotPad`：AppKit / SwiftUI 界面、截图遮罩、画布、浏览和贴图。
- `Sources/ShotPadCore`：标注、渲染、浮动块、撤销、历史、OCR 与翻译逻辑。
- `Tests/ShotPadCoreTests`：核心逻辑回归测试。
- `docs/FEATURES.md`：完整功能与交互约定。
- `landing/`：产品落地页及 Cloudflare Workers 部署配置。

应用显示名是 **Hoot**。为兼容早期版本，SwiftPM 目标 `ShotPad`、bundle ID `com.xiezhaoye.shotpad`、数据目录 `~/Library/Application Support/ShotPad/` 和钥匙串服务名 `ShotPad.LLM` 保持不变。

## 落地页部署

与 XMark 使用相同方式：Cloudflare Workers 托管静态资源，绑定自定义域名。详见 [landing/README.md](landing/README.md)。

## 作者与协议

由 [xiezhaoye](https://github.com/xiezhaoye) 开发，以 [MIT 协议](LICENSE) 开源。欢迎提 Issue 和 Pull Request。
