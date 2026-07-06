import SwiftUI
import AppKit
import EventKit

// MARK: - Calendar Model

class CalendarModel: ObservableObject {
    @Published var displayedMonth: Date
    @Published var displayedYear: Int
    @Published var selectedDate: Date?

    private let eventStore = EKEventStore()
    private let calendar = Calendar.current

    /// Merged marked dates: key "yyyy-MM-dd" → [label1, label2, ...]
    private var markData: [String: [String]] = [:]
    private var loadedYears = Set<Int>()

    private var cachedEvents: [EKEvent] = []
    private var cacheRange: (start: Date, end: Date)?
    private var eventsLoading = false

    @Published var calendarAccessGranted = false
    @Published var accessChecked = false

    init() {
        let now = Date()
        let comps = Calendar.current.dateComponents([.year, .month], from: now)
        displayedMonth = Calendar.current.date(from: comps)!
        displayedYear = comps.year!
        selectedDate = Date()

        // Load hardcoded solar terms + festivals immediately (instant)
        loadLocalData()

        // Then refresh with API for better holiday accuracy
        checkAccess()
    }

    // MARK: - Mark lookup

    /// Returns all labels for a date joined by "·"
    func markLabel(for date: Date) -> String? {
        let labels = markData[dateKey(date)] ?? []
        return labels.isEmpty ? nil : labels.joined(separator: "·")
    }

    // MARK: - Calendar Access

