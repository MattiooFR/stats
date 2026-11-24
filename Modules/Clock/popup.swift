//
//  popup.swift
//  Clock
//
//  Created by Serhiy Mytrovtsiy on 24/03/2023
//  Using Swift 5.0
//  Running on macOS 13.2
//
//  Copyright © 2023 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import EventKit
import Kit

private struct DayEvent {
    let title: String
    let color: NSColor
    let start: Date
    let end: Date
    let allDay: Bool
}

private enum EventsAccess {
    case undetermined
    case granted
    case refused
}

internal class Popup: PopupWrapper {
    private lazy var orderTableView: OrderTableView = OrderTableView()
    private var settingsLoaded: Bool = false
    private var list: [Clock_t] = []
    private let cache = PopupCache<[Clock_t]>()
    
    private var calendarState: Bool = true
    
    // views, rebuilt each time the popup opens
    private var monthView: MonthView? = nil
    private var eventsCard: ISCard? = nil
    private var shortcutBar: NSView? = nil
    private var clockCards: [ClockCard] = []
    private var loading: Bool = false
    
    // calendar events of the selected day
    private lazy var eventStore: EKEventStore = EKEventStore()
    private let eventsQueue = DispatchQueue(label: "eu.exelban.Stats.Clock.events", qos: .userInitiated)
    private var eventsToken: Int = 0
    private var todayEvents: (day: Date, list: [DayEvent])? = nil
    private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    private let maxEvents: Int = 8
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 285, height: 0))
        
        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
        
        self.calendarState = Store.shared.bool(key: "\(self.title)_calendar", defaultValue: self.calendarState)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadContent() {
        self.loading = true
        self.selectedDay = Calendar.current.startOfDay(for: Date())
        
        if self.calendarState {
            self.addSection(self.initCalendar())
            self.addSection(self.initEvents())
        }
        
        let bar = ISShortcutBar(module: .clock, extra: [
            ISShortcut.app("com.apple.iCal"),
            ISShortcut.link(
                "x-apple.systempreferences:com.apple.Date-Time-Settings.extension",
                symbol: "clock",
                toolTip: isL("Date & Time", fr: "Date et heure")
            )
        ])
        self.addSection(bar)
        self.shortcutBar = bar
        
        // the clock list is known before the first reading: the cards are there as soon as the popup opens
        self.renderClocks(self.cache.value ?? self.currentList())
        if self.calendarState {
            self.reloadEvents()
        }
        
        self.loading = false
        self.resizeToFitContent()
    }
    
    public override func unloadContent() {
        self.monthView = nil
        self.eventsCard = nil
        self.shortcutBar = nil
        self.clockCards = []
        // a fetch that is still running must not touch the next set of views
        self.eventsToken += 1
    }
    
    public override func appear() {
        self.replay(self.cache, render: self.renderClocks)
    }
    
    private func fit() {
        guard !self.loading else { return }
        self.resizeToFitContent()
    }
    
    // MARK: - Calendar
    
    private func initCalendar() -> NSView {
        let card = ISCard()
        // the view spans the whole card and insets its grid itself: the arrows sit near the edge and keep a full hit area
        card.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        
        let view = MonthView()
        view.onSelect = { [weak self] day in
            self?.selectedDay = day
            self?.reloadEvents()
        }
        view.onResize = { [weak self] in
            self?.fit()
        }
        view.onOpen = { [weak self] in
            self?.openCalendar()
        }
        card.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: card.widthAnchor).isActive = true
        self.monthView = view
        
        return card
    }
    
    private func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        (self.window as? PopupWindow)?.dismissIfUnlocked()
    }
    
    // MARK: - Events
    
    private func initEvents() -> NSView {
        let card = ISCard()
        self.eventsCard = card
        return card
    }
    
    // the permission is never asked automatically: only a click on the card asks for it
    private var eventsAccess: EventsAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            // without the usage description in Info.plist the request cannot succeed: it is not offered
            return self.hasUsageDescription ? .undetermined : .refused
        }
        if #available(macOS 14.0, *) {
            return status == .fullAccess ? .granted : .refused
        }
        return status == .authorized ? .granted : .refused
    }
    
    private var hasUsageDescription: Bool {
        if #available(macOS 14.0, *) {
            return Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil
        }
        return Bundle.main.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") != nil
    }
    
    private func reloadEvents() {
        guard self.contentLoaded, let card = self.eventsCard else { return }
        let day = self.selectedDay
        
        switch self.eventsAccess {
        case .undetermined:
            self.eventsToken += 1
            let row = ISRow(
                isL("Show calendar events…", fr: "Afficher les évènements du calendrier…"),
                icon: NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            )
            row.labelField.textColor = ISTheme.current.value
            self.setEventRows([row]) { [weak self] in
                self?.requestEventsAccess()
            }
        case .refused:
            self.eventsToken += 1
            self.setEventRows(self.eventRows([], day: day))
        case .granted:
            if let cached = self.todayEvents, cached.day == day {
                self.setEventRows(self.eventRows(cached.list, day: day))
            } else if card.arrangedSubviews.isEmpty || card.onClick != nil {
                self.setEventRows(self.eventRows([], day: day))
            }
            // otherwise the previous day stays on screen until the new one is read: no flicker
            self.fetchEvents(day)
        }
    }
    
    private func requestEventsAccess() {
        if #available(macOS 14.0, *) {
            self.eventStore.requestFullAccessToEvents { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.reloadEvents()
                }
            }
        } else {
            self.eventStore.requestAccess(to: .event) { [weak self] _, _ in
                DispatchQueue.main.async {
                    self?.reloadEvents()
                }
            }
        }
    }
    
    private func fetchEvents(_ day: Date) {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { return }
        
        self.eventsToken += 1
        let token = self.eventsToken
        let store = self.eventStore
        let fallbackColor = ISTheme.current.blue
        
        self.eventsQueue.async { [weak self] in
            let predicate = store.predicateForEvents(withStart: day, end: end.addingTimeInterval(-1), calendars: nil)
            var list: [DayEvent] = []
            for event in store.events(matching: predicate) {
                guard event.status != .canceled, let from = event.startDate, let to = event.endDate else { continue }
                // an event that ended at midnight belongs to the day before
                guard from < end, to > day || from >= day else { continue }
                list.append(DayEvent(
                    title: event.title ?? "",
                    color: event.calendar?.color ?? fallbackColor,
                    start: from,
                    end: to,
                    allDay: event.isAllDay || (from <= day && to >= end.addingTimeInterval(-60))
                ))
            }
            list.sort(by: { a, b in
                if a.allDay != b.allDay { return a.allDay }
                if a.start != b.start { return a.start < b.start }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            })
            
            DispatchQueue.main.async {
                guard let self, self.contentLoaded, token == self.eventsToken else { return }
                if calendar.isDateInToday(day) {
                    self.todayEvents = (day, list)
                }
                self.setEventRows(self.eventRows(list, day: day))
            }
        }
    }
    
    private func eventRows(_ events: [DayEvent], day: Date) -> [NSView] {
        let theme = ISTheme.current
        var rows: [NSView] = []
        
        // the selected day is named when it is not today
        if !Calendar.current.isDateInToday(day) {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            let row = ISRow(formatter.string(from: day).uppercased(with: Locale.current))
            row.labelField.textColor = theme.title
            rows.append(row)
        }
        
        guard !events.isEmpty else {
            let row = ISRow(isL("No Events", fr: "Aucun Évènement"))
            row.labelField.textColor = theme.value
            rows.append(row)
            return rows
        }
        
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        
        for event in events.prefix(self.maxEvents) {
            let row = ISRow(event.title, color: event.color)
            row.labelField.textColor = theme.value
            row.valueField.textColor = theme.label
            if !event.allDay {
                // started the day before: the end time is what matters today
                row.setPlain(event.start < day ? "→ \(formatter.string(from: event.end))" : formatter.string(from: event.start))
            }
            row.toolTip = event.title
            rows.append(row)
        }
        if events.count > self.maxEvents {
            let more = events.count - self.maxEvents
            rows.append(ISRow(isL("\(more) more…", fr: more == 1 ? "1 autre…" : "\(more) autres…"), dim: true))
        }
        
        return rows
    }
    
    private func setEventRows(_ rows: [NSView], onClick: (() -> Void)? = nil) {
        guard let card = self.eventsCard else { return }
        card.removeAll(keepHeader: false)
        rows.forEach { card.add($0) }
        card.onClick = onClick
        card.needsDisplay = true
        self.fit()
    }
    
    // MARK: - Clocks
    
    internal func callback(_ list: [Clock_t]) {
        if self.settingsLoaded && (list.count != self.orderTableView.list.count || self.orderTableView.window?.isVisible ?? false) {
            self.orderTableView.list = list.sorted(by: { $0.popupIndex < $1.popupIndex })
            self.orderTableView.update()
        }
        
        self.list = list
        self.apply(list, to: self.cache, render: self.renderClocks)
    }
    
    private func currentList() -> [Clock_t] {
        let now = Date()
        return Clock.list.map { item in
            var clock = item
            clock.value = now
            return clock
        }
    }
    
    private func renderClocks(_ list: [Clock_t]) {
        guard self.contentLoaded else { return }
        
        // same rules as before: the order and the visibility come from the list in the popup settings
        var ordered: [(offset: Int, index: Int, clock: Clock_t)] = []
        for (offset, clock) in list.enumerated() where clock.popupState {
            ordered.append((offset: offset, index: clock.popupIndex, clock: clock))
        }
        ordered.sort { a, b in
            if a.index != b.index { return a.index < b.index }
            return a.offset < b.offset
        }
        let visible: [Clock_t] = ordered.map { $0.clock }
        let visibleIDs: [String] = visible.map { $0.id }
        let shownIDs: [String] = self.clockCards.map { $0.clock.id }
        
        if visibleIDs != shownIDs {
            self.clockCards.forEach { card in
                self.removeArrangedSubview(card)
                card.removeFromSuperview()
            }
            self.clockCards = visible.map { ClockCard($0, width: self.frame.width) }
            
            var index = self.arrangedSubviews.count
            if let bar = self.shortcutBar, let position = self.arrangedSubviews.firstIndex(of: bar) {
                index = position
            }
            self.clockCards.forEach { card in
                self.addSection(card, at: index)
                index += 1
            }
            self.fit()
        }
        
        for (card, clock) in zip(self.clockCards, visible) {
            card.update(clock)
        }
        self.monthView?.refreshToday()
    }
    
    private func rearrange() {
        self.callback(self.list)
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        self.settingsLoaded = true
        self.orderTableView.list = self.list.sorted(by: { $0.popupIndex < $1.popupIndex })
        self.orderTableView.update()
        self.orderTableView.reorderCallback = { [weak self] in
            self?.rearrange()
        }
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Calendar"), component: self.switchView(
                action: #selector(self.toggleCalendarState),
                state: self.calendarState
            ))
        ]))
        
        view.addArrangedSubview(self.orderTableView)
        
        return view
    }
    
    @objc private func toggleCalendarState(_ sender: NSControl) {
        self.calendarState = controlState(sender)
        Store.shared.set(key: "\(self.title)_calendar", value: self.calendarState)
        
        guard self.contentLoaded else { return }
        self.releaseContent()
        self.prepareForDisplay()
    }
}

