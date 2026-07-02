import SwiftUI
import AVFoundation
import Speech

// MARK: - Transcription State

enum TranscriptionState {
    case idle
    case transcribing
    case transcribed(String)
    case summarizing
    case summarized(String)
    case error(String)
}

// MARK: - Sheet Item Wrapper

struct SheetItem: Identifiable {
    let id: String
}

// MARK: - Recording Item

struct RecordingItem: Identifiable {
    let id: String
    let name: String
    let url: URL
    let date: Date
    let duration: Double
    var transcriptionState: TranscriptionState = .idle
    var transcriptText: String?
    var summaryText: String?
}

// MARK: - Recording Model

class RecordingModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?
    @Published var apiKey: String = ""

    private var recorder: AVAudioRecorder?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!

    override init() {
        super.init()
        requestPermissions()
        loadRecordings()
        apiKey = UserDefaults.standard.string(forKey: "deepseek_api_key") ?? ""
    }

    private func requestPermissions() {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { _ in }
        }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private var recordingsDir: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/工具箱录音")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadRecordings() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let oldStates = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.transcriptionState) })
        let oldTrans = Dictionary(uniqueKeysWithValues: recordings.compactMap { r in r.transcriptText.map { (r.id, $0) } })
        let oldSum = Dictionary(uniqueKeysWithValues: recordings.compactMap { r in r.summaryText.map { (r.id, $0) } })

        recordings = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                let dur = AVURLAsset(url: url).duration.seconds
                let name = url.deletingPathExtension().lastPathComponent
                let fileId = url.lastPathComponent
                var item = RecordingItem(
                    id: fileId, name: name, url: url, date: date, duration: dur,
                    transcriptionState: oldStates[fileId] ?? .idle
                )
                item.transcriptText = oldTrans[fileId]
                item.summaryText = oldSum[fileId]
                return item
            }
            .sorted { $0.date > $1.date }
    }

    func startRecording() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = recordingsDir.appendingPathComponent("录音 \(df.string(from: Date())).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.record()
            isRecording = true
        } catch {
            errorMessage = "录音启动失败: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        loadRecordings()
    }

    func deleteRecording(_ item: RecordingItem) {
        try? FileManager.default.removeItem(at: item.url)
        loadRecordings()
    }

    func transcribe(_ item: RecordingItem) {
        guard let idx = recordings.firstIndex(where: { $0.id == item.id }) else { return }
        recordings[idx].transcriptionState = .transcribing

        let request = SFSpeechURLRecognitionRequest(url: item.url)
        request.shouldReportPartialResults = false

        speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, let rIdx = self.recordings.firstIndex(where: { $0.id == item.id }) else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.recordings[rIdx].transcriptionState = .error("转写失败: \(error.localizedDescription)")
                }
                return
            }
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.recordings[rIdx].transcriptText = text
                    self.recordings[rIdx].transcriptionState = .transcribed(text)
                }
            }
        }
    }

    func summarize(_ item: RecordingItem) {
        guard case .transcribed(let text) = item.transcriptionState else { return }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            if let idx = recordings.firstIndex(where: { $0.id == item.id }) {
                recordings[idx].transcriptionState = .error("请先设置 DeepSeek API Key")
            }
            return
        }
        guard let idx = recordings.firstIndex(where: { $0.id == item.id }) else { return }
        recordings[idx].transcriptionState = .summarizing

        UserDefaults.standard.set(apiKey, forKey: "deepseek_api_key")

        let prompt = """
        你是一个专业的会议纪要助手。请根据以下会议录音转写内容，生成简洁的会议纪要。

        要求：
        1. 用几句话概括会议主题和目的
        2. 列出关键讨论点和决策
        3. 列出待办事项和责任人（如果提到的话）
        4. 用中文输出

        转写内容：
        \(text)
        """

        let body: [String: Any] = [
            "model": "deepseek-chat",
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": "你是一个专业的会议纪要助手。"],
                ["role": "user", "content": prompt]
            ]
        ]

        guard let url = URL(string: "https://api.deepseek.com/v1/chat/completions") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self,
                      let rIdx = self.recordings.firstIndex(where: { $0.id == item.id }) else { return }

                if let error = error {
                    self.recordings[rIdx].transcriptionState = .error("网络错误: \(error.localizedDescription)")
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.recordings[rIdx].transcriptionState = .error("解析响应失败")
                    return
                }
                if let err = json["error"] as? [String: Any], let msg = err["message"] as? String {
                    self.recordings[rIdx].transcriptionState = .error("API: \(msg)")
                    return
                }
                if let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let msg = first["message"] as? [String: Any],
                   let text = msg["content"] as? String {
                    self.recordings[rIdx].summaryText = text
                    self.recordings[rIdx].transcriptionState = .summarized(text)
                } else {
                    self.recordings[rIdx].transcriptionState = .error("API 返回格式异常")
                }
            }
        }.resume()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { self.loadRecordings() }
    }
}

// MARK: - Recording Tab

