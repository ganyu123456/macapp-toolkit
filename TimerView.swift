import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - Timer Model
enum TimerMode: String, CaseIterable {
    case countdown = "倒计时"
    case stopwatch = "秒表"
}

enum TimerState {
    case idle, running, paused, finished
}

class TimerModel: ObservableObject {
    @Published var mode: TimerMode = .countdown
    @Published var state: TimerState = .idle
    @Published var display = "00:00:00.00"
    @Published var laps: [String] = []

    // countdown settings
    @Published var setHours = 0
    @Published var setMinutes = 0
    @Published var setSeconds = 0

    private var timerCancellable: AnyCancellable?
    private var remainingSeconds: TimeInterval = 0
    private var elapsedSeconds: TimeInterval = 0

    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func switchMode(to newMode: TimerMode) {
        reset()
        mode = newMode
    }

    func toggleStartPause() {
        switch state {
        case .idle:
            start()
        case .running:
            pause()
        case .paused:
            start()
        case .finished:
            reset()
        }
    }

    func start() {
        if state == .idle {
            if mode == .countdown {
                remainingSeconds = TimeInterval(
                    setHours * 3600 + setMinutes * 60 + setSeconds
                )
                guard remainingSeconds > 0 else { return }
            } else {
                elapsedSeconds = 0
                laps.removeAll()
            }
        }
        state = .running

        timerCancellable?.cancel()
        timerCancellable = Timer.publish(every: 0.01, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    func pause() {
        state = .paused
        timerCancellable?.cancel()
        timerCancellable = nil
    }

    func reset() {
        state = .idle
        timerCancellable?.cancel()
        timerCancellable = nil
        laps.removeAll()

        if mode == .countdown {
            remainingSeconds = TimeInterval(
                setHours * 3600 + setMinutes * 60 + setSeconds
            )
            updateCountdownDisplay()
        } else {
            elapsedSeconds = 0
            display = "00:00:00.00"
        }
    }

    func lap() {
        guard mode == .stopwatch, state == .running else { return }
        laps.insert(formatInterval(elapsedSeconds), at: 0)
    }

    private func tick() {
        if mode == .countdown {
            remainingSeconds -= 0.01
            if remainingSeconds <= 0 {
                remainingSeconds = 0
                updateCountdownDisplay()
                state = .finished
                timerCancellable?.cancel()
                timerCancellable = nil
                onCountdownFinished()
                return
            }
            updateCountdownDisplay()
        } else {
            elapsedSeconds += 0.01
            display = formatInterval(elapsedSeconds)
        }
    }

    private func updateCountdownDisplay() {
        display = formatInterval(remainingSeconds)
    }

    private func formatInterval(_ interval: TimeInterval) -> String {
        let total = max(0, interval)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        let cs = Int((total - Double(Int(total))) * 100)
        return String(format: "%02d:%02d:%02d.%02d", h, m, s, cs)
    }

    private func onCountdownFinished() {
        NSSound.beep()

        let content = UNMutableNotificationContent()
        content.title = "计时器"
        content.body = "倒计时结束！"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "countdown-finished",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Timer Views
struct TimerTab: View {
    @EnvironmentObject var model: TimerModel

    var body: some View {
        VStack(spacing: 16) {
            Picker("模式", selection: Binding(
                get: { model.mode },
                set: { model.switchMode(to: $0) }
            )) {
                ForEach(TimerMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .disabled(model.state == .running)

            Text(model.display)
                .font(.system(size: 48, weight: .light, design: .monospaced))
                .foregroundColor(
                    model.state == .finished ? .red : .primary
                )
                .padding(.vertical, 8)

            if model.mode == .countdown && model.state != .running {
                CountdownSetupView()
            }

            if model.mode == .stopwatch && !model.laps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.laps.indices, id: \.self) { idx in
                            HStack {
                                Text("计次 \(model.laps.count - idx)")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(model.laps[idx])
                                    .font(.system(size: 15, design: .monospaced))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(idx % 2 == 0
                                        ? Color.primary.opacity(0.04)
                                        : Color.clear)
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 160)
            }

            Spacer()

            HStack(spacing: 20) {
                if model.mode == .stopwatch && model.state == .running {
                    Button(action: { model.lap() }) {
                        Text("计次")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 70, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: { model.toggleStartPause() }) {
                    Text(buttonLabel)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 90, height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(mode == .countdown
                                    ? (model.state == .finished
                                        ? Color.gray : Color.green)
                                    : (model.state == .running
                                        ? Color.red : Color.green))
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                if model.state == .paused || model.state == .finished {
                    Button(action: { model.reset() }) {
                        Text("重置")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 70, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.primary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 20)
        .frame(width: 360)
    }

    var buttonLabel: String {
        switch model.state {
        case .idle:    return "开始"
        case .running: return "暂停"
        case .paused:  return "继续"
        case .finished: return "完成"
        }
    }

    var mode: TimerMode { model.mode }
}

struct CountdownSetupView: View {
    @EnvironmentObject var model: TimerModel

    var body: some View {
        HStack(spacing: 16) {
            VStack {
                Text("时")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $model.setHours) {
                    ForEach(0..<24) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 50, height: 80)
                .clipped()
            }
            VStack {
                Text("分")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $model.setMinutes) {
                    ForEach(0..<60) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 50, height: 80)
                .clipped()
            }
            VStack {
                Text("秒")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $model.setSeconds) {
                    ForEach(0..<60) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 50, height: 80)
                .clipped()
            }
        }
    }
}