    private func checkAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:
            calendarAccessGranted = true; accessChecked = true
            loadEvents()
        case .notDetermined:
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { [weak self] granted, _ in
                    DispatchQueue.main.async {
                        self?.calendarAccessGranted = granted
                        self?.accessChecked = true
                        if granted { self?.loadEvents() }
                    }
                }
            } else {
                eventStore.requestAccess(to: .event) { [weak self] granted, _ in
                    DispatchQueue.main.async {
                        self?.calendarAccessGranted = granted
                        self?.accessChecked = true
                        if granted { self?.loadEvents() }
                    }
                }
            }
        default:
            calendarAccessGranted = false; accessChecked = true
        }
    }

    // MARK: - Event Loading

    func loadEvents() {
        guard calendarAccessGranted, !eventsLoading else { return }
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))!
        let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart)!
        let start = calendar.date(byAdding: .day, value: -7, to: monthStart)!
        let end = calendar.date(byAdding: .day, value: 7, to: monthEnd)!
        if let existing = cacheRange, existing.start <= start && existing.end >= end { return }
        cacheRange = (start, end)
        eventsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let predicate = self.eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = self.eventStore.events(matching: predicate)
            DispatchQueue.main.async { self.cachedEvents = events; self.eventsLoading = false }
        }
    }

    func eventsForDate(_ date: Date) -> [EKEvent] {
        guard calendarAccessGranted else { return [] }
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return cachedEvents.filter { event in
            if event.isAllDay { return event.startDate < dayEnd && event.endDate > dayStart }
            return event.startDate >= dayStart && event.startDate < dayEnd
        }.sorted { a, b in
            if a.isAllDay != b.isAllDay { return !a.isAllDay }
            return a.startDate < b.startDate
        }
    }

    func hasEvents(_ date: Date) -> Bool { !eventsForDate(date).isEmpty }

    func eventDotColors(_ date: Date) -> [Color] {
        let colors = eventsForDate(date).compactMap { event -> Color? in
            guard let nsColor = event.calendar.color else { return nil }
            return Color(nsColor: nsColor)
        }
        let seen = NSMutableSet(); var unique: [Color] = []
        for c in colors where !seen.contains(c.description) { seen.add(c.description); unique.append(c) }
        return Array(unique.prefix(3))
    }

    // MARK: - Data loading — local + remote

    private func loadLocalData() {
        loadSolarTerms()
        loadFestivals()
    }

    /// Fetch official holidays from NateScarlet/holiday-cn (State Council announcements)
    func fetchYearData(_ year: Int) {
        guard !loadedYears.contains(year) else { return }
        loadedYears.insert(year)

        let urlStr = "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/\(year).json"
        guard let url = URL(string: urlStr) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let days = json["days"] as? [[String: Any]]
            else { return }

            DispatchQueue.main.async {
                self.objectWillChange.send()
                for day in days {
                    guard let dateStr = day["date"] as? String,
                          let name = day["name"] as? String,
                          let isOff = day["isOffDay"] as? Bool
                    else { continue }

                    let label = isOff ? "\(name)休" : "\(name)班"
                    var existing = self.markData[dateStr] ?? []
                    existing.removeAll { $0.hasPrefix(name) }
                    existing.append(label)
                    self.markData[dateStr] = existing
                }
            }
        }.resume()
    }

    // MARK: - Solar terms (C-value formula, 21st century)

    private func loadSolarTerms() {
        // Each solar term: (month, C_value, name)
        // Formula: day = int(C + 0.2422*(Y-2000) - int((Y-2000)/4))
        let terms: [(Int, Double, String)] = [
            (1,  5.4055, "小寒"), (1,  20.12,  "大寒"),
            (2,  3.87,   "立春"), (2,  18.73,  "雨水"),
            (3,  5.63,   "惊蛰"), (3,  20.46,  "春分"),
            (4,  4.81,   "清明"), (4,  20.04,  "谷雨"),
            (5,  5.52,   "立夏"), (5,  21.04,  "小满"),
            (6,  5.678,  "芒种"), (6,  21.37,  "夏至"),
            (7,  7.108,  "小暑"), (7,  22.83,  "大暑"),
            (8,  7.5,    "立秋"), (8,  23.13,  "处暑"),
            (9,  7.646,  "白露"), (9,  23.042, "秋分"),
            (10, 8.318,  "寒露"), (10, 23.438, "霜降"),
            (11, 7.438,  "立冬"), (11, 22.36,  "小雪"),
            (12, 7.18,   "大雪"), (12, 21.94,  "冬至"),
        ]

        for year in 2020...2035 {
            let yOff = year - 2000
            let offset = 0.2422 * Double(yOff) - Double(yOff / 4)

            for (month, c, name) in terms {
                let day = Int(floor(c + offset))
                guard day >= 1 && day <= 31 else { continue }
                let key = String(format: "%04d-%02d-%02d", year, month, day)
                var existing = markData[key] ?? []
                if !existing.contains(name) { existing.append(name); markData[key] = existing }
            }
        }
    }

    // MARK: - Traditional festivals (lunar-based, approximate)

    private func loadFestivals() {
        let fests: [(String, String)] = [
            ("2025-02-12", "元宵"), ("2025-08-29", "七夕"), ("2025-10-29", "重阳"),
            ("2026-03-03", "元宵"), ("2026-08-19", "七夕"), ("2026-10-18", "重阳"),
            ("2027-02-20", "元宵"), ("2027-08-08", "七夕"), ("2027-10-08", "重阳"),
            ("2028-02-09", "元宵"), ("2028-08-26", "七夕"), ("2028-10-26", "重阳"),
            ("2029-02-27", "元宵"), ("2029-08-16", "七夕"), ("2029-10-16", "重阳"),
            ("2030-02-17", "元宵"), ("2030-09-05", "七夕"), ("2030-11-04", "重阳"),
        ]
        for (key, name) in fests {
            var existing = markData[key] ?? []
            if !existing.contains(name) { existing.append(name); markData[key] = existing }
        }
    }

    // MARK: - Navigation

    var monthYearText: String {
        let df = DateFormatter(); df.dateFormat = "yyyy年 M月"
        return df.string(from: displayedMonth)
    }
    var yearText: String { "\(displayedYear)年" }

    func goToToday() {
        let now = Date()
        displayedMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        displayedYear = calendar.component(.year, from: now)
        selectedDate = now
        loadEvents()
        fetchYearData(displayedYear)
    }

    func nextMonth() {
        if let next = calendar.date(byAdding: .month, value: 1, to: displayedMonth) {
            let newYear = calendar.component(.year, from: next)
            displayedMonth = next
            if newYear != displayedYear { displayedYear = newYear; fetchYearData(newYear) }
            loadEvents()
        }
    }
    func prevMonth() {
        if let prev = calendar.date(byAdding: .month, value: -1, to: displayedMonth) {
            let newYear = calendar.component(.year, from: prev)
            displayedMonth = prev
            if newYear != displayedYear { displayedYear = newYear; fetchYearData(newYear) }
            loadEvents()
        }
    }
    func nextYear() {
        if let next = calendar.date(byAdding: .year, value: 1, to: displayedMonth) {
            displayedMonth = next; displayedYear = calendar.component(.year, from: next)
            loadEvents(); fetchYearData(displayedYear)
        }
    }
    func prevYear() {
        if let prev = calendar.date(byAdding: .year, value: -1, to: displayedMonth) {
            displayedMonth = prev; displayedYear = calendar.component(.year, from: prev)
            loadEvents(); fetchYearData(displayedYear)
        }
    }
    func goToMonth(year: Int, month: Int) {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        if let date = calendar.date(from: comps) {
            displayedMonth = date
            if year != displayedYear { displayedYear = year; fetchYearData(year) }
            loadEvents()
        }
    }
    func goToYear(_ y: Int) {
        displayedYear = y
        var comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        comps.year = y
        if let date = calendar.date(from: comps) { displayedMonth = date; loadEvents() }
        fetchYearData(y)
    }
    func monthDate(year: Int, month: Int) -> Date {
        var comps = DateComponents(); comps.year = year; comps.month = month; comps.day = 1
        return calendar.date(from: comps) ?? Date()
    }

    // MARK: - Grid helpers

    func isToday(_ date: Date) -> Bool { calendar.isDate(date, inSameDayAs: Date()) }
    func isSelected(_ date: Date) -> Bool {
        guard let sel = selectedDate else { return false }
        return calendar.isDate(date, inSameDayAs: sel)
    }
    func isCurrentMonth(_ date: Date) -> Bool {
        calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
    }
    func weeksInMonth(_ month: Date) -> [[Date?]] {
        var weeks: [[Date?]] = []
        guard let range = calendar.range(of: .day, in: .month, for: month),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return weeks }
        let firstWeekday = calendar.component(.weekday, from: firstDay)
        var currentWeek: [Date?] = []
        for _ in 1..<firstWeekday { currentWeek.append(nil) }
        for day in 1...range.count {
            currentWeek.append(calendar.date(byAdding: .day, value: day - 1, to: firstDay)!)
            if currentWeek.count == 7 { weeks.append(currentWeek); currentWeek = [] }
        }
        if !currentWeek.isEmpty {
            while currentWeek.count < 7 { currentWeek.append(nil) }
            weeks.append(currentWeek)
        }
        return weeks
    }
    private func dateKey(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        return df.string(from: date)
    }
}

