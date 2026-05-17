import SwiftUI
import AppKit

// MARK: - Terminal Entry
struct TerminalEntry: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let isError: Bool
}

// MARK: - Terminal Model
class TerminalModel: ObservableObject {
    @Published var outputs: [TerminalEntry] = []
    @Published var streamingOutput = ""
    @Published var isRunning = false
    @Published var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

    private var masterFD: Int32 = -1
    private var process: Process?
    private var readSource: DispatchSourceRead?
    var pendingCommand = ""
    private var totalOutput = ""

    var prompt: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentDirectory == home { return "~" }
        if currentDirectory.hasPrefix(home + "/") {
            return "~/" + currentDirectory.dropFirst(home.count + 1)
        }
        return currentDirectory
    }

    func execute(_ command: String) {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }

        // Handle cd
        if cmd.hasPrefix("cd ") || cmd == "cd" {
            let arg = cmd == "cd" ? "~" : String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let path = arg == "~"
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : (arg.hasPrefix("/") ? arg : "\(currentDirectory)/\(arg)")
            let resolved = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                currentDirectory = resolved
                outputs.insert(TerminalEntry(command: cmd, output: "", isError: false), at: 0)
            } else {
                outputs.insert(TerminalEntry(command: cmd, output: "cd: no such directory: \(arg)", isError: true), at: 0)
            }
            return
        }

        pendingCommand = cmd
        totalOutput = ""
        streamingOutput = ""
        isRunning = true

        let dir = currentDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let shellInit = """
        [ -f "$HOME/.zshenv" ] && . "$HOME/.zshenv" 2>/dev/null
        [ -f "$HOME/.zprofile" ] && . "$HOME/.zprofile" 2>/dev/null
        [ -f "$HOME/.zshrc" ] && . "$HOME/.zshrc" 2>/dev/null
        """
        let fullCmd = "\(shellInit)\n\(cmd)"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startProcess(cmd: fullCmd, directory: dir, home: home)
        }
    }

    // MARK: - Interactive input

    func sendInput(_ text: String) {
        guard masterFD >= 0 else { return }
        let line = text + "\n"
        let data = line.data(using: .utf8)!
        data.withUnsafeBytes { ptr in
            _ = write(masterFD, ptr.baseAddress, data.count)
        }
    }

    func interrupt() {
        guard let pid = process?.processIdentifier, pid > 0 else { return }
        kill(pid, SIGINT)
    }

    // MARK: - Process lifecycle

    private func startProcess(cmd: String, directory: String, home: String) {
        let mfd = posix_openpt(O_RDWR)
        guard mfd >= 0 else {
            finalizeWithError("无法打开 PTY")
            return
        }
        grantpt(mfd)
        unlockpt(mfd)
        guard let slaveName = ptsname(mfd) else {
            close(mfd)
            finalizeWithError("无法获取 PTY slave")
            return
        }
        let slaveFD = open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            close(mfd)
            finalizeWithError("无法打开 PTY slave")
            return
        }
        let _ = fcntl(mfd, F_SETFL, fcntl(mfd, F_GETFL) | O_NONBLOCK)
        masterFD = mfd

        var ws = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let _ = ioctl(mfd, TIOCSWINSZ, &ws)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        p.environment = [
            "HOME": home,
            "USER": NSUserName(),
            "TERM": "dumb",
            "LANG": "zh_CN.UTF-8",
            "NO_COLOR": "1",
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
            finalizeWithError("启动进程失败: \(error.localizedDescription)")
            return
        }

        process = p

        // Async read source
        let source = DispatchSource.makeReadSource(fileDescriptor: mfd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 16384)
            defer { buf.deallocate() }
            var done = false
            while !done {
                let n = read(self.masterFD, buf, 16384)
                if n > 0 {
                    let data = Data(bytes: buf, count: n)
                    if let str = String(data: data, encoding: .utf8) {
                        self.totalOutput += str
                        DispatchQueue.main.async {
                            self.streamingOutput = self.stripANSI(self.totalOutput)
                        }
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
            let exitCode = self.process?.terminationStatus ?? -1
            self.process = nil
            self.readSource = nil

            let cleaned = self.stripANSI(self.totalOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.outputs.insert(TerminalEntry(
                    command: self.pendingCommand,
                    output: cleaned,
                    isError: exitCode != 0
                ), at: 0)
                self.streamingOutput = ""
                self.totalOutput = ""
                self.isRunning = false
            }
        }
        readSource = source
        source.resume()

        // Termination handler: delay cancel to allow final output to drain
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.readSource?.cancel()
            }
        }
    }

    private func finalizeWithError(_ msg: String) {
        DispatchQueue.main.async {
            self.outputs.insert(TerminalEntry(
                command: self.pendingCommand,
                output: msg,
                isError: true
            ), at: 0)
            self.streamingOutput = ""
            self.totalOutput = ""
            self.isRunning = false
        }
    }

    func clearOutput() {
        outputs.removeAll()
    }

    // MARK: - ANSI stripping

    private func stripANSI(_ text: String) -> String {
        let esc = "\u{1B}"
        let pattern = esc + "\\[[0-9;?]*[a-zA-Z]"
            + "|" + esc + "\\][^" + esc + "\u{07}]*(?:\u{07}|" + esc + "\\\\)"
            + "|" + esc + "[PX^_][^" + esc + "]*(?:" + esc + "\\\\)?"
            + "|" + esc + "[()][0-9A-Za-z]"
            + "|" + esc + "#[0-9]"
            + "|" + esc + "\\s"
            + "|" + esc + "[=>]"
            + "|\u{07}"
        let stripped: String
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            stripped = regex.stringByReplacingMatches(in: text, options: [],
                range: NSRange(text.startIndex..., in: text), withTemplate: "")
        } else {
            var result = ""
            var inEsc = false
            for ch in text {
                if ch == "\u{1B}" { inEsc = true; continue }
                if inEsc {
                    if ("["..."_").contains(ch) || ("a"..."z").contains(ch) || ("A"..."Z").contains(ch) || ("0"..."9").contains(ch) || ch == ";" || ch == "?" { continue }
                    if ch == "\\" || ch == "\u{07}" { inEsc = false; continue }
                    inEsc = false
                }
                if ch != "\u{07}" { result.append(ch) }
            }
            stripped = result
        }
        // Normalize carriage returns: \r\n → \n, then \r → \n
        return stripped.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// MARK: - Terminal Tab