// month grid: month and year with previous / next, weekday names, one rounded cell per day
private final class MonthView: NSView {
    private enum Zone: Equatable {
        case outside
        case title
        case previous
        case next
        case day(Int)
    }
    
    public var onSelect: ((Date) -> Void)?
    public var onResize: (() -> Void)?
    public var onOpen: (() -> Void)?
    
    private let calendar: Calendar = Calendar.current
    private var month: Date
    private var today: Date
    private var selected: Date
    
    private var days: [Date] = []
    private var numbers: [String] = []
    private var inMonth: [Bool] = []
    private var title: String = ""
    
    private var hovered: Zone = .outside {
        didSet {
            if oldValue != self.hovered { self.needsDisplay = true }
        }
    }
    private var pressed: Zone = .outside
    private var tracking: NSTrackingArea? = nil
    private var heightConstraint: NSLayoutConstraint? = nil
    private var toolTipsSize: NSSize = .zero
    
    private let headerHeight: CGFloat = 22
    private let weekdayTop: CGFloat = 24
    private let weekdayHeight: CGFloat = 20
    private let gridTop: CGFloat = 47
    private let cellHeight: CGFloat = 29
    private let gap: CGFloat = 4
    private let radius: CGFloat = 6
    private let inset: CGFloat = ISMetrics.padH
    
