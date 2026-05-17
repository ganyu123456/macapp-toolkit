# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
./build.sh   # 编译并自动打开 工具箱.app
```

No Xcode project — pure `swiftc` compilation. The script creates the `.app` bundle structure (`Contents/MacOS`, `Info.plist`, `PkgInfo`) automatically.

## Architecture

Three functionally independent modules with a shared tab shell:

```
MainApp.swift          → @main entry, TabView segmented picker, per-tab window resizing
CalculatorView.swift   → CalculatorModel + CalculatorTab + CalcButtonView
TimerView.swift        → TimerModel + TimerTab + CountdownSetupView
NewsView.swift         → NewsModel + NewsTab + NewsRowView + WebView (WKWebView wrapper)
build.sh               → swiftc *.swift → 工具箱.app
```

Each module owns an `ObservableObject` model instantiated by `MainApp` as `@StateObject` and passed via `.environmentObject()`. Models don't share state.

## Key Constraints

- **No Xcode, no Swift Package Manager** — editing is done on raw `.swift` files; `swiftc` compiles directly. Adding a new file means adding it to `"$BUILD_DIR"/*.swift` (already done via glob).
- **macOS 13+ deployment target** — `windowResizability`, `defaultSize`, and other Ventura-era APIs are used.
- **Apple Silicon only** — target is `arm64-apple-macos13.0`.
- **Frameworks linked**: SwiftUI, AppKit, UserNotifications, WebKit.
- **China network environment** — Google services are blocked. The news module uses 新浪新闻 API (`feed.mix.sina.com.cn`) which is accessible.

## News Data Source

新浪新闻滚动 API — no API key required:
- Headlines: `https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=30`
- Search: append `k=关键词` parameter
- Response is JSON — parsed manually with `JSONSerialization` (no Codable structs).

Articles are displayed in-app via WKWebView (`NSViewRepresentable` wrapper). User can also open in external browser.

## Timer

- `Timer.publish(every: 0.01, on: .main, in: .common)` drives the display at centisecond precision.
- Countdown completion triggers `NSSound.beep()` + `UNUserNotificationCenter` (permission requested in `TimerModel.init()`).
- State machine: `idle → running → paused / finished → idle`.

## Window Management

`MainApp.setWindowSize()` resizes the window per tab (calculator: 320×500, timer: 380×520, news: 700×560). The window has transparent titlebar and is movable by background.
