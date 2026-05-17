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

    private var dataTask: URLSessionDataTask?

    init() {
        let saved = UserDefaults.standard.string(forKey: "wecom_webhook_url") ?? ""
        webhookURL = saved.isEmpty
            ? "https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=241119fc30528eca8a59c3a6e29f40128b"
            : saved
    }

    func send() {
        let content = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        guard !webhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("请先配置 Webhook 地址")
            return
        }
        guard let url = URL(string: webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            state = .error("Webhook 地址格式无效")
            return
        }

        state = .sending
        dataTask?.cancel()

        let body: [String: Any] = {
            switch messageType {
            case .text:
                return [
                    "msgtype": "text",
                    "text": ["content": content]
                ]
            case .markdown:
                return [
                    "msgtype": "markdown",
                    "markdown": ["content": content]
                ]
            }
        }()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let error = error {
                    self.state = .error("发送失败：\(error.localizedDescription)")
                    self.addRecord(content: content, success: false, response: error.localizedDescription)
                    return
                }
                let respStr: String = {
                    if let data = data, let str = String(data: data, encoding: .utf8) {
                        return str
                    }
                    return "无响应内容"
                }()

                // Check WeCom response: {"errcode":0,"errmsg":"ok"}
                var success = false
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errcode = json["errcode"] as? Int,
                   errcode == 0 {
                    success = true
                }

                if success {
                    self.state = .success
                    self.messageText = ""
                } else {
                    self.state = .error("发送失败：\(respStr)")
                }
                self.addRecord(content: content, success: success, response: respStr)
            }
        }
        dataTask?.resume()
    }

    private func addRecord(content: String, success: Bool, response: String) {
        let record = PushRecord(
            content: content,
            type: messageType,
            timestamp: Date(),
            success: success,
            response: response
        )
        history.insert(record, at: 0)
        if history.count > 100 {
            history = Array(history.prefix(100))
        }
    }

    func clearHistory() {
        history.removeAll()
    }
}

// MARK: - WeCom Push Tab
struct WeComPushTab: View {
    @EnvironmentObject var model: WeComPushModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Top: message compose
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

