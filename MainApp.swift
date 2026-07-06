import SwiftUI
import AppKit

// MARK: - App Entry

private let windowWidthRatio: CGFloat = 2000.0 / 3456.0
private let windowHeightRatio: CGFloat = 1430.0 / 2158.0

@main
struct MainApp: App {
    @StateObject private var calcModel = CalculatorModel()
    @StateObject private var timerModel = TimerModel()
    @StateObject private var newsModel = NewsModel()
    @StateObject private var wecomPushModel = WeComPushModel()
    @StateObject private var terminalSessionManager = TerminalSessionManager()
    @StateObject private var recordingModel = RecordingModel()
    @StateObject private var calendarModel = CalendarModel()

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
                    Text("录音").tag(5)
                    Text("日历").tag(6)
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
                    case 5:
                        RecordingTab()
                            .environmentObject(recordingModel)
                    case 6:
                        CalendarTab()
                            .environmentObject(calendarModel)
                    default:
                        Color.clear
                    }

                    TerminalContainer(manager: terminalSessionManager)
                        .opacity(selectedTab == 4 ? 1 : 0)
                        .allowsHitTesting(selectedTab == 4)
                }
                .frame(minWidth: 320, minHeight: 420)
            }
            .onAppear {
                centerAndSizeWindow()
            }
            .onChange(of: selectedTab) { _ in }
        }
        .windowResizability(.contentSize)
    }

    private func centerAndSizeWindow() {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first,
                  let screen = window.screen ?? NSScreen.main else { return }

            let screenFrame = screen.visibleFrame
            let width = screenFrame.width * windowWidthRatio
            let height = screenFrame.height * windowHeightRatio
            let x = screenFrame.midX - width / 2
            let y = screenFrame.midY - height / 2

            window.setFrame(NSRect(x: x, y: y, width: width, height: height),
                            display: true, animate: false)
            window.title = "工具箱"
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
    }
}
