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
    @Published var isRunning = false
    @Published var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path

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

        // Handle cd specially
        if cmd.hasPrefix("cd ") || cmd == "cd" {
            let arg = cmd == "cd" ? "~" : String(cmd.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            let path = arg == "~"
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : (arg.hasPrefix("/") ? arg : "\(currentDirectory)/\(arg)")
            let resolved = (path as NSString).standardizingPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                currentDirectory = resolved
                outputs.append(TerminalEntry(command: cmd, output: "", isError: false))
            } else {
                outputs.append(TerminalEntry(command: cmd, output: "cd: no such directory: \(arg)", isError: true))
            }
            return
        }

        isRunning = true
        let dir = currentDirectory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", cmd]
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            process.environment = [
                "HOME": home,
                "PATH": envPath,
                "TERM": "xterm-256color",
                "LANG": "zh_CN.UTF-8",
                "USER": NSUserName()
            ]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()

                let group = DispatchGroup()
                group.enter()
                process.terminationHandler = { _ in group.leave() }

                if group.wait(timeout: .now() + 60) == .timedOut {
                    process.terminate()
                    group.wait()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    DispatchQueue.main.async {
                        self.outputs.append(TerminalEntry(
                            command: cmd,
                            output: (output + "\n[超时终止]").trimmingCharacters(in: .whitespacesAndNewlines),
                            isError: true
                        ))
                        self.isRunning = false
                    }
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    self.outputs.append(TerminalEntry(
                        command: cmd,
                        output: trimmed,
                        isError: process.terminationStatus != 0
                    ))
                    self.isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.outputs.append(TerminalEntry(
                        command: cmd,
                        output: "\(error.localizedDescription)",
                        isError: true
                    ))
                    self.isRunning = false
                }
            }
        }
    }

    func clearOutput() {
        outputs.removeAll()
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
                        if model.outputs.isEmpty {
                            VStack(spacing: 6) {
                                Text("工具箱终端")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                Text("支持系统命令、claude、python3 等")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                        }

                        ForEach(model.outputs) { entry in
                            VStack(alignment: .leading, spacing: 1) {
                                // Prompt + command
                                HStack(spacing: 4) {
                                    Text("\(model.prompt) $")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.green)
                                    Text(entry.command)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                // Output
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

                        // Bottom spacer anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .onChange(of: model.outputs.count) { _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))

            Divider()

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
                        let cmd = inputText.trimmingCharacters(in: .whitespaces)
                        if !cmd.isEmpty {
                            model.execute(cmd)
                            inputText = ""
                        }
                    }
                    .disabled(model.isRunning)

                if !inputText.trimmingCharacters(in: .whitespaces).isEmpty, !model.isRunning {
                    Button("运行") {
                        let cmd = inputText.trimmingCharacters(in: .whitespaces)
                        if !cmd.isEmpty {
                            model.execute(cmd)
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
                    .keyboardShortcut(.return, modifiers: [])
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
