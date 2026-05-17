# 工具箱 — macOS 原生桌面工具应用

一个纯 SwiftUI 编写的 macOS 桌面工具箱，集成**计算器**、**计时器**、**新闻检索**三个功能模块。无需 Xcode，一条命令即可从源码编译为 `.app`。

## 功能

| 模块 | 功能 |
|------|------|
| 计算器 | 四则运算、百分比、正负号、连续运算 |
| 计时器 | 倒计时（时/分/秒设定，归零响铃+系统通知）、秒表（毫秒精度，计次列表） |
| 新闻 | 关键词搜索新闻、头条浏览、应用内 WebView 阅读原文 |

## 快速开始

```bash
# 编译并运行
./build.sh
```

编译后自动生成 `工具箱.app` 并打开。也可以手动打开：

```bash
open 工具箱.app
```

## 开发环境

| 项 | 说明 |
|---|------|
| 语言 | Swift 5 |
| 框架 | SwiftUI + AppKit + WebKit + UserNotifications |
| 编译器 | swiftc（无 Xcode 项目、无 SPM） |
| 最低系统 | macOS 13 Ventura |
| 架构 | Apple Silicon (arm64) |
| 数据源 | 新浪新闻滚动 API（无需 API Key） |

## 项目结构

```
.
├── MainApp.swift         # @main 入口 + Tab 导航 + 窗口管理
├── CalculatorView.swift  # 计算器（模型 + 按钮布局 + 运算逻辑）
├── TimerView.swift       # 计时器（倒计时/秒表双模式 + 通知）
├── NewsView.swift        # 新闻（JSON API 解析 + WKWebView 阅读器）
├── build.sh              # 编译脚本，swiftc → .app bundle
└── CLAUDE.md             # Claude Code 协作参考
```

每个模块独立持有自己的 `ObservableObject` 模型，通过 `MainApp` 注入 `.environmentObject()`，模块之间不共享状态。

## 架构设计

### 窗口导航

顶部 `Picker` 分段控件切换三个 Tab，切换时自动调整窗口尺寸：

- 计算器：320 × 500
- 计时器：380 × 520
- 新闻：700 × 560

### 计算器

状态机管理输入流程：

```
空闲 → 输入数字 → 等待运算符 → 计算 → 显示结果
```

- `isTyping` 标记是否正在输入数字，用于区分"追加字符"和"开始新数字"
- `justEvaluated` 标记刚完成等号运算，用于处理结果后直接输入新数字
- 连续运算：按下运算符时，如已有待处理运算，先执行上一次运算
- 除零返回 `Double.infinity`，显示为"错误"

### 计时器

使用 `Timer.publish(every: 0.01)` 以 10ms 精度驱动显示：

```
idle → running ⇄ paused
         ↓
      finished
```

- 倒计时归零触发 `NSSound.beep()` + `UNUserNotificationCenter` 推送
- 秒表计次通过 `laps.insert(_, at: 0)` 维护倒序列表
- 运行时禁用模式切换，防止状态混乱

### 新闻检索

```
用户输入关键词 → URLSession → 新浪 API → JSONSerialization 解析 → List 展示
                                                                    ↓
                                                        点击 → WKWebView 加载原文
```

- NSViewRepresentable 封装 WKWebView，通过 `WKNavigationDelegate` 追踪加载状态
- URLSession 手动添加 User-Agent 请求头
- 时间戳来自 API 的 Unix timestamp，格式化时指定中文 locale

## 构建细节

`build.sh` 执行流程：

1. 清理旧的 `工具箱.app`
2. 创建 `.app` bundle 目录结构（`Contents/MacOS`、`Contents/Resources`）
3. 调用 `swiftc` 编译所有 `.swift` 文件，链接 4 个 framework
4. 生成 `Info.plist` 和 `PkgInfo`
5. `open` 启动应用

编译参数：

```
swiftc -o Calculator \
  -framework SwiftUI -framework AppKit \
  -framework UserNotifications -framework WebKit \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  *.swift
```

注意：`-parse-as-library` 是 SwiftUI `@main` 入口在单文件编译模式下的必需参数，否则会报 "main attribute cannot be used in a module that contains top-level code"。

## 添加新模块

1. 在项目目录创建 `NewFeature.swift`，包含模型类和视图
2. 在 `MainApp.swift` 中：
   - 添加 `@StateObject private var newModel = NewModel()`
   - 在 `Picker` 中添加新的 `.tag()`
   - 在 `switch selectedTab` 中添加新 case
   - 在 `onChange(of: selectedTab)` 中添加窗口尺寸
3. 运行 `./build.sh`

新文件会被 glob 模式 `"$BUILD_DIR"/*.swift` 自动纳入编译。