    private let titleFont: NSFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let weekdayFont: NSFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    private let numberFont: NSFont = ISFont.value(13)
    
    private lazy var titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = self.calendar
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()
    private lazy var dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = self.calendar
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
    // names in the order of the week, starting with the first weekday of the locale
    private lazy var weekdays: (short: [String], narrow: [String]) = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = self.calendar
        let first = self.calendar.firstWeekday - 1
        let ordered: ([String]?) -> [String] = { symbols in
            guard let symbols, symbols.count == 7, (0..<7).contains(first) else {
                return Array(repeating: "", count: 7)
            }
            return (Array(symbols[first...]) + Array(symbols[..<first])).map { $0.uppercased(with: Locale.current) }
        }
        return (ordered(formatter.shortStandaloneWeekdaySymbols), ordered(formatter.veryShortStandaloneWeekdaySymbols))
    }()
    
    override var isFlipped: Bool { true }
    
    init() {
        let now = Calendar.current.startOfDay(for: Date())
        self.month = now
        self.today = now
        self.selected = now
        
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        
        let height = self.heightAnchor.constraint(equalToConstant: self.gridTop)
        height.isActive = true
        self.heightConstraint = height
        
        self.show(now)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // MARK: - State
    
    // displays the month that contains the date; the height follows the number of weeks
    private func show(_ date: Date) {
        let calendar = self.calendar
        let start = calendar.date(from: calendar.dateComponents([.era, .year, .month], from: date)) ?? date
        guard let range = calendar.range(of: .day, in: .month, for: start) else { return }
        
        let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let rows = Int((Double(lead + range.count) / 7).rounded(.up))
        var days: [Date] = []
        for i in 0..<(rows * 7) {
            if let day = calendar.date(byAdding: .day, value: i - lead, to: start) {
                days.append(day)
            }
        }
        guard rows > 0, days.count == rows * 7 else { return }
        
        let before = self.days.count
        self.month = start
        self.days = days
        self.numbers = days.map { "\(calendar.component(.day, from: $0))" }
        self.inMonth = days.map { calendar.isDate($0, equalTo: start, toGranularity: .month) }
        self.title = self.titleFormatter.string(from: start).uppercased(with: Locale.current)
        
        self.heightConstraint?.constant = self.gridTop + (CGFloat(rows) * self.cellHeight) + (CGFloat(rows - 1) * self.gap)
        self.updateToolTips()
        self.updateHover()
        self.needsDisplay = true
        
        if before != 0 && before != days.count {
            self.onResize?()
        }
    }
    
    private func shift(_ months: Int) {
        guard let date = self.calendar.date(byAdding: .month, value: months, to: self.month) else { return }
        self.show(date)
    }
    
    private func select(_ date: Date) {
        let day = self.calendar.startOfDay(for: date)
        let changed = !self.calendar.isDate(day, inSameDayAs: self.selected)
        self.selected = day
        if !self.calendar.isDate(day, equalTo: self.month, toGranularity: .month) {
            self.show(day)
        }
        self.needsDisplay = true
        if changed {
            self.onSelect?(day)
        }
    }
    
    // called every second by the popup: follows the date when the day changes while the popup is open
    public func refreshToday() {
        let now = self.calendar.startOfDay(for: Date())
        guard !self.calendar.isDate(now, inSameDayAs: self.today) else { return }
        let followed = self.calendar.isDate(self.selected, inSameDayAs: self.today)
        self.today = now
        if followed {
            self.select(now)
        }
        self.needsDisplay = true
    }
    
    // MARK: - Geometry
    
    private var cellWidth: CGFloat {
        (self.bounds.width - (self.inset * 2) - (self.gap * 6)) / 7
    }
    
    private func cellRect(_ index: Int) -> NSRect {
        NSRect(
            x: self.inset + (CGFloat(index % 7) * (self.cellWidth + self.gap)),
            y: self.gridTop + (CGFloat(index / 7) * (self.cellHeight + self.gap)),
            width: self.cellWidth,
            height: self.cellHeight
        )
    }
    
    // the arrows are centered 34 and 10 pt from the right edge of the card
    private var previousRect: NSRect {
        NSRect(x: self.bounds.width - 46, y: 0, width: 24, height: self.headerHeight)
    }
    
    private var nextRect: NSRect {
        NSRect(x: self.bounds.width - 22, y: 0, width: 22, height: self.headerHeight)
    }
    
    private var titleRect: NSRect {
        let width = (self.title as NSString).size(withAttributes: [.font: self.titleFont]).width + 16
        return NSRect(x: (self.bounds.width - width) / 2, y: 0, width: width, height: self.headerHeight)
    }
    
    private func zone(at point: NSPoint) -> Zone {
        guard self.bounds.contains(point) else { return .outside }
        
        if point.y < self.headerHeight {
            if self.nextRect.contains(point) { return .next }
            if self.previousRect.contains(point) { return .previous }
            if self.titleRect.contains(point) { return .title }
            return .outside
        }
        guard point.y >= self.gridTop, point.x >= self.inset, self.cellWidth > 0 else { return .outside }
        
        let column = Int((point.x - self.inset) / (self.cellWidth + self.gap))
        let row = Int((point.y - self.gridTop) / (self.cellHeight + self.gap))
        let index = (row * 7) + column
        guard column < 7, self.days.indices.contains(index), self.cellRect(index).contains(point) else { return .outside }
        return .day(index)
    }
    
    // MARK: - Drawing
    
    private static func cellFill(_ theme: ISTheme) -> NSColor {
        let color = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let luminance = (0.2126 * color.redComponent) + (0.7152 * color.greenComponent) + (0.0722 * color.blueComponent)
        // a darker cell does not show on an almost black panel
        return luminance < 0.08 ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.1)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let width = self.bounds.width
        let cellWidth = self.cellWidth
        guard width > 0, cellWidth > 0 else { return }
        
        // month and year
        let title = NSAttributedString(string: self.title, attributes: [
            .font: self.titleFont,
            .foregroundColor: theme.value
        ])
        let titleSize = title.size()
        title.draw(at: NSPoint(
            x: ((width - titleSize.width) / 2).rounded(),
            y: ((self.headerHeight - titleSize.height) / 2).rounded()
        ))
        
        // previous / next month
        let arrows: [(zone: Zone, rect: NSRect, left: Bool)] = [
            (.previous, self.previousRect, true),
            (.next, self.nextRect, false)
        ]
        for arrow in arrows {
            let center = NSPoint(x: arrow.left ? arrow.rect.midX : arrow.rect.maxX - 10, y: arrow.rect.midY)
            if self.hovered == arrow.zone {
                theme.hover.withAlphaComponent(0.75).setFill()
                NSBezierPath(roundedRect: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18), xRadius: 5, yRadius: 5).fill()
            }
            self.drawChevron(at: center, left: arrow.left, color: theme.value)
        }
        
        // weekday names
        var symbols = self.weekdays.short
        if symbols.contains(where: { ($0 as NSString).size(withAttributes: [.font: self.weekdayFont]).width > cellWidth }) {
            symbols = self.weekdays.narrow
        }
        let weekdayColor = theme.value.withAlphaComponent(0.6)
        for (i, symbol) in symbols.enumerated() {
            let text = NSAttributedString(string: symbol, attributes: [
                .font: self.weekdayFont,
                .foregroundColor: weekdayColor
            ])
            let size = text.size()
            text.draw(at: NSPoint(
                x: (self.inset + (CGFloat(i) * (cellWidth + self.gap)) + ((cellWidth - size.width) / 2)).rounded(),
                y: (self.weekdayTop + ((self.weekdayHeight - size.height) / 2)).rounded()
            ))
        }
        
        // days
        let fill = MonthView.cellFill(theme)
        let dimmed = theme.dim.withAlphaComponent(0.7)
        for i in self.days.indices {
            let rect = self.cellRect(i)
            guard rect.intersects(dirtyRect) else { continue }
            
            let day = self.days[i]
            let isToday = self.calendar.isDate(day, inSameDayAs: self.today)
            let isSelected = self.calendar.isDate(day, inSameDayAs: self.selected)
            let isHovered = self.hovered == .day(i)
            let isInMonth = self.inMonth[i]
            
            let cell = NSBezierPath(roundedRect: rect, xRadius: self.radius, yRadius: self.radius)
            fill.withAlphaComponent(fill.alphaComponent * (isInMonth || isToday ? 1 : 0.5)).setFill()
            cell.fill()
            if isToday {
                theme.blue.withAlphaComponent(isHovered ? 0.42 : 0.3).setFill()
                cell.fill()
            } else if isHovered || isSelected {
                theme.hover.withAlphaComponent(isHovered ? 0.75 : 0.55).setFill()
                cell.fill()
            }
            
            if isToday || isSelected {
                let lineWidth: CGFloat = 1
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                    xRadius: self.radius - (lineWidth / 2),
                    yRadius: self.radius - (lineWidth / 2)
                )
                outline.lineWidth = lineWidth
                (isToday ? theme.blue : theme.label.withAlphaComponent(0.7)).setStroke()
                outline.stroke()
            }
            
            let number = NSAttributedString(string: self.numbers[i], attributes: [
                .font: self.numberFont,
                .foregroundColor: (isInMonth || isToday) ? theme.value : dimmed
            ])
            let size = number.size()
            number.draw(at: NSPoint(
                x: (rect.minX + ((rect.width - size.width) / 2)).rounded(),
                y: (rect.minY + ((rect.height - size.height) / 2)).rounded()
            ))
        }
    }
    
    private func drawChevron(at center: NSPoint, left: Bool, color: NSColor) {
        let w: CGFloat = left ? 2.5 : -2.5
        let h: CGFloat = 4.75
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + w, y: center.y - h))
        path.line(to: NSPoint(x: center.x - w, y: center.y))
        path.line(to: NSPoint(x: center.x + w, y: center.y + h))
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
    
    // MARK: - Mouse
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
    
    override func mouseDown(with event: NSEvent) {
        self.pressed = self.zone(at: self.convert(event.locationInWindow, from: nil))
    }
    
    override func mouseUp(with event: NSEvent) {
        let zone = self.zone(at: self.convert(event.locationInWindow, from: nil))
        let pressed = self.pressed
        self.pressed = .outside
        // the press and the release must be on the same target
        guard zone != .outside, pressed == .outside || pressed == zone else { return }
        
        switch zone {
        case .previous:
            self.shift(-1)
        case .next:
            self.shift(1)
        case .title:
            self.today = self.calendar.startOfDay(for: Date())
            self.select(self.today)
        case .day(let index):
            guard self.days.indices.contains(index) else { return }
            if event.clickCount > 1 {
                // nothing after this line: the popup closes and releases this view
                self.onOpen?()
                return
            }
            self.select(self.days[index])
        case .outside:
            break
        }
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking {
            self.removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        self.addTrackingArea(area)
        self.tracking = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        self.hovered = self.zone(at: self.convert(event.locationInWindow, from: nil))
    }
    
    override func mouseMoved(with event: NSEvent) {
        self.hovered = self.zone(at: self.convert(event.locationInWindow, from: nil))
    }
    
    override func mouseExited(with event: NSEvent) {
        self.hovered = .outside
    }
    
    private func updateHover() {
        guard let window = self.window else {
            self.hovered = .outside
            return
        }
        self.hovered = self.zone(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    
    // MARK: - Tooltips
    
    override func layout() {
        super.layout()
        if self.toolTipsSize != self.bounds.size {
            self.updateToolTips()
        }
    }
    
    private func updateToolTips() {
        self.removeAllToolTips()
        self.toolTipsSize = self.bounds.size
        guard self.bounds.width > 0 else { return }
        
        _ = self.addToolTip(self.titleRect, owner: self, userData: nil)
        _ = self.addToolTip(self.previousRect, owner: self, userData: nil)
        _ = self.addToolTip(self.nextRect, owner: self, userData: nil)
        for i in self.days.indices {
            _ = self.addToolTip(self.cellRect(i), owner: self, userData: nil)
        }
    }
}

extension MonthView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch self.zone(at: point) {
        case .title:
            return isL("Today", fr: "Aujourd’hui")
        case .previous:
            return localizedString("Previous month")
        case .next:
            return isL("Next month", fr: "Mois suivant")
        case .day(let index):
            return self.days.indices.contains(index) ? self.dayFormatter.string(from: self.days[index]) : ""
        case .outside:
            return ""
        }
    }
}