// MARK: - Swipe helpers

private final class SwipeAcc { var x: CGFloat = 0; var y: CGFloat = 0 }
private enum SwipeAxis { case horizontal, vertical }

// MARK: - Calendar Tab (root)

struct CalendarTab: View {
    @EnvironmentObject var model: CalendarModel
    @State private var isYearView = false

    var body: some View {
        VStack(spacing: 0) {
            if isYearView {
                YearCalendarView(isYearView: $isYearView)
            } else {
                MonthCalendarView(isYearView: $isYearView)
            }
        }
    }
}

// MARK: - Month Calendar View

struct MonthCalendarView: View {
    @EnvironmentObject var model: CalendarModel
    @Binding var isYearView: Bool

    @State private var swipeMonitor: Any?
    @State private var transitionEdge: Edge = .trailing
    @State private var transitionAxis: SwipeAxis = .horizontal
    @State private var hoveredDate: Date?

    private let weekDays = ["日", "一", "二", "三", "四", "五", "六"]
    private let topSafe: CGFloat = 40

    var body: some View {
        let weeks = model.weeksInMonth(model.displayedMonth)

        VStack(spacing: 0) {
            Spacer().frame(height: topSafe)
            monthNavBar
            weekdayHeader

            // Animated grid
            VStack(spacing: 0) {
                ForEach(0..<weeks.count, id: \.self) { weekIdx in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { dayIdx in
                            if let date = weeks[weekIdx][dayIdx] {
                                CalendarCell(
                                    date: date,
                                    isToday: model.isToday(date),
                                    isSelected: model.isSelected(date),
                                    isCurrentMonth: model.isCurrentMonth(date),
                                    markLabel: model.markLabel(for: date),
                                    dotColors: model.eventDotColors(date),
                                    isHovered: hoveredDate == date
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedDate = date }
                                .onHover { h in hoveredDate = h ? date : nil }
                            } else {
                                Color.clear.frame(maxWidth: .infinity, minHeight: 60)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .id(model.displayedMonth)
            .transition(slideTransition)

            Spacer(minLength: 0)
            selectedDatePanel
        }
        .frame(width: 840, height: 620)
        .gesture(mouseDragGesture)
        .onAppear {
            if model.accessChecked && model.calendarAccessGranted { model.loadEvents() }
            model.fetchYearData(model.displayedYear)
            startTrackpadSwipe()
        }
        .onDisappear { stopTrackpadSwipe() }
    }

    // MARK: - Nav bar

    private var monthNavBar: some View {
        HStack(spacing: 6) {
            Button(action: { model.prevYear() }) {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("上一年")
            Button(action: { model.prevMonth() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("上一月")
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isYearView = true } }) {
                HStack(spacing: 4) {
                    Text(model.monthYearText).font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
            }
            .buttonStyle(.plain).help("展开年视图")
            Button(action: { model.nextMonth() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("下一月")
            Button(action: { model.nextYear() }) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("下一年")
            Spacer()
            Button("今天") { model.goToToday(); isYearView = false }
                .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 28).padding(.bottom, 10)
    }

    // MARK: - Weekday header

    private var weekdayHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                    Text(day).font(.system(size: 11, weight: .semibold))
                        .foregroundColor(idx == 0 || idx == 6 ? .secondary : .primary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 6)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 28)
        }
    }

    // MARK: - Transitions

    private var slideTransition: AnyTransition {
        let removal: Edge = {
            switch transitionAxis {
            case .horizontal: return transitionEdge == .trailing ? .leading : .trailing
            case .vertical:   return transitionEdge == .bottom ? .top : .bottom
            }
        }()
        return .asymmetric(insertion: .move(edge: transitionEdge), removal: .move(edge: removal))
    }

    private var mouseDragGesture: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { value in
            let absX = abs(value.translation.width), absY = abs(value.translation.height)
            if max(absX, absY) > 50 {
                if absX > absY { triggerMonth(isNext: value.translation.width < 0, axis: .horizontal) }
                else { triggerMonth(isNext: value.translation.height > 0, axis: .vertical) }
            }
        }
    }

    private func startTrackpadSwipe() {
        guard swipeMonitor == nil else { return }
        let acc = SwipeAcc()
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            switch event.phase {
            case .began: acc.x = 0; acc.y = 0
            case .changed: acc.x += event.scrollingDeltaX; acc.y += event.scrollingDeltaY
            case .ended, .cancelled:
                let absX = abs(acc.x), absY = abs(acc.y)
                if max(absX, absY) > 70 {
                    DispatchQueue.main.async {
                        if absX > absY { self.triggerMonth(isNext: acc.x < 0, axis: .horizontal) }
                        else { self.triggerMonth(isNext: acc.y > 0, axis: .vertical) }
                    }
                }
            default: break
            }
            return event
        }
    }
    private func stopTrackpadSwipe() {
        if let m = swipeMonitor { NSEvent.removeMonitor(m) }; swipeMonitor = nil
    }
    private func triggerMonth(isNext: Bool, axis: SwipeAxis) {
        transitionAxis = axis
        transitionEdge = axis == .horizontal
            ? (isNext ? .trailing : .leading)
            : (isNext ? .bottom : .top)
        withAnimation(.easeInOut(duration: 0.28)) {
            if isNext { model.nextMonth() } else { model.prevMonth() }
        }
    }

    // MARK: - Bottom panel

    @ViewBuilder
    var selectedDatePanel: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if let date = model.selectedDate {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text(formattedDate(date)).font(.system(size: 13, weight: .semibold))
                        if model.isToday(date) {
                            Text("今天").font(.system(size: 11)).foregroundColor(.red)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.red.opacity(0.1)))
                        }
                        if let label = model.markLabel(for: date) {
                            Text(label).font(.system(size: 12, weight: .medium)).foregroundColor(.red)
                        }
                        Spacer()
                    }
                    let events = model.eventsForDate(date)
                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(events.prefix(4), id: \.eventIdentifier) { EventRow(event: $0) }
                            if events.count > 4 {
                                Text("还有 \(events.count - 4) 个日程...")
                                    .font(.system(size: 10)).foregroundColor(.secondary).padding(.leading, 14)
                            }
                        }.padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 14).frame(maxHeight: 160)
            } else {
                HStack {
                    Image(systemName: "hand.draw").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
                    Text("点击日期查看日程 · 触控板滑动切换月份").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 28).padding(.vertical, 14)
            }
        }
    }
    private func formattedDate(_ date: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "M月d日 EEEE"; return df.string(from: date)
    }
}

