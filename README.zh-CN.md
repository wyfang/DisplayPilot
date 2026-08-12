# Display Pilot

简体中文 · [English](README.md)

[![构建状态](https://github.com/wyfang/DisplayPilot/actions/workflows/build.yml/badge.svg)](https://github.com/wyfang/DisplayPilot/actions/workflows/build.yml)

Display Pilot 是一款轻量级 macOS 菜单栏应用，用一次点击切换整套多显示器配置。它提供预设 A 和预设 B，每套预设都能分别保存每块显示器的开关状态、亮度、对比度调整和分辨率。

## 功能

- 两套完整的逐显示器配置，名称可由用户修改。
- 每块屏幕可独立保存亮度、对比度调整、分辨率和开关状态。
- 从菜单栏一键切换，并提供 `⌘1`、`⌘2` 快捷键。
- 可从菜单栏开启或关闭“开机自启动”。
- 记住已关闭或暂时离线的显示器，之后仍可通过预设重新连接。
- 按安全顺序执行：先连接并等待屏幕稳定，再校验和重试分辨率、重复发送画面参数，最后关闭不需要的屏幕。
- 始终禁止关闭最后一块活动屏幕，降低黑屏风险。
- 从旧版升级时，自动迁移原有的亮度 A / B 数值。

## 系统要求

- macOS 13 或更高版本。
- 从源码构建需要安装 Xcode Command Line Tools。
- 调整亮度和对比度需要运行 [BetterDisplay](https://github.com/waydabber/BetterDisplay)，并启用它的集成功能。显示器开关和分辨率切换不依赖 BetterDisplay。

可在 BetterDisplay 的 **设置 → 应用 → 集成** 中检查集成功能。当前版本的 BetterDisplay 默认启用通知集成。

## 构建

```bash
git clone https://github.com/wyfang/DisplayPilot.git
cd DisplayPilot
./build.sh
```

构建完成后，会生成经过本地临时签名的应用：

```text
dist/Display Pilot.app
```

也可以自定义输出目录：

```bash
DISPLAYPILOT_OUTPUT_DIR=/自定义/输出目录 ./build.sh
```

项目没有经过 Apple 公证。第一次启动时，macOS 可能要求右键点击应用并选择“打开”。

## 使用说明

1. 启动 BetterDisplay 和 Display Pilot。
2. 点击菜单栏中的 Display Pilot 图标。
3. 选择“编辑预设…”。
4. 选择一个预设，可先修改其名称，然后配置每块显示器：
   - 是否开启这块屏幕；
   - 0%～100% 的亮度；
   - -90%～+90% 的软件对比度调整，其中 0% 表示默认效果；
   - macOS 当前报告的一个显示模式。
5. 保存后，在菜单中点击以自定义名称显示的预设项。菜单只显示该名称；打开菜单时也可以使用 `⌘1` 或 `⌘2`。

菜单的第一部分仍然可以单独连接或断开某块显示器。

菜单中的“开机自启动”可以注册或取消 macOS 登录项。若系统要求确认，应用会打开“系统设置 → 通用 → 登录项”。

## 实现原理

### 显示器发现与身份识别

Display Pilot 通过 `CGGetOnlineDisplayList` 枚举显示器。它使用内置/外接标记，以及厂商、型号、序列号和单元编号组合出相对稳定的硬件身份。已知显示器和两套预设会编码为 JSON，保存在 `UserDefaults` 中。

### 显示器开关

应用在 Core Graphics 显示配置事务中修改连接状态。实际的开启和关闭操作使用 macOS 私有接口 `CGSConfigureDisplayEnabled`，然后将配置永久提交。

### 分辨率切换

应用通过 `CGDisplayCopyAllDisplayModes` 获取可用模式。预设会保存逻辑尺寸、实际像素尺寸、刷新率和模式编号。应用预设时，它会从当前可用模式中寻找最接近的匹配，再通过 `CGConfigureDisplayWithDisplayMode` 提交。

### 亮度与对比度

对于预设中处于开启状态的每块显示器，Display Pilot 会通过 `DistributedNotificationCenter` 向 `pro.betterdisplay.BetterDisplay.request` 发送 JSON 请求。请求包含 macOS 显示器 ID，以及 BetterDisplay 的 `brightness` 和软件 `contrast` 参数。调用格式遵循 BetterDisplay 的[集成接口说明](https://github.com/waydabber/BetterDisplay/wiki/Integration-features,-CLI)。

### 应用预设的顺序

```text
连接预设需要的显示器
        ↓
等待 macOS 完成显示器枚举并稳定
        ↓
应用并校验分辨率（必要时重试）
        ↓
应用亮度和对比度（重复发送一次）
        ↓
关闭预设中不需要的显示器
```

如果预设中没有任何目标显示器能够成功开启，应用会保留当前屏幕，不会继续执行可能导致黑屏的关闭操作。

## 项目结构

```text
DisplayPilot.swift          应用逻辑与菜单栏界面
Info.plist                  macOS App Bundle 配置
build.sh                    独立构建和本地临时签名脚本
README.md                   英文说明
README.zh-CN.md             简体中文说明
```

## 重要限制

- `CGSConfigureDisplayEnabled` 是 macOS 私有接口，因此本项目不适合发布到 Mac App Store；未来的 macOS 更新也可能改变或移除这项能力。
- BetterDisplay 必须正在运行，并且启用了集成功能，亮度和对比度命令才会生效。
- 软件无法重新连接一块已经物理拔线的显示器。编辑器保留它只是为了不丢失上次保存的预设参数。
- 可用显示模式可能随着线材、扩展坞、输入接口、镜像、HDR 状态或 macOS 版本发生变化。如果保存的模式已经不可用，应用会报告错误并继续应用预设中的其他设置。
- 应用仅使用本地临时签名，没有经过 Apple 公证。