// one clock of the list: name and difference with the local time on the left, time in large digits on the right
private final class ClockCard: ISCard {
    private(set) var clock: Clock_t
    
    private let nameField: ISText
    private let detailField: ISText
    private let timeField: ISText
    
    // time of day part of the clock format, nil when the format has none
    private var timeFormat: String?
    private var timeSize: CGFloat = ClockCard.maxTimeSize
    private var timeLength: Int = -1
    private let maxTimeWidth: CGFloat
    private var toolTipSize: NSSize = .zero
    
    private static let maxTimeSize: CGFloat = 30
    private static let minTimeSize: CGFloat = 14
    private static var formatters: [String: DateFormatter] = [:]
    
    init(_ clock: Clock_t, width: CGFloat) {
        let theme = ISTheme.current
        self.clock = clock
        self.timeFormat = ClockCard.timeOnly(clock.format)
        self.maxTimeWidth = ((width - (ISMetrics.padH * 2)) * 0.64).rounded()
        self.nameField = ISText(clock.name, font: ISFont.label(13), color: theme.value)
        self.detailField = ISText("", font: ISFont.label(13), color: theme.label)
        self.timeField = ISText("", font: ClockCard.timeFont(ClockCard.maxTimeSize), color: theme.value, alignment: .right)
        
        super.init(title: nil, value: nil)
        
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.heightAnchor.constraint(equalToConstant: 35).isActive = true
        
        self.nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.timeField.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        self.timeField.setContentHuggingPriority(.required, for: .horizontal)
        
        content.addSubview(self.nameField)
        content.addSubview(self.detailField)
        content.addSubview(self.timeField)
        NSLayoutConstraint.activate([
            self.nameField.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            self.nameField.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            self.detailField.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            self.detailField.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            self.timeField.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            self.timeField.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            self.nameField.trailingAnchor.constraint(lessThanOrEqualTo: self.timeField.leadingAnchor, constant: -8),
            self.detailField.trailingAnchor.constraint(lessThanOrEqualTo: self.timeField.leadingAnchor, constant: -8)
        ])
        self.add(content)
        
        self.update(clock)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ clock: Clock_t) {
        if clock.format != self.clock.format {
            self.timeFormat = ClockCard.timeOnly(clock.format)
        }
        self.clock = clock
        
        let date = clock.value ?? Date()
        let zone = TimeZone(from: clock.tz)
        
        if self.nameField.stringValue != clock.name {
            self.nameField.stringValue = clock.name
        }
        
        let time: String
        if let format = self.timeFormat {
            time = ClockCard.formatter(format, zone: zone).string(from: date)
        } else {
            time = clock.formatted()
        }
        if self.timeField.stringValue != time {
            self.fit(time)
            self.timeField.stringValue = time
        }
        
        let detail = ClockCard.difference(with: zone, at: date)
        if self.detailField.stringValue != detail {
            self.detailField.stringValue = detail
        }
    }
    
