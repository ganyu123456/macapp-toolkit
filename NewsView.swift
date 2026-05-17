import SwiftUI
import AppKit
import WebKit

// MARK: - News Item
struct NewsItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let link: URL?
    let pubDate: String
    let source: String
    let summary: String

    static func == (lhs: NewsItem, rhs: NewsItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - News Model
enum NewsState {
    case idle
    case loading
    case loaded
    case error(String)
}

class NewsModel: ObservableObject {
    @Published var items: [NewsItem] = []
    @Published var searchText = ""
    @Published var state: NewsState = .idle

    private var dataTask: URLSessionDataTask?

    func loadHeadlines() {
        let url = URL(string: "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=30")!
        fetchNews(from: url)
    }

    func search() {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            loadHeadlines()
            return
        }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let urlStr = "https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=\(encoded)&num=30"
        guard let url = URL(string: urlStr) else { return }
        fetchNews(from: url)
    }

    private func fetchNews(from url: URL) {
        state = .loading
        items = []
        dataTask?.cancel()

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async {
                    self.state = .error("无法连接：\(error.localizedDescription)")
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async {
                    self.state = .error("无数据返回")
                }
                return
            }
            self.parseSinaResponse(data)
        }
        dataTask?.resume()
    }

    private func parseSinaResponse(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any],
                  let code = status["code"] as? Int,
                  code == 0,
                  let articles = result["data"] as? [[String: Any]]
            else {
                DispatchQueue.main.async {
                    self.state = .error("解析失败，API 结构变更")
                }
                return
            }

            let items: [NewsItem] = articles.compactMap { article in
                let title = (article["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { return nil }

                let linkUrl: URL? = {
                    if let urlStr = article["url"] as? String, let u = URL(string: urlStr) {
                        return u
                    }
                    if let wapStr = article["wapurl"] as? String, let u = URL(string: wapStr) {
                        return u
                    }
                    return nil
                }()

                let source = (article["stitle"] as? String) ?? "新浪新闻"
                let summary = (article["intro"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let pubDate: String = {
                    if let ts = article["ctime"] as? String, let seconds = Double(ts) {
                        let date = Date(timeIntervalSince1970: seconds)
                        let fmt = DateFormatter()
                        fmt.dateFormat = "yyyy-MM-dd HH:mm"
                        fmt.locale = Locale(identifier: "zh_CN")
                        return fmt.string(from: date)
                    }
                    return ""
                }()

                return NewsItem(
                    title: title,
                    link: linkUrl,
                    pubDate: pubDate,
                    source: source,
                    summary: summary
                )
            }

            DispatchQueue.main.async {
                self.items = items
                self.state = items.isEmpty ? .error("未找到相关新闻") : .loaded
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .error("JSON 解析错误：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - WKWebView wrapper
struct WebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool

        init(isLoading: Binding<Bool>) {
            self._isLoading = isLoading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}

// MARK: - News Views
struct NewsTab: View {
    @EnvironmentObject var model: NewsModel
    @State private var selectedItem: NewsItem? = nil
    @State private var webLoading = false

    var body: some View {
        VStack(spacing: 0) {
            if let item = selectedItem {
                // Article detail view
                VStack(spacing: 0) {
                    // top bar
                    HStack(spacing: 12) {
                        Button(action: { selectedItem = nil }) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("返回列表")
                                    .font(.system(size: 13))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                if !item.source.isEmpty {
                                    Text(item.source)
                                        .font(.system(size: 11))
                                        .foregroundColor(.blue)
                                }
                                if !item.pubDate.isEmpty {
                                    Text(item.pubDate)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        // open in browser
                        if let url = item.link {
                            Button(action: { NSWorkspace.shared.open(url) }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "safari")
                                        .font(.system(size: 11))
                                    Text("浏览器打开")
                                        .font(.system(size: 11))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    // web view
                    ZStack {
                        if let url = item.link {
                            WebView(url: url, isLoading: $webLoading)
                        } else {
                            Text("无法加载此文章")
                                .foregroundColor(.secondary)
                        }

                        if webLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.primary.opacity(0.05))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // news list view
                VStack(spacing: 0) {
                    // search bar
                    HStack(spacing: 8) {
                        TextField("输入关键词搜索新闻...", text: $model.searchText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.search() }

                        Button(action: {
                            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.loadHeadlines()
                            } else {
                                model.search()
                            }
                        }) {
                            Text("搜索")
                                .font(.system(size: 14, weight: .medium))
                                .frame(height: 28)
                                .padding(.horizontal, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.blue)
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    Divider()

                    // content
                    ZStack {
                        switch model.state {
                        case .idle:
                            VStack(spacing: 12) {
                                Image(systemName: "newspaper")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text("点击搜索按钮或按回车检索新闻")
                                    .foregroundColor(.secondary)
                                Button("加载头条新闻") {
                                    model.loadHeadlines()
                                }
                                .padding(.top, 4)
                            }

                        case .loading:
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.2)
                                Text("正在获取新闻...")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }

                        case .loaded:
                            if model.items.isEmpty {
                                Text("无结果")
                                    .foregroundColor(.secondary)
                            } else {
                                List(model.items) { item in
                                    NewsRowView(item: item)
                                        .onTapGesture {
                                            selectedItem = item
                                        }
                                        .listRowSeparator(.hidden)
                                }
                                .listStyle(.plain)
                            }

                        case .error(let message):
                            VStack(spacing: 12) {
                                Image(systemName: "wifi.slash")
                                    .font(.system(size: 30))
                                    .foregroundColor(.red.opacity(0.6))
                                Text(message)
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                                HStack(spacing: 12) {
                                    Button("重试") {
                                        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                                            model.loadHeadlines()
                                        } else {
                                            model.search()
                                        }
                                    }
                                    Button("加载头条") {
                                        model.searchText = ""
                                        model.loadHeadlines()
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // status bar
                    if case .loaded = model.state {
                        HStack {
                            Text("共 \(model.items.count) 条新闻")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("数据来源：新浪新闻")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.03))
                    }
                }
                .frame(width: 680)
            }
        }
    }
}

struct NewsRowView: View {
    let item: NewsItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if !item.source.isEmpty {
                    Text(item.source)
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                }
                if !item.pubDate.isEmpty {
                    Text(item.pubDate)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
