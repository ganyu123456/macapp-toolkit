import SwiftUI
import AVFoundation

// MARK: - Recording Model

class RecordingModel: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?

    override init() {
        super.init()
        requestPermission()
        loadRecordings()
    }

    private func requestPermission() {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                if !granted {
                    DispatchQueue.main.async { self.errorMessage = "麦克风权限未授权" }
                }
            }
        }
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

        recordings = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let date = attrs[.modificationDate] as? Date else { return nil }
                let asset = AVURLAsset(url: url)
                let duration = asset.duration.seconds
                let name = url.deletingPathExtension().lastPathComponent
                return RecordingItem(id: url.lastPathComponent, name: name,
                                     url: url, date: date, duration: duration)
            }
            .sorted { $0.date > $1.date }
    }

    func startRecording() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let filename = "录音 \(dateFormatter.string(from: Date())).m4a"
        let url = recordingsDir.appendingPathComponent(filename)
        recordingURL = url

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

    // MARK: - AVAudioRecorderDelegate

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.loadRecordings()
        }
    }
}

// MARK: - Recording Item

struct RecordingItem: Identifiable {
    let id: String
    let name: String
    let url: URL
    let date: Date
    let duration: Double
}

// MARK: - Recording Tab

struct RecordingTab: View {
    @EnvironmentObject var model: RecordingModel
    @State private var playingItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Record button area
            VStack(spacing: 12) {
                Button(action: {
                    if model.isRecording {
                        model.stopRecording()
                    } else {
                        model.startRecording()
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(model.isRecording ? Color.red : Color.red.opacity(0.9))
                            .frame(width: 64, height: 64)

                        if model.isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white)
                                .frame(width: 22, height: 22)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 22, height: 22)
                        }
                    }
                }
                .buttonStyle(.plain)

                Text(model.isRecording ? "录音中... 点击停止" : "点击开始录音")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 24)

            Divider()

            // Error
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // Recording list
            if model.recordings.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("暂无录音")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(model.recordings) { item in
                        RecordingRow(
                            item: item,
                            isPlaying: playingItemId == item.id,
                            onPlay: { playingItemId = (playingItemId == item.id) ? nil : item.id },
                            onDelete: { model.deleteRecording(item) }
                        )
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Recording Row

struct RecordingRow: View {
    let item: RecordingItem
    let isPlaying: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var audioPlayer: AVAudioPlayer?

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: item.date)
    }

    private var formattedDuration: String {
        let total = Int(item.duration)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: {
                if isPlaying {
                    audioPlayer?.stop()
                } else {
                    play()
                }
                onPlay()
            }) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack {
                    Text(formattedDate)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(formattedDuration)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func play() {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: item.url)
            audioPlayer?.play()
        } catch {
            print("播放失败: \(error)")
        }
    }
}