    // a long value (a format without a time of day, seconds and AM/PM...) gets smaller digits instead of pushing the name out
    private func fit(_ text: String) {
        guard text.count != self.timeLength else { return }
        self.timeLength = text.count
        
        var size = ClockCard.maxTimeSize
        while size > ClockCard.minTimeSize {
            let width = (text as NSString).size(withAttributes: [.font: ClockCard.timeFont(size)]).width
            if width <= self.maxTimeWidth { break }
            size -= 1
        }
        if size != self.timeSize {
            self.timeSize = size
            self.timeField.font = ClockCard.timeFont(size)
        }
    }
    
    private static func timeFont(_ size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .thin)
    }
    
    private static func formatter(_ format: String, zone: TimeZone) -> DateFormatter {
        let key = "\(zone.identifier)|\(format)"
        if let formatter = ClockCard.formatters[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = zone
        ClockCard.formatters[key] = formatter
        return formatter
    }
    
    // "yyyy-MM-dd HH:mm:ss" -> "HH:mm:ss": the large digits show the time, the calendar above shows the date
    private static func timeOnly(_ format: String) -> String? {
        enum Kind {
            case time
            case other
            case literal
        }
        let timeFields: Set<Character> = ["a", "A", "b", "B", "h", "H", "k", "K", "m", "s", "S"]
        let chars = Array(format)
        var tokens: [(text: String, kind: Kind)] = []
        
        var i = 0
        while i < chars.count {
            let char = chars[i]
            var j = i + 1
            if char == "'" {
                // quoted text, '' is a quote inside it
                while j < chars.count {
                    if chars[j] == "'" {
                        if j + 1 < chars.count && chars[j + 1] == "'" {
                            j += 2
                            continue
                        }
                        break
                    }
                    j += 1
                }
                j = min(j + 1, chars.count)
                tokens.append((String(chars[i..<j]), .literal))
            } else if char.isASCII && char.isLetter {
                while j < chars.count && chars[j] == char { j += 1 }
                tokens.append((String(chars[i..<j]), timeFields.contains(char) ? .time : .other))
            } else {
                while j < chars.count && chars[j] != "'" && !(chars[j].isASCII && chars[j].isLetter) { j += 1 }
                tokens.append((String(chars[i..<j]), .literal))
            }
            i = j
        }
        
        guard let first = tokens.firstIndex(where: { $0.kind == .time }),
              let last = tokens.lastIndex(where: { $0.kind == .time }) else {
            return nil
        }
        
        // a separator is kept only between two time fields
        var result = ""
        var separator = ""
        var skipped = false
        for token in tokens[first...last] {
            switch token.kind {
            case .time:
                if !result.isEmpty {
                    result += skipped ? " " : separator
                }
                result += token.text
                separator = ""
                skipped = false
            case .literal:
                separator += token.text
            case .other:
                skipped = true
            }
        }
        return result
    }
    
    private static func difference(with zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        guard seconds != 0 else {
            return isL("Same time", fr: "Même heure")
        }
        
        let minutes = abs(seconds) / 60
        let h = minutes / 60
        let m = minutes % 60
        let amount: String
        if m == 0 {
            amount = isL(h == 1 ? "1 hour" : "\(h) hours", fr: h == 1 ? "1 heure" : "\(h) heures")
        } else if h == 0 {
            amount = "\(m) minutes"
        } else {
            amount = isL("\(h) h \(m) min", fr: "\(h) h \(String(format: "%02d", m))")
        }
        var text = seconds > 0 ? isL("\(amount) ahead", fr: "\(amount) d’avance") : isL("\(amount) behind", fr: "\(amount) de retard")
        
        // the date is not the same over there: whole days between the two wall clocks
        let stamp = date.timeIntervalSince1970
        let remoteDay = ((stamp + Double(zone.secondsFromGMT(for: date))) / 86400).rounded(.down)
        let localDay = ((stamp + Double(TimeZone.current.secondsFromGMT(for: date))) / 86400).rounded(.down)
        let days = Int(remoteDay - localDay)
        if days > 0 {
            text = "\(isL("Tomorrow", fr: "Demain")), \(text)"
        } else if days < 0 {
            text = "\(isL("Yesterday", fr: "Hier")), \(text)"
        }
        return text
    }
    
    // MARK: - Tooltip (the clock in its own format, as before)
    
    override func layout() {
        super.layout()
        if self.toolTipSize != self.bounds.size {
            self.toolTipSize = self.bounds.size
            self.removeAllToolTips()
            _ = self.addToolTip(self.bounds, owner: self, userData: nil)
        }
    }
}

