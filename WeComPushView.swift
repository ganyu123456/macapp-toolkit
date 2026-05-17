import SwiftUI
import AppKit

// MARK: - WeCom Push Model
enum PushMsgType: String, CaseIterable {
    case text = "文本"
    case markdown = "Markdown"
}

enum PushState {
    case idle, sending, success, error(String)
}

struct PushRecord: Identifiable {
    let id = UUID()
    let content: String
    let type: PushMsgType
    let timestamp: Date
    let success: Bool
    let response: String
}

let scheduleIntervalOptions: [(label: String, value: TimeInterval)] = [
    ("5 分钟", 300),
    ("10 分钟", 600),
    ("30 分钟", 1800),
    ("1 小时", 3600),
    ("2 小时", 7200),
]

class WeComPushModel: ObservableObject {
    @Published var webhookURL: String {
        didSet {
            UserDefaults.standard.set(webhookURL, forKey: "wecom_webhook_url")
        }
    }
    @Published var messageText = ""
    @Published var messageType: PushMsgType = .text
    @Published var state: PushState = .idle
    @Published var history: [PushRecord] = []

    @Published var scheduleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "wecom_schedule_enabled")
            if scheduleEnabled { startSchedule() } else { stopSchedule() }
        }
    }
    @Published var scheduleInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(scheduleInterval, forKey: "wecom_schedule_interval")
            if scheduleEnabled { startSchedule() }
        }
    }
    @Published var lastScheduledPush: Date?
    @Published var nextScheduledPush: Date?

    private var dataTask: URLSessionDataTask?
    private var scheduleTimer: Timer?

    init() {
        let saved = UserDefaults.standard.string(forKey: "wecom_webhook_url") ?? ""
        webhookURL = saved.isEmpty
            ? "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=241119fc30528eca8a59c3a6e29f40128b"
            : saved
        let savedEnabled = UserDefaults.standard.bool(forKey: "wecom_schedule_enabled")
        scheduleEnabled = savedEnabled
        let savedInterval = UserDefaults.standard.double(forKey: "wecom_schedule_interval")
        scheduleInterval = savedInterval > 0 ? savedInterval : 600
        if scheduleEnabled { startSchedule() }
    }

    // MARK: - Manual send

    func send() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("请先配置 Webhook 地址")
            return
        }
        guard URL(string: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            state = .error("Webhook 地址格式无效")
            return
        }
        state = .sending
        pushContent(content, type: messageType)
        messageText = ""
    }

    // MARK: - Scheduled push

    func toggleSchedule() {
        scheduleEnabled.toggle()
    }

    func fetchAndPushNews() {
        if case .sending = state { return }
        guard !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        state = .sending

        let url = URL(string: "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=5")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.state = .error("获取新闻失败：\(error.localizedDescription)")
                    self.addRecord(content: "定时推送", success: false, response: error.localizedDescription, type: .markdown)
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    self.state = .error("无数据返回")
                    self.addRecord(content: "定时推送", success: false, response: "无数据", type: .markdown)
                }
                return
            }

            var titles: [(title: String, url: String)] = []
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let status = result["status"] as? [String: Any],
                      let code = status["code"] as? Int, code == 0,
                      let articles = result["data"] as? [[String: Any]]
                else {
                    DispatchQueue.main.async {
                        self.state = .error("解析新闻失败")
                        self.addRecord(content: "定时推送", success: false, response: "API 结构变更", type: .markdown)
                    }
                    return
                }

                for article in articles.prefix(5) {
                    guard let title = article["title"] as? String,
                          !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { continue }
                    let urlStr: String = {
                        if let u = article["url"] as? String { return u }
                        if let u = article["wapurl"] as? String { return u }
                        return ""
                    }()
                    titles.append((title: title, url: urlStr))
                }
            } catch {
                DispatchQueue.main.async {
                    self.state = .error("解析新闻失败")
                    self.addRecord(content: "定时推送", success: false, response: error.localizedDescription, type: .markdown)
                }
                return
            }

            guard !titles.isEmpty else {
                DispatchQueue.main.async {
                    self.state = .error("未获取到新闻")
                    self.addRecord(content: "定时推送", success: false, response: "无新闻", type: .markdown)
                }
                return
            }

            let now = Date()
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            let timeStr = fmt.string(from: now)

            var md = "## 新浪头条新闻\n> 更新于 \(timeStr)\n"
            for (i, item) in titles.enumerated() {
                if item.url.isEmpty {
                    md += "\n\(i + 1). \(item.title)"
                } else {
                    md += "\n\(i + 1). [\(item.title)](\(item.url))"
                }
            }

            DispatchQueue.main.async {
                self.lastScheduledPush = now
                self.nextScheduledPush = now.addingTimeInterval(self.scheduleInterval)
            }

            self.pushContent(md, type: .markdown)
        }.resume()
    }

    private func startSchedule() {
        stopSchedule()
        nextScheduledPush = Date().addingTimeInterval(scheduleInterval)
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: scheduleInterval, repeats: true) { [weak self] _ in
            self?.fetchAndPushNews()
        }
    }

    private func stopSchedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        nextScheduledPush = nil
    }

    // MARK: - Internal

    private func pushContent(_ content: String, type: PushMsgType) {
        guard let url = URL(string: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }

        let body: [String: Any] = {
            switch type {
            case .text:
                return ["msgtype": "text", "text": ["content": content]]
            case .markdown:
                return ["msgtype": "markdown", "markdown": ["content": content]]
            }
        }()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        dataTask?.cancel()
        dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.state = .error("发送失败：\(error.localizedDescription)")
                    self.addRecord(content: content, success: false, response: error.localizedDescription, type: type)
                    return
                }
                let respStr: String = {
                    if let data = data, let str = String(data: data, encoding: .utf8) { return str }
                    return "无响应内容"
                }()
                var success = false
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errcode = json["errcode"] as? Int,
                   errcode == 0 {
                    success = true
                }
                if success {
                    self.state = .success
                } else {
                    self.state = .error("发送失败：\(respStr)")
                }
                self.addRecord(content: content, success: success, response: respStr, type: type)
            }
        }
        dataTask?.resume()
    }

    func clearHistory() {
        history.removeAll()
    }

    private func addRecord(content: String, success: Bool, response: String, type: PushMsgType? = nil) {
        let record = PushRecord(
            content: content,
            type: type ?? messageType,
            timestamp: Date(),
            success: success,
            response: response
        )
        history.insert(record, at: 0)
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
    }

    func scheduleIntervalLabel() -> String {
        for option in scheduleIntervalOptions {
            if option.value == scheduleInterval { return option.label }
        }
        return "10 分钟"
    }
}