struct RecordingTab: View {
    @EnvironmentObject var model: RecordingModel
    @State private var playingItemId: String?
    @State private var selectedItemId: SheetItem?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button(action: {
                    model.isRecording ? model.stopRecording() : model.startRecording()
                }) {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color.red : Color.red.opacity(0.9))
                            .frame(width: 56, height: 56)
                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white).frame(width: 20, height: 20)
                        } else {
                            Circle().fill(Color.white).frame(width: 20, height: 20)
                        }
                    }
                }
                .buttonStyle(.plain)

                Text(model.isRecording ? "录音中..." : "点击开始录音")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("DeepSeek API Key").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    Text("用于 AI 会议总结").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.6))
                }
                SecureField("sk-ant-api03-...", text: $model.apiKey)
                    .font(.system(size: 11, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .onChange(of: model.apiKey) { val in
                        UserDefaults.standard.set(val, forKey: "claude_api_key")
                    }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)

            Divider()

            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
                    .padding(.horizontal, 16).padding(.top, 8)
            }

            if model.recordings.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 28)).foregroundColor(.secondary.opacity(0.4))
                    Text("暂无录音").font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(model.recordings) { item in
                        RecordingRowView(
                            item: item, isPlaying: playingItemId == item.id,
                            onPlay: { playingItemId = (playingItemId == item.id) ? nil : item.id },
                            onTranscribe: { model.transcribe(item) },
                            onSummarize: { model.summarize(item) },
                            onDelete: { model.deleteRecording(item) },
                            onSelect: { selectedItemId = SheetItem(id: item.id) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $selectedItemId) { wrapper in
            DetailSheet(itemId: wrapper.id).environmentObject(model)
        }
    }
}

// MARK: - Recording Row

struct RecordingRowView: View {
    let item: RecordingItem
    let isPlaying: Bool
    let onPlay: () -> Void
    let onTranscribe: () -> Void
    let onSummarize: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: {
                    if isPlaying { audioPlayer?.stop() } else { play() }
                    onPlay()
                }) {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22)).foregroundColor(.blue)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.system(size: 12)).lineLimit(1)
                    HStack {
                        Text(formatDate(item.date))
                        Text(formatDuration(item.duration))
                    }
                    .font(.system(size: 10)).foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                stateBadge

                Spacer()

                if case .idle = item.transcriptionState {
                    actionButton("转写", color: .blue, action: onTranscribe)
                }
                if case .transcribed = item.transcriptionState {
                    actionButton("AI 总结", color: .purple, action: onSummarize)
                    actionButton("查看", color: .secondary, action: onSelect)
                }
                if case .summarized = item.transcriptionState {
                    actionButton("查看结果", color: .green, action: onSelect)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch item.transcriptionState {
        case .idle: EmptyView()
        case .transcribing:
            HStack(spacing: 3) { ProgressView().scaleEffect(0.5); Text("转写中...").font(.system(size: 9)).foregroundColor(.secondary) }
        case .transcribed:
            Text("已转写").font(.system(size: 9)).foregroundColor(.blue)
        case .summarizing:
            HStack(spacing: 3) { ProgressView().scaleEffect(0.5); Text("AI 总结中...").font(.system(size: 9)).foregroundColor(.purple) }
        case .summarized:
            Text("已完成").font(.system(size: 9)).foregroundColor(.green)
        case .error(let msg):
            Text(msg).font(.system(size: 9)).foregroundColor(.red).lineLimit(1)
        }
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.1)))
    }

    private func play() {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: item.url)
            audioPlayer?.play()
        } catch { print("播放失败: \(error)") }
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: d)
    }
    private func formatDuration(_ dur: Double) -> String {
        let t = Int(dur); return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Detail Sheet

struct DetailSheet: View {
    let itemId: String
    @EnvironmentObject var model: RecordingModel
    @Environment(\.dismiss) private var dismiss

    private var item: RecordingItem? {
        model.recordings.first { $0.id == itemId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(item?.name ?? "录音详情").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider()

            if let item = item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch item.transcriptionState {
                        case .idle:
                            Text("点击录音行的「转写」按钮开始语音识别")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 60)
                        case .transcribing:
                            HStack { ProgressView().scaleEffect(0.6); Text("转写中...").font(.system(size: 12)) }
                        case .transcribed(let text):
                            section("转写内容", text)
                            Button("AI 总结") { model.summarize(item) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(.purple)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.purple.opacity(0.1)))
                        case .summarizing:
                            HStack { ProgressView().scaleEffect(0.6); Text("AI 总结中...").font(.system(size: 12)) }
                        case .summarized(let summary):
                            if let text = item.transcriptText { section("转写内容", text) }
                            section("AI 会议总结", summary)
                        case .error(let msg):
                            section("错误", msg, isError: true)
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("录音已删除").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 60)
            }
        }
        .frame(width: 520, height: 460)
    }

    private func section(_ title: String, _ content: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(isError ? .red : .secondary)
            Text(content).font(.system(size: 12)).foregroundColor(isError ? .red : .primary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