extension ClockCard: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "\(self.clock.name): \(self.clock.formatted())"
    }
}

internal class ClockView: NSStackView {
    public var clock: Clock_t
    private let background: Bool
    
    open override var intrinsicContentSize: CGSize {
        return CGSize(width: self.bounds.width, height: self.bounds.height)
    }
    
    private let cache = PopupCache<Clock_t>()
    
    private let clockView: ClockChart = ClockChart(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
    private let nameField: NSTextField = TextView()
    private let timeField: NSTextField = TextView()
    private let tzField: NSTextField = TextView()
    private let dateField: NSTextField = TextView()
    
    init(width: CGFloat, clock: Clock_t, background: Bool = true, nameSize: CGFloat = 11, timeSize: CGFloat = 13) {
        self.clock = clock
        self.background = background
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 50))
        
        self.orientation = .horizontal
        self.distribution = .fill
        self.spacing = Constants.Popup.margins
        self.edgeInsets = NSEdgeInsets(
            top: Constants.Popup.margins,
            left: Constants.Popup.margins,
            bottom: Constants.Popup.margins,
            right: Constants.Popup.margins
        )
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.setAccessibilityElement(true)
        self.toolTip = "\(clock.name): \(clock.formatted())"
        
        self.clockView.widthAnchor.constraint(equalToConstant: 34).isActive = true
        
        let container: NSStackView = NSStackView()
        container.orientation = .vertical
        container.spacing = 2
        container.distribution = .fillEqually
        container.alignment = .leading
        
        self.nameField.font = NSFont.systemFont(ofSize: nameSize, weight: .medium)
        self.nameField.textColor = .tertiaryLabelColor
        self.nameField.stringValue = self.clock.name
        self.nameField.cell?.truncatesLastVisibleLine = true
        
