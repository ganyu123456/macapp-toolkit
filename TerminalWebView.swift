import SwiftUI
import WebKit

// MARK: - Terminal Coordinator
class TerminalCoordinator: NSObject, WKScriptMessageHandler, ObservableObject {
    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?
    private var readQueue: DispatchQueue?
    private weak var webView: WKWebView?

    @Published var isRunning = false
    private var shellRestartAttempt = 0

    func setWebView(_ wv: WKWebView) {
        webView = wv
    }

    // MARK: - Start shell

    func startShell() {
        guard !isRunning else { return }
        isRunning = true

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shellInit = """
        [ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv" 2>/dev/null
        [ -f "$HOME/.zprofile" ] && . "$HOME/.zprofile" 2>/dev/null
        [ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc" 2>/dev/null
        export PROMPT='%F{green}%1~%f %# '
        """
        let cmd = "\(shellInit)\nexec /bin/zsh -l"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startProcess(cmd: cmd, directory: home, home: home)
        }
    }

    // MARK: - Input from xterm.js

    func sendInput(_ data: String) {
        guard masterFD >= 0 else { return }
        guard let utf8 = data.data(using: .utf8) else { return }
        utf8.withUnsafeBytes { ptr in
            _ = write(masterFD, ptr.baseAddress, utf8.count)
        }
    }

    // MARK: - Resize

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    // MARK: - Interrupt

    func interrupt() {
        guard let pid = process?.processIdentifier, pid > 0 else { return }
        kill(pid, SIGINT)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "terminalInput":
            if let data = message.body as? String {
                sendInput(data)
            }
        case "terminalResize":
            if let dict = message.body as? [String: Any],
               let cols = dict["cols"] as? Int,
               let rows = dict["rows"] as? Int {
                resize(cols: cols, rows: rows)
            }
        default:
            break
        }
    }

    // MARK: - Process lifecycle

    private func startProcess(cmd: String, directory: String, home: String) {
        let mfd = posix_openpt(O_RDWR)
        guard mfd >= 0 else {
            writeToTerminal("\r\n\u{1B}[31m无法打开 PTY\u{1B}[0m\r\n")
            finishWithRestart()
            return
        }
        grantpt(mfd)
        unlockpt(mfd)
        guard let slaveName = ptsname(mfd) else {
            close(mfd)
            writeToTerminal("\r\n\u{1B}[31m无法获取 PTY slave\u{1B}[0m\r\n")
            finishWithRestart()
            return
        }
        let slaveFD = open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            close(mfd)
            writeToTerminal("\r\n\u{1B}[31m无法打开 PTY slave\u{1B}[0m\r\n")
            finishWithRestart()
            return
        }
        _ = fcntl(mfd, F_SETFL, fcntl(mfd, F_GETFL) | O_NONBLOCK)

        if masterFD >= 0 {
            close(masterFD)
        }
        masterFD = mfd

        var ws = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(mfd, TIOCSWINSZ, &ws)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        p.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "TERM": "xterm-256color",
            "LANG": "zh_CN.UTF-8",
            "PATH": "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        ]

        let si = dup(slaveFD)
        let so = dup(slaveFD)
        let se = dup(slaveFD)
        close(slaveFD)

        p.standardInput = FileHandle(fileDescriptor: si, closeOnDealloc: true)
        p.standardOutput = FileHandle(fileDescriptor: so, closeOnDealloc: true)
        p.standardError = FileHandle(fileDescriptor: se, closeOnDealloc: true)

        do {
            try p.run()
        } catch {
            close(mfd)
            masterFD = -1
            writeToTerminal("\r\n\u{1B}[31m启动进程失败: \(error.localizedDescription)\u{1B}[0m\r\n")
            finishWithRestart()
            return
        }

        process = p
        shellRestartAttempt = 0

        let queue = DispatchQueue(label: "terminal.pty.read", qos: .userInitiated)
        readQueue = queue

        let source = DispatchSource.makeReadSource(fileDescriptor: mfd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 16384)
            defer { buf.deallocate() }
            var done = false
            while !done {
                let n = read(self.masterFD, buf, 16384)
                if n > 0 {
                    let data = Data(bytes: buf, count: n)
                    DispatchQueue.main.async {
                        self.sendDataToTerminal(data)
                    }
                } else {
                    done = true
                    if n == 0 { source.cancel() }
                }
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.masterFD >= 0 {
                close(self.masterFD)
                self.masterFD = -1
            }
            self.process?.waitUntilExit()
            self.process = nil
            self.readSource = nil
            self.readQueue = nil

            DispatchQueue.main.async {
                self.finishWithRestart()
            }
        }
        readSource = source
        source.resume()

        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.readSource?.cancel()
            }
        }
    }

    private func finishWithRestart() {
        isRunning = false
        shellRestartAttempt += 1
        guard shellRestartAttempt <= 5 else {
            writeToTerminal("\r\n\u{1B}[31m[终端已停止]\u{1B}[0m\r\n")
            return
        }
        // Auto-restart shell after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startShell()
        }
    }

    // MARK: - Send data to xterm.js (batched)

    private var pendingData = Data()
    private var batchTimer: DispatchSourceTimer?

    private func sendDataToTerminal(_ data: Data) {
        pendingData.append(data)
        if batchTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 0.016)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                self.batchTimer?.cancel()
                self.batchTimer = nil
                self.flushData()
            }
            batchTimer = timer
            timer.resume()
        }
    }

    private func flushData() {
        guard !pendingData.isEmpty, let wv = webView else { return }
        let batch = pendingData
        pendingData = Data()

        let b64 = batch.base64EncodedString()
        let js = "window.writeToTerminal(Uint8Array.from(atob('\(b64)'), c => c.charCodeAt(0)));"
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    private func writeToTerminal(_ text: String) {
        guard let wv = webView else { return }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        wv.evaluateJavaScript("window.writeToTerminal('\(escaped)');", completionHandler: nil)
    }

    // MARK: - Cleanup

    func cleanup() {
        shellRestartAttempt = 99 // Prevent auto-restart
        readSource?.cancel()
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        process?.terminate()
        process = nil
    }

    deinit {
        cleanup()
    }
}

// MARK: - Terminal WebView (NSViewRepresentable)
struct TerminalWebView: NSViewRepresentable {
    let coordinator: TerminalCoordinator

    func makeCoordinator() -> TerminalCoordinator {
        coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let controller = WKUserContentController()
        controller.add(coordinator, name: "terminalInput")
        controller.add(coordinator, name: "terminalResize")
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsBackForwardNavigationGestures = false
        coordinator.setWebView(wv)

        if let resourcesURL = Bundle.main.resourceURL?.appendingPathComponent("xterm"),
           let htmlURL = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "xterm") {
            wv.loadFileURL(htmlURL, allowingReadAccessTo: resourcesURL)
        }

        // Start shell after a short delay to allow xterm.js to initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak coordinator] in
            coordinator?.startShell()
        }

        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: TerminalCoordinator) {
        coordinator.cleanup()
    }
}

// MARK: - Terminal Container
struct TerminalContainer: View {
    @ObservedObject var coordinator: TerminalCoordinator

    var body: some View {
        VStack(spacing: 0) {
            TerminalWebView(coordinator: coordinator)

            Divider()

            // Bottom control bar
            HStack {
                if coordinator.isRunning {
                    Button(action: { coordinator.interrupt() }) {
                        Text("Ctrl+C")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.3)))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("发送中断信号 (SIGINT)")

                    Text("终端运行中 — 直接在终端中输入命令")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text("就绪")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.03))
        }
    }
}