struct TerminalTab: View {
    @EnvironmentObject var model: TerminalModel
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // History entries
                        ForEach(model.outputs.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text("\(model.prompt) $")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.green)
                                    Text(entry.command)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                if !entry.output.isEmpty {
                                    Text(entry.output)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(entry.isError ? .red : .white.opacity(0.85))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .id(entry.id)
                        }

                        // Live streaming output
                        if model.isRunning {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text("\(model.prompt) $")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.green)
                                    Text(model.pendingCommand)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                if !model.streamingOutput.isEmpty {
                                    Text(model.streamingOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .id("live")
                        }

                        // Welcome
                        if model.outputs.isEmpty && !model.isRunning {
                            VStack(spacing: 6) {
                                Text("工具箱终端")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("支持交互式命令: claude, python3, vim 等")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.35))
                                Text("运行中的进程可在下方输入框发送输入")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.2))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.streamingOutput) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: model.outputs.count) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))

            Divider()

            // Interactive control bar (only when process is running)
            if model.isRunning {
                HStack(spacing: 8) {
                    Button(action: { model.interrupt() }) {
                        Text("Ctrl+C")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.3)))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .help("发送中断信号 (SIGINT)")

                    Text("进程运行中，输入文本后按回车发送")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
            }

            // Input area
            HStack(spacing: 0) {
                Text("\(model.prompt) $")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .fixedSize()

                TextField("", text: $inputText)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if model.isRunning {
                            model.sendInput(inputText)
                        } else {
                            let cmd = inputText.trimmingCharacters(in: .whitespaces)
                            if !cmd.isEmpty {
                                model.execute(inputText)
                            }
                        }
                        inputText = ""
                    }
                    .disabled(false)

                if !inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(model.isRunning ? "发送" : "运行") {
                        let text = inputText.trimmingCharacters(in: .whitespaces)
                        if !text.isEmpty {
                            if model.isRunning {
                                model.sendInput(inputText)
                            } else {
                                model.execute(inputText)
                            }
                            inputText = ""
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.6))
                    )
                    .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Bottom bar
            HStack {
                if model.isRunning {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("执行中...")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(model.prompt)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { model.clearOutput() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text("清空")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.03))
        }
    }
}