        self.timeField.font = NSFont.systemFont(ofSize: timeSize, weight: .regular)
        self.timeField.stringValue = clock.formatted()
        self.timeField.cell?.truncatesLastVisibleLine = true
        
        container.addArrangedSubview(self.nameField)
        container.addArrangedSubview(self.timeField)
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let details: NSStackView = NSStackView()
        details.orientation = .vertical
        details.spacing = 2
        details.distribution = .fillEqually
        details.alignment = .trailing
        
        self.tzField.font = NSFont.systemFont(ofSize: nameSize, weight: .medium)
        self.tzField.textColor = .tertiaryLabelColor
        self.tzField.alignment = .trailing
        
        self.dateField.font = NSFont.systemFont(ofSize: nameSize, weight: .regular)
        self.dateField.textColor = .tertiaryLabelColor
        self.dateField.alignment = .trailing
        
        details.addArrangedSubview(self.tzField)
        details.addArrangedSubview(self.dateField)
        details.setContentHuggingPriority(.required, for: .horizontal)
        
        self.addArrangedSubview(self.clockView)
        self.addArrangedSubview(container)
        self.addArrangedSubview(details)
        
        self.update(clock)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        guard self.background else { return }
        self.layer?.backgroundColor = (self.isDarkMode ? NSColor(red: 17/255, green: 17/255, blue: 17/255, alpha: 0.25) : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)).cgColor
    }
    
    public func update(_ newClock: Clock_t) {
        if self.clock.tz != newClock.tz || self.clock.name != newClock.name {
            self.clock = newClock
            self.nameField.stringValue = self.clock.name
        }
        self.cache.apply(newClock, visible: self.window?.isVisible ?? false, render: self.renderClock)
    }
    
    private func renderClock(_ newClock: Clock_t) {
        self.timeField.stringValue = newClock.formatted()
        self.setDetails(newClock)
        if let value = newClock.value {
            self.clockView.setValue(value.convertToTimeZone(TimeZone(from: newClock.tz)))
        }
        self.clockView.display()
    }
    
    private func setDetails(_ clock: Clock_t) {
        let date = clock.value ?? Date()
        let tz = TimeZone(from: clock.tz)
        
        let seconds = tz.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600
        let minutes = abs(seconds) / 60 % 60
        self.tzField.stringValue = minutes == 0
            ? "GMT\(sign)\(hours)"
            : String(format: "GMT\(sign)%d:%02d", hours, minutes)
            
        guard clock.tz != "local" else {
            self.dateField.stringValue = ""
            self.dateField.isHidden = true
            return
        }
        self.dateField.isHidden = false
        
        var remote = Calendar.current
        remote.timeZone = tz
        var local = Calendar.current
        local.timeZone = .current
        let diff = (remote.ordinality(of: .day, in: .era, for: date) ?? 0) - (local.ordinality(of: .day, in: .era, for: date) ?? 0)
        
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = tz
        formatter.dateFormat = "EEE"
        var value = formatter.string(from: date)
        if diff > 0 {
            value += " · +\(diff)"
        } else if diff < 0 {
            value += " · \(diff)"
        }
        self.dateField.stringValue = value
    }
    
    public func appear() {
        self.cache.replay(render: self.renderClock)
    }
}

internal class ClockChart: NSView {
    private let calendar = Calendar.current
    private var hour: Int = 0
    private var minute: Int = 0
    private var second: Int = 0
    
    private let hourLayer = CALayer()
    private let minuteLayer = CALayer()
    private let secondsLayer = CALayer()
    private let pinLayer = CAShapeLayer()
    
    override init(frame: CGRect = NSRect.zero) {
        super.init(frame: frame)
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.setFillColor(NSColor.controlBackgroundColor.cgColor)
        context.setStrokeColor((self.isDarkMode ? NSColor.darkGray : NSColor.lightGray).cgColor)
        context.setLineWidth(1)
        context.addEllipse(in: CGRect(x: 0, y: 0, width: self.frame.width, height: self.frame.height))
        context.drawPath(using: .fillStroke)
        context.restoreGState()
        
        let anchor = CGPoint(x: 0.5, y: 0)
        let center = CGPoint(x: self.frame.size.width / 2, y: self.frame.size.height / 2)
        
        let hourAngle: CGFloat = CGFloat(Double(self.hour) * (360.0 / 12.0)) + CGFloat(Double(self.minute) * (1.0 / 60.0) * (360.0 / 12.0))
        let minuteAngle: CGFloat = CGFloat(self.minute) * CGFloat(360.0 / 60.0)
        let secondsAngle: CGFloat = CGFloat(self.second) * CGFloat(360.0 / 60.0)
        
        self.hourLayer.backgroundColor = NSColor.labelColor.cgColor
        self.hourLayer.anchorPoint = anchor
        self.hourLayer.position = center
        self.hourLayer.cornerRadius = 2
        self.hourLayer.bounds = CGRect(x: 0, y: 0, width: 2, height: self.frame.size.width / 2 - 4)
        self.hourLayer.transform = CATransform3DMakeRotation(-hourAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.hourLayer)
        
        self.minuteLayer.backgroundColor = NSColor.secondaryLabelColor.cgColor
        self.minuteLayer.anchorPoint = anchor
        self.minuteLayer.position = center
        self.minuteLayer.cornerRadius = 2
        self.minuteLayer.bounds = CGRect(x: 0, y: 0, width: 2, height: self.frame.size.width / 2 - 2)
        self.minuteLayer.transform = CATransform3DMakeRotation(-minuteAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.minuteLayer)
        
        self.secondsLayer.backgroundColor = NSColor.red.cgColor
        self.secondsLayer.anchorPoint = anchor
        self.secondsLayer.position = center
        self.secondsLayer.cornerRadius = 1
        self.secondsLayer.bounds = CGRect(x: 0, y: 0, width: 1, height: self.frame.size.width / 2 - 1)
        self.secondsLayer.transform = CATransform3DMakeRotation(-secondsAngle / 180 * CGFloat(Double.pi), 0, 0, 1)
        self.layer?.addSublayer(self.secondsLayer)
        
        self.pinLayer.fillColor = NSColor.controlBackgroundColor.cgColor
        self.pinLayer.strokeColor = (self.isDarkMode ? NSColor.darkGray : NSColor.lightGray).cgColor
        self.pinLayer.anchorPoint = anchor
        self.pinLayer.path = CGMutablePath(roundedRect: CGRect(
            x: center.x - 3 / 2,
            y: center.y - 3 / 2,
            width: 3,
            height: 3
        ), cornerWidth: 4, cornerHeight: 4, transform: nil)
        self.layer?.addSublayer(self.pinLayer)
    }
    
