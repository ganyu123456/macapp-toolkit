import SwiftUI
import AppKit

// MARK: - App Entry
@main
struct MainApp: App {
    @StateObject private var calcModel = CalculatorModel()
    @StateObject private var timerModel = TimerModel()
    @StateObject private var newsModel = NewsModel()
    @StateObject private var wecomPushModel = WeComPushModel()
    @StateObject private var terminalModel = TerminalModel()

    @State private var selectedTab = 0

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    Text("计算器").tag(0)
                    Text("计时器").tag(1)
                    Text("新闻").tag(2)
                    Text("推送").tag(3)
                    Text("终端").tag(4)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ZStack {
                    switch selectedTab {
                    case 0:
                        CalculatorTab()
                            .environmentObject(calcModel)
                    case 1:
                        TimerTab()
                            .environmentObject(timerModel)
                    case 2:
                        NewsTab()
                            .environmentObject(newsModel)
                    case 3:
                        WeComPushTab()
                            .environmentObject(wecomPushModel)
                    case 4:
                        TerminalTab()
                            .environmentObject(terminalModel)
                    default:
                        EmptyView()
                    }
                }
                .frame(minWidth: 320, minHeight: 420)
            }
            .onAppear {
                setWindowSize(width: 320, height: 500)
            }
            .onChange(of: selectedTab) { tab in
                switch tab {
                case 0: setWindowSize(width: 320, height: 500)
                case 1: setWindowSize(width: 380, height: 520)
                case 2: setWindowSize(width: 700, height: 560)
                case 3: setWindowSize(width: 500, height: 680)
                case 4: setWindowSize(width: 700, height: 500)
                default: break
                }
            }
        }
        .windowResizability(.contentSize)
    }

    private func setWindowSize(width: CGFloat, height: CGFloat) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first else { return }
            var frame = window.frame
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: true, animate: true)
            window.title = "工具箱"
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}