// MARK: - Year Calendar View

struct YearCalendarView: View {
    @EnvironmentObject var model: CalendarModel
    @Binding var isYearView: Bool
    @State private var swipeMonitor: Any?
    @State private var transitionEdge: Edge = .trailing
    @State private var transitionAxis: SwipeAxis = .horizontal
    private let months = Array(1...12)
    private let topSafe: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: topSafe)
            yearNavBar
            let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 4)
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(months, id: \.self) { month in
                    MiniMonthCell(month: month, year: model.displayedYear) {
                        model.goToMonth(year: model.displayedYear, month: month)
                        withAnimation(.easeInOut(duration: 0.2)) { isYearView = false }
                    }
                }
            }
            .padding(.horizontal, 28)
            .id(model.displayedYear)
            .transition(slideTransition)
            Spacer(minLength: 0)
        }
        .frame(width: 940, height: 680)
        .gesture(mouseDragGesture)
        .onAppear { model.fetchYearData(model.displayedYear); startTrackpadSwipe() }
        .onDisappear { stopTrackpadSwipe() }
    }

    private var yearNavBar: some View {
        HStack(spacing: 6) {
            Button(action: { model.goToYear(model.displayedYear - 5) }) {
                Image(systemName: "chevron.left.2").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary).help("前五年")
            Button(action: { model.goToYear(model.displayedYear - 1) }) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary).help("上一年")
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isYearView = false } }) {
                HStack(spacing: 4) {
                    Text(model.yearText).font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
            }.buttonStyle(.plain).help("收起年视图")
            Button(action: { model.goToYear(model.displayedYear + 1) }) {
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary).help("下一年")
            Button(action: { model.goToYear(model.displayedYear + 5) }) {
                Image(systemName: "chevron.right.2").font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundColor(.secondary).help("后五年")
            Spacer()
            Button("今天") { model.goToToday(); isYearView = false }
                .font(.system(size: 12, weight: .medium)).buttonStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }.padding(.horizontal, 28).padding(.bottom, 14)
    }

    private var slideTransition: AnyTransition {
        let removal: Edge = transitionAxis == .horizontal
            ? (transitionEdge == .trailing ? .leading : .trailing)
            : (transitionEdge == .bottom ? .top : .bottom)
        return .asymmetric(insertion: .move(edge: transitionEdge), removal: .move(edge: removal))
    }
    private var mouseDragGesture: some Gesture {
        DragGesture(minimumDistance: 15).onEnded { value in
            let absX = abs(value.translation.width), absY = abs(value.translation.height)
            if max(absX, absY) > 50 {
                if absX > absY { triggerYear(isNext: value.translation.width < 0, axis: .horizontal) }
                else { triggerYear(isNext: value.translation.height > 0, axis: .vertical) }
            }
        }
    }
    private func startTrackpadSwipe() {
        guard swipeMonitor == nil else { return }
        let acc = SwipeAcc()
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            switch event.phase {
            case .began: acc.x = 0; acc.y = 0
            case .changed: acc.x += event.scrollingDeltaX; acc.y += event.scrollingDeltaY
            case .ended, .cancelled:
                let absX = abs(acc.x), absY = abs(acc.y)
                if max(absX, absY) > 70 {
                    DispatchQueue.main.async {
                        if absX > absY { self.triggerYear(isNext: acc.x < 0, axis: .horizontal) }
                        else { self.triggerYear(isNext: acc.y > 0, axis: .vertical) }
                    }
                }
            default: break
            }
            return event
        }
    }
    private func stopTrackpadSwipe() {
        if let m = swipeMonitor { NSEvent.removeMonitor(m) }; swipeMonitor = nil
    }
    private func triggerYear(isNext: Bool, axis: SwipeAxis) {
        transitionAxis = axis
        transitionEdge = axis == .horizontal
            ? (isNext ? .trailing : .leading)
            : (isNext ? .bottom : .top)
        withAnimation(.easeInOut(duration: 0.28)) {
            if isNext { model.goToYear(model.displayedYear + 1) }
            else { model.goToYear(model.displayedYear - 1) }
        }
    }
}