    public func setValue(_ value: Date) {
        self.hour = self.calendar.component(.hour, from: value)
        self.minute = self.calendar.component(.minute, from: value)
        self.second = self.calendar.component(.second, from: value)
        
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }
}

private class OrderTableView: NSView, NSTableViewDelegate, NSTableViewDataSource {
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var dragDropType = NSPasteboard.PasteboardType(rawValue: "\(Bundle.main.bundleIdentifier!).sensors-row")
    
    public var reorderCallback: () -> Void = {}
    public var list: [Clock_t] = []
    
    init() {
        super.init(frame: NSRect.zero)
        
        self.wantsLayer = true
        self.layer?.cornerRadius = 3
        
        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.documentView = self.tableView
        self.scrollView.hasHorizontalScroller = false
        self.scrollView.hasVerticalScroller = true
        self.scrollView.autohidesScrollers = true
        self.scrollView.backgroundColor = NSColor.clear
        self.scrollView.drawsBackground = true
        
        self.tableView.frame = self.scrollView.bounds
        self.tableView.delegate = self
        self.tableView.dataSource = self
        self.tableView.backgroundColor = NSColor.clear
        self.tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        self.tableView.registerForDraggedTypes([self.dragDropType])
        self.tableView.gridColor = .gridColor
        self.tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        self.tableView.style = .plain
        
        let nameColumn = NSTableColumn(identifier: nameColumnID)
        nameColumn.headerCell.title = localizedString("Name")
        nameColumn.headerCell.alignment = .center
        let statusColumn = NSTableColumn(identifier: statusColumnID)
        statusColumn.headerCell.title = ""
        statusColumn.width = 16
        
        self.tableView.addTableColumn(nameColumn)
        self.tableView.addTableColumn(statusColumn)
        
        self.addSubview(self.scrollView)
        
        NSLayoutConstraint.activate([
            self.scrollView.leftAnchor.constraint(equalTo: self.leftAnchor),
            self.scrollView.rightAnchor.constraint(equalTo: self.rightAnchor),
            self.scrollView.topAnchor.constraint(equalTo: self.topAnchor),
            self.scrollView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            
            self.heightAnchor.constraint(equalToConstant: 120)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update() {
        self.tableView.reloadData()
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return self.list.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if !self.list.indices.contains(row) { return nil }
        let item = self.list[row]
        
        let cell = NSTableCellView()
        
        switch tableColumn?.identifier {
        case nameColumnID:
            let text: NSTextField = NSTextField()
            text.drawsBackground = false
            text.isBordered = false
            text.isEditable = false
            text.isSelectable = false
            text.translatesAutoresizingMaskIntoConstraints = false
            text.identifier = NSUserInterfaceItemIdentifier(item.name)
            text.stringValue = item.name
            
            text.sizeToFit()
            
            cell.addSubview(text)
            
            NSLayoutConstraint.activate([
                text.widthAnchor.constraint(equalTo: cell.widthAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        case statusColumnID:
            let button: NSButton = NSButton(frame: NSRect(x: 0, y: 5, width: 10, height: 10))
            button.identifier = NSUserInterfaceItemIdentifier("\(row)")
            button.setButtonType(.switch)
            button.state = item.popupState ? .on : .off
            button.action = #selector(self.toggleClock)
            button.title = ""
            button.isBordered = false
            button.isTransparent = false
            button.target = self
            button.sizeToFit()
            
            cell.addSubview(button)
        default: break
        }
        
        return cell
    }
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: self.dragDropType)
        return item
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        var oldIndexes = [Int]()
        info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { dragItem, _, _ in
            if let item = dragItem.item as? NSPasteboardItem, let str = item.string(forType: self.dragDropType), let index = Int(str) {
                oldIndexes.append(index)
            }
        }
        
        var oldIndexOffset = 0
        var newIndexOffset = 0
        
        tableView.beginUpdates()
        for oldIndex in oldIndexes {
            let currentIdx: Int
            let newIdx: Int
            
            if oldIndex < row {
                currentIdx = oldIndex + oldIndexOffset
                newIdx = row - 1
                oldIndexOffset -= 1
            } else {
                currentIdx = oldIndex
                newIdx = row + newIndexOffset
                newIndexOffset += 1
            }
            
            if self.list.indices.contains(currentIdx) && self.list.indices.contains(newIdx) {
                self.list.insert(self.list.remove(at: currentIdx), at: newIdx)
            }
        }
        for i in self.list.indices {
            self.list[i].popupIndex = i
        }
        self.reorderCallback()
        tableView.reloadData()
        tableView.endUpdates()
        
        return true
    }
    
    @objc private func toggleClock(_ sender: NSButton) {
        guard let id = sender.identifier, let i = Int(id.rawValue) else { return }
        self.list[i].popupState = sender.state == NSControl.StateValue.on
    }
}