// MARK: - WeCom Push Tab
struct WeComPushTab: View {
    @EnvironmentObject var model: WeComPushModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // Webhook settings button
                    HStack {
                        Spacer()
                        Button(action: { showSettings.toggle() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 12))
                                Text("Webhook 设置")
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if showSettings {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Webhook 地址")
                                .font(.system(size: 12, weight: .medium))
                            TextField("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=...", text: $model.webhookURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            Text("在企业微信机器人管理页面获取 Webhook 地址")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }

                    // Message type picker
                    Picker("消息类型", selection: $model.messageType) {
                        ForEach(PushMsgType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    // Message input
                    VStack(alignment: .leading, spacing: 6) {
                        if model.messageType == .markdown {
                            Text("支持企业微信 Markdown 语法")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        TextEditor(text: $model.messageText)
                            .font(.system(size: 14))
                            .frame(height: model.messageType == .text ? 80 : 160)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                            .overlay(alignment: .topLeading) {
                                if model.messageText.isEmpty {
                                    Text(model.messageType == .text ? "输入要推送的消息..." : "输入 Markdown 内容...")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    // Send button
                    HStack(spacing: 12) {
                        if case .sending = model.state {
                            ProgressView()
                                .scaleEffect(0.8)
                        }

                        Button(action: { model.send() }) {
                            Text(sendButtonLabel)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 120, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? Color.gray.opacity(0.3) : Color.green)
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .disabled({
                            if case .sending = model.state { return true }
                            return false
                        }())
                    }

                    // status
                    statusView

                    // Schedule section
                    scheduleSection
                }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Bottom: send history
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("发送记录")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if !model.history.isEmpty {
                        Button("清空") {
                            model.clearHistory()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if model.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("暂无发送记录")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.history) { record in
                        PushHistoryRow(record: record)
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Schedule section

    @ViewBuilder
    var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("定时推送")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
            }

            HStack {
                Text("定时推送最新 5 条新浪头条")
                    .font(.system(size: 13))
                Spacer()
                Toggle("", isOn: $model.scheduleEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
            }

            if model.scheduleEnabled {
                HStack(spacing: 8) {
                    Text("间隔:")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Picker("", selection: $model.scheduleInterval) {
                        ForEach(scheduleIntervalOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                    .scaleEffect(0.9)

                    Spacer()

                    Button(action: { model.fetchAndPushNews() }) {
                        HStack(spacing: 3) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 10))
                            Text("立即推送一条")
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.blue.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled({
                        if case .sending = model.state { return true }
                        return false
                    }())
                }

                if let last = model.lastScheduledPush {
                    HStack(spacing: 16) {
                        Text("上次推送: \(formatScheduleDate(last))")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if let next = model.nextScheduledPush {
                            Text("下次推送: \(formatScheduleDate(next))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func formatScheduleDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Status view

    @ViewBuilder
    var statusView: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .sending:
            Text("正在发送...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        case .success:
            Text("发送成功")
                .font(.system(size: 12))
                .foregroundColor(.green)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
    }

    var sendButtonLabel: String {
        switch model.state {
        case .sending: return "发送中..."
        default: return "发送推送"
        }
    }
}

struct PushHistoryRow: View {
    let record: PushRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(record.success ? .green : .red)
                Text(record.type.rawValue)
                    .font(.system(size: 11))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                    )
                Spacer()
                Text(formatDate(record.timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Text(record.content)
                .font(.system(size: 13))
                .lineLimit(2)

            if !record.success {
                Text(record.response)
                    .font(.system(size: 10))
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}