// MARK: - Mini Month Cell

struct MiniMonthCell: View {
    @EnvironmentObject var model: CalendarModel
    let month: Int; let year: Int; let onTap: () -> Void
    private let weekDays = ["日", "一", "二", "三", "四", "五", "六"]
    private let monthNames = ["","一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"]
    private let calendar = Calendar.current

    var body: some View {
        let monthDate = model.monthDate(year: year, month: month)
        let weeks = model.weeksInMonth(monthDate)
        let isCurrent = calendar.isDate(Date(), equalTo: monthDate, toGranularity: .month)

        VStack(spacing: 3) {
            Text(monthNames[month]).font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                .foregroundColor(isCurrent ? .red : .primary).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(Array(weekDays.enumerated()), id: \.offset) { idx, day in
                    Text(day).font(.system(size: 7, weight: .medium))
                        .foregroundColor(idx == 0 || idx == 6 ? .secondary : .primary.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<weeks.count, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in
                        if let date = weeks[w][d] {
                            MiniDayCell(date: date, monthDate: monthDate)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: 18)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .contentShape(Rectangle()).onTapGesture { onTap() }
    }
}

struct MiniDayCell: View {
    let date: Date; let monthDate: Date
    private let calendar = Calendar.current
    var body: some View {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let isToday = calendar.isDate(date, inSameDayAs: Date())
        let inMonth = calendar.isDate(date, equalTo: monthDate, toGranularity: .month)
        Text("\(day)").font(.system(size: 9, weight: isToday ? .bold : .regular))
            .foregroundColor({
                if isToday { return Color.red }
                if !inMonth { return Color.secondary }
                if weekday == 1 { return Color.red.opacity(0.7) }
                if weekday == 7 { return Color.blue.opacity(0.7) }
                return Color.primary.opacity(0.8)
            }())
            .frame(height: 18).frame(maxWidth: .infinity)
            .background(isToday ? Circle().fill(Color.red.opacity(0.12)).frame(width: 20, height: 20) : nil)
            .opacity(inMonth ? 1 : 0.25)
    }
}

// MARK: - Calendar Cell

struct CalendarCell: View {
    let date: Date
    let isToday: Bool; let isSelected: Bool; let isCurrentMonth: Bool
    let markLabel: String?; let dotColors: [Color]; let isHovered: Bool
    private let calendar = Calendar.current

    var body: some View {
        let day = calendar.component(.day, from: date)
        let weekday = calendar.component(.weekday, from: date)

        VStack(spacing: 3) {
            ZStack {
                if isSelected { Circle().fill(Color.blue).frame(width: 32, height: 32) }
                else if isToday { Circle().stroke(Color.red, lineWidth: 1.5).frame(width: 32, height: 32) }
                Text("\(day)")
                    .font(.system(size: 15, weight: (isToday || isSelected) ? .semibold : .regular))
                    .foregroundColor(cellColor(weekday: weekday))
                    .frame(width: 32, height: 32)
            }
            if let label = markLabel {
                Text(label).font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.red).lineLimit(1).fixedSize()
            } else if !dotColors.isEmpty {
                HStack(spacing: 3) {
                    ForEach(0..<min(dotColors.count, 3), id: \.self) { i in
                        Circle().fill(dotColors[i]).frame(width: 5, height: 5)
                    }
                }.frame(height: 10)
            } else {
                Color.clear.frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(isHovered && !isSelected
            ? RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)) : nil)
        .opacity(isCurrentMonth ? 1 : 0.25)
    }

    private func cellColor(weekday: Int) -> Color {
        if isSelected { return .white }
        if !isCurrentMonth { return .secondary }
        if weekday == 1 { return .red }
        if weekday == 7 { return .blue }
        return .primary
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: EKEvent
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(nsColor: event.calendar.color ?? .gray)).frame(width: 7, height: 7)
            if event.isAllDay {
                Text(event.title).font(.system(size: 12)).lineLimit(1)
                Spacer(); Text("全天").font(.system(size: 10)).foregroundColor(.secondary)
            } else {
                Text(event.title).font(.system(size: 12)).lineLimit(1)
                Spacer()
                Text({ let df = DateFormatter(); df.dateFormat = "HH:mm"; return df.string(from: event.startDate) }())
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
        }
    }
}
