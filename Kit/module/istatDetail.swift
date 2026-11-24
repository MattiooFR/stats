//
//  istatDetail.swift
//  Kit
//
//  Long history (1 hour to 30 days, kept on disk) and the side panel that opens next to a popup
//  while the pointer rests on one of its cards.
//

import Cocoa

// MARK: - Range

public enum ISRange: String, CaseIterable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    // every range is drawn with the same number of bars
    public static let slots: Int = 120
    public static let storeKey: String = "popup_history_range"

    // seconds covered by one bar
    public var bucket: TimeInterval {
        switch self {
        case .hour: return 30
        case .day: return 720
        case .week: return 5040
        case .month: return 21600
        }
    }
    public var duration: TimeInterval { self.bucket * Double(ISRange.slots) }

    public var title: String {
        switch self {
        case .hour: return isL("1 hour", fr: "1 heure")
        case .day: return isL("24 hours", fr: "24 heures")
        case .week: return isL("7 days", fr: "7 jours")
        case .month: return isL("30 days", fr: "30 jours")
        }
    }

    // review mode (popups opened under the wallpaper): the choice stays in memory, the settings of the installed app are not touched
    private static let review: Bool = !(ProcessInfo.processInfo.environment["STATS_DEBUG_POPUPS"] ?? "").isEmpty
    private static var reviewValue: ISRange?
    
    public static var current: ISRange {
        get {
            if let value = ISRange.reviewValue { return value }
            return ISRange(rawValue: Store.shared.string(key: ISRange.storeKey, defaultValue: ISRange.hour.rawValue)) ?? .hour
        }
        set {
            if ISRange.review {
                ISRange.reviewValue = newValue
            } else {
                Store.shared.set(key: ISRange.storeKey, value: newValue.rawValue)
            }
        }
    }
}

// MARK: - Series

// one bar of a history chart
public struct ISPoint {
    public let average: [Double]
    public let maximum: [Double]
    // value x seconds: for a rate (bytes per second) this is the amount itself
    public let total: [Double]
    public let seconds: Double
}

// a few values followed over time, kept as 120 slots for each range
public final class ISSeries {
    public enum Kind {
        // a level read at every tick (load, memory in use)
        case gauge
        // what was counted since the previous tick (bytes), kept as a rate per second
        case amount
    }

    public let key: String
    public let dimensions: Int
    public let kind: Kind

    private struct Slot {
        var index: Int64 = -1
        var seconds: Double = 0
        var totals: [Double]
        var peaks: [Double]
    }

    private var tiers: [[Slot]]
    private var last: TimeInterval?
    private var seeded: Bool = false
    private let lock = NSLock()
    // bumped by every sample; the one written to disk last is remembered, so a write that failed is tried again
    private var generation: UInt64 = 0
    private var savedGeneration: UInt64 = 0
    fileprivate var seeding: Bool = false
    
    fileprivate var dirty: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.generation != self.savedGeneration
    }
    
    fileprivate func markSaved(_ generation: UInt64) {
        self.lock.lock()
        self.savedGeneration = generation
        self.lock.unlock()
    }

    fileprivate init(key: String, dimensions: Int, kind: Kind) {
        self.key = key
        self.dimensions = dimensions
        self.kind = kind
        let empty = Slot(totals: Array(repeating: 0, count: dimensions), peaks: Array(repeating: 0, count: dimensions))
        self.tiers = Array(repeating: Array(repeating: empty, count: ISRange.slots), count: ISRange.allCases.count)
    }

    public func record(_ values: [Double], at date: Date = Date()) {
        guard values.count == self.dimensions, !values.contains(where: { !$0.isFinite }) else { return }
        let now = date.timeIntervalSince1970
        // a clock before 1970 would give negative slot numbers
        guard now > 0 else { return }

        self.lock.lock()
        defer { self.lock.unlock() }

        // the time this sample stands for: at least a second (two reads in a row must not look like a huge rate),
        // and a single second after a pause (sleep, module off)
        var seconds: Double = 1
        if let last = self.last, now - last > 1, now - last <= 90 {
            seconds = now - last
        }
        self.last = now
        let rates = self.kind == .amount ? values.map({ $0 / seconds }) : values

        if self.seeding && !self.seeded {
            self.seeded = true
            self.seed(rates, now: now)
        }

        for (t, range) in ISRange.allCases.enumerated() {
            let index = Int64((now / range.bucket).rounded(.down))
            let position = Int(index % Int64(ISRange.slots))
            if self.tiers[t][position].index != index {
                self.tiers[t][position] = Slot(
                    index: index,
                    seconds: 0,
                    totals: Array(repeating: 0, count: self.dimensions),
                    peaks: Array(repeating: 0, count: self.dimensions)
                )
            }
            self.tiers[t][position].seconds += seconds
            for i in 0..<self.dimensions {
                self.tiers[t][position].totals[i] += rates[i] * seconds
                self.tiers[t][position].peaks[i] = max(self.tiers[t][position].peaks[i], rates[i])
            }
        }
        self.generation &+= 1
    }

    // oldest first, always ISRange.slots items; nil where nothing was recorded (Mac asleep, app closed)
    public func points(_ range: ISRange, now: Date = Date()) -> [ISPoint?] {
        guard let t = ISRange.allCases.firstIndex(of: range) else { return [] }
        let current = Int64((now.timeIntervalSince1970 / range.bucket).rounded(.down))

        self.lock.lock()
        defer { self.lock.unlock() }

        var result: [ISPoint?] = []
        result.reserveCapacity(ISRange.slots)
        for index in (current - Int64(ISRange.slots) + 1)...current {
            guard index >= 0 else {
                result.append(nil)
                continue
            }
            let slot = self.tiers[t][Int(index % Int64(ISRange.slots))]
            guard slot.index == index, slot.seconds > 0 else {
                result.append(nil)
                continue
            }
            result.append(ISPoint(
                average: slot.totals.map({ $0 / slot.seconds }),
                maximum: slot.peaks,
                total: slot.totals,
                seconds: slot.seconds
            ))
        }
        return result
    }

    // review mode only: fills every range with a made up curve around the first real sample
    private func seed(_ values: [Double], now: TimeInterval) {
        for (t, range) in ISRange.allCases.enumerated() {
            let current = Int64((now / range.bucket).rounded(.down))
            for k in 1..<ISRange.slots {
                // a hole in the middle, like a night with the lid closed
                if k >= 38 && k < 47 { continue }
                let index = current - Int64(k)
                let position = Int(index % Int64(ISRange.slots))
                var slot = Slot(
                    index: index,
                    seconds: range.bucket,
                    totals: Array(repeating: 0, count: self.dimensions),
                    peaks: Array(repeating: 0, count: self.dimensions)
                )
                for i in 0..<self.dimensions {
                    let x = Double(k) + Double(t * 17)
                    let wave = 1 + 0.45 * sin(x * 0.21 + Double(i)) + 0.3 * sin(x * 0.057 + Double(i) * 2) + 0.15 * sin(x * 1.3)
                    let value = values[i] * max(0.08, wave)
                    slot.totals[i] = value * range.bucket
                    slot.peaks[i] = value * 1.6
                }
                self.tiers[t][position] = slot
            }
        }
    }

    fileprivate func encoded() -> (object: [String: Any], generation: UInt64) {
        self.lock.lock()
        defer { self.lock.unlock() }

        var tiers: [String: Any] = [:]
        for (t, range) in ISRange.allCases.enumerated() {
            var rows: [[Double]] = []
            for slot in self.tiers[t] where slot.index >= 0 && slot.seconds > 0 {
                rows.append([Double(slot.index), slot.seconds] + slot.totals + slot.peaks)
            }
            tiers[range.rawValue] = rows
        }
        return (["version": 1, "dimensions": self.dimensions, "tiers": tiers], self.generation)
    }

    fileprivate func decode(_ object: Any) {
        guard let root = object as? [String: Any],
              (root["dimensions"] as? Int) == self.dimensions,
              let tiers = root["tiers"] as? [String: Any] else { return }

        self.lock.lock()
        defer { self.lock.unlock() }

        for (t, range) in ISRange.allCases.enumerated() {
            guard let rows = tiers[range.rawValue] as? [[Double]] else { continue }
            for row in rows where row.count == 2 + self.dimensions * 2 && !row.contains(where: { !$0.isFinite }) {
                guard row[0] >= 0, row[0] < 1e15, row[1] > 0 else { continue }
                let index = Int64(row[0])
                self.tiers[t][Int(index % Int64(ISRange.slots))] = Slot(
                    index: index,
                    seconds: row[1],
                    totals: Array(row[2..<(2 + self.dimensions)]),
                    peaks: Array(row[(2 + self.dimensions)...])
                )
            }
        }
    }
}

public extension Array where Element == ISPoint? {
    // time weighted average of one value over what is on screen
    func isAverage(_ dim: Int) -> Double? {
        var total: Double = 0
        var seconds: Double = 0
        for case let point? in self where point.total.indices.contains(dim) {
            total += point.total[dim]
            seconds += point.seconds
        }
        return seconds > 0 ? total / seconds : nil
    }

    // highest single sample
    func isMaximum(_ dim: Int) -> Double? {
        self.compactMap({ $0 }).filter({ $0.maximum.indices.contains(dim) }).map({ $0.maximum[dim] }).max()
    }

    // value x time: the amount when the series is a rate
    func isTotal(_ dim: Int) -> Double? {
        let values = self.compactMap({ $0 }).filter({ $0.total.indices.contains(dim) }).map({ $0.total[dim] })
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}

// MARK: - Store

// keeps the series of every module and writes them to Application Support/Stats/history
public final class ISHistoryStore {
    public static let shared = ISHistoryStore()

    private var list: [String: ISSeries] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "eu.exelban.istat.history", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let directory: URL?
    private let persistent: Bool
    private let seeding: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        // the review mode (popups opened off screen) runs next to the installed app: it reads the history, never writes it
        self.persistent = (env["STATS_DEBUG_POPUPS"] ?? "").isEmpty
        self.seeding = env["STATS_DEBUG_HISTORY"] == "seed"
        self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Stats").appendingPathComponent("history")

        guard self.persistent, let directory = self.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 120, repeating: 300, leeway: .seconds(20))
        timer.setEventHandler { [weak self] in
            self?.write()
        }
        timer.resume()
        self.timer = timer

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync { self?.write() }
        }
    }

    public func series(_ key: String, dimensions: Int, kind: ISSeries.Kind = .gauge) -> ISSeries {
        self.lock.lock()
        defer { self.lock.unlock() }

        if let series = self.list[key], series.dimensions == dimensions {
            return series
        }
        let series = ISSeries(key: key, dimensions: dimensions, kind: kind)
        series.seeding = self.seeding
        if !self.seeding, let url = self.url(key), let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) {
            series.decode(object)
        }
        self.list[key] = series
        return series
    }

    private func url(_ key: String) -> URL? {
        let name = key.replacingOccurrences(of: "/", with: "-")
        return self.directory?.appendingPathComponent("\(name).json")
    }

    private func write() {
        guard self.persistent else { return }
        self.lock.lock()
        let pending = self.list.values.filter({ $0.dirty })
        self.lock.unlock()

        for series in pending {
            let snapshot = series.encoded()
            guard let url = self.url(series.key),
                  let data = try? JSONSerialization.data(withJSONObject: snapshot.object) else { continue }
            // only what reached the disk counts as saved
            if (try? data.write(to: url, options: .atomic)) != nil {
                series.markSaved(snapshot.generation)
            }
        }
    }
}

// MARK: - Chart

// 120 slots of history: stacked bars, two mirrored series or lines
public final class ISHistoryChart: NSView {
    public enum Style {
        case stacked
        case mirror
        case lines
    }

    public var colors: [NSColor]
    // which values of the series are drawn
    public var dims: [Int]
    // the value at the top of the chart; nil = the highest one on screen
    public var scale: Double?
    private let style: Style
    private var points: [ISPoint?] = []

    public init(style: Style, colors: [NSColor], dims: [Int], height: CGFloat, scale: Double? = nil) {
        self.style = style
        self.colors = colors
        self.dims = dims
        self.scale = scale
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ points: [ISPoint?]) {
        self.points = points
        self.needsDisplay = true
    }

    private func value(_ point: ISPoint, _ n: Int) -> Double {
        guard self.dims.indices.contains(n), point.average.indices.contains(self.dims[n]) else { return 0 }
        return max(0, point.average[self.dims[n]])
    }

    private func color(_ n: Int) -> NSColor {
        self.colors.indices.contains(n) ? self.colors[n] : (self.colors.last ?? ISTheme.current.blue)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let pixel = 1 / (self.window?.backingScaleFactor ?? 2)
        let height = self.bounds.height
        let middle = (self.bounds.midY / pixel).rounded() * pixel

        theme.track.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: self.style == .mirror ? middle - pixel / 2 : 0, width: self.bounds.width, height: pixel).fill()

        let known = self.points.compactMap({ $0 })
        guard !self.points.isEmpty, !known.isEmpty else {
            let text = NSAttributedString(string: isL("No history yet", fr: "Pas encore d’historique"), attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: theme.dim
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: (self.bounds.width - size.width) / 2, y: (height - size.height) / 2))
            return
        }

        let step = self.bounds.width / CGFloat(self.points.count)
        let width = max(step - pixel, pixel)

        switch self.style {
        case .stacked:
            let sums: [Double] = known.map({ p in self.dims.indices.map({ self.value(p, $0) }).reduce(0, +) })
            let top: Double = max(self.scale ?? (sums.max() ?? 0), 1e-9)
            for (i, point) in self.points.enumerated() {
                guard let point else { continue }
                let x = CGFloat(i) * step
                var y: CGFloat = 0
                for n in self.dims.indices {
                    var h = CGFloat(self.value(point, n) / top) * height
                    if y + h > height { h = height - y }
                    guard h > 0 else { continue }
                    self.color(n).setFill()
                    NSRect(x: x, y: y, width: width, height: max(h, pixel)).fill()
                    y += h
                }
            }
        case .mirror:
            let upTop: Double = max(self.scale ?? (known.map({ self.value($0, 0) }).max() ?? 0), 1e-9)
            let downTop: Double = max(self.scale ?? (known.map({ self.value($0, 1) }).max() ?? 0), 1e-9)
            let half = (height - pixel) / 2
            for (i, point) in self.points.enumerated() {
                guard let point else { continue }
                let x = CGFloat(i) * step
                let up = self.value(point, 0)
                let down = self.value(point, 1)
                self.color(0).setFill()
                NSRect(x: x, y: middle, width: width, height: max(min(CGFloat(up / upTop), 1) * half, up > 0 ? 1 : pixel)).fill()
                self.color(1).setFill()
                let h = max(min(CGFloat(down / downTop), 1) * half, down > 0 ? 1 : pixel)
                NSRect(x: x, y: middle - h, width: width, height: h).fill()
            }
        case .lines:
            let highs: [Double] = known.map({ p in self.dims.indices.map({ self.value(p, $0) }).max() ?? 0 })
            let top: Double = max(self.scale ?? (highs.max() ?? 0), 1e-9)
            for n in self.dims.indices.reversed() {
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.lineJoinStyle = .round
                path.lineCapStyle = .round
                var open = false
                for (i, point) in self.points.enumerated() {
                    guard let point else {
                        open = false
                        continue
                    }
                    let p = NSPoint(
                        x: (CGFloat(i) + 0.5) * step,
                        y: 1 + min(CGFloat(self.value(point, n) / top), 1) * (height - 2)
                    )
                    if open {
                        path.line(to: p)
                    } else {
                        path.move(to: p)
                        // a lonely sample still shows up as a dot
                        path.line(to: p)
                        open = true
                    }
                }
                self.color(n).setStroke()
                path.stroke()
            }
        }
    }
}

// "hier 21:14 ............ maintenant" under a history chart
public final class ISAxisRow: NSView {
    private let left: ISText
    private let right: ISText

    public init() {
        let theme = ISTheme.current
        self.left = ISText("", font: NSFont.systemFont(ofSize: 10, weight: .regular), color: theme.dim)
        self.right = ISText(isL("now", fr: "maintenant"), font: NSFont.systemFont(ofSize: 10, weight: .regular), color: theme.dim, alignment: .right)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 13).isActive = true
        self.addSubview(self.left)
        self.addSubview(self.right)
        NSLayoutConstraint.activate([
            self.left.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.left.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.right.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.right.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ range: ISRange, now: Date = Date()) {
        let start = now.addingTimeInterval(-range.duration)
        let formatter = DateFormatter()
        switch range {
        case .hour:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        case .day:
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
        case .week, .month:
            formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        }
        self.left.stringValue = formatter.string(from: start)
    }
}

// MARK: - Range switch

// "1 heure | 24 heures | 7 jours | 30 jours" at the top of a side panel
public final class ISRangeSelector: NSView {
    public var onChange: ((ISRange) -> Void)?
    private var hovered: Int? {
        didSet { if oldValue != self.hovered { self.needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    public init() {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // the panel never takes the keyboard, so every click is a "first" click
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func index(at point: NSPoint) -> Int? {
        guard self.bounds.contains(point), self.bounds.width > 0 else { return nil }
        let count = ISRange.allCases.count
        return min(count - 1, max(0, Int(point.x / (self.bounds.width / CGFloat(count)))))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let ranges = ISRange.allCases
        let current = ISRange.current
        let width = self.bounds.width / CGFloat(ranges.count)

        let frame = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        theme.border.setStroke()
        frame.lineWidth = 1
        frame.stroke()

        for (i, range) in ranges.enumerated() {
            let cell = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: self.bounds.height)
            let selected = range == current
            if selected {
                theme.blue.setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if self.hovered == i {
                theme.hover.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            let text = NSAttributedString(string: range.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? NSColor.white : theme.label
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking {
            self.removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.tracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        self.hovered = self.index(at: self.convert(event.locationInWindow, from: nil))
    }
    public override func mouseEntered(with event: NSEvent) {
        self.hovered = self.index(at: self.convert(event.locationInWindow, from: nil))
    }
    public override func mouseExited(with event: NSEvent) {
        self.hovered = nil
    }
    public override func mouseDown(with event: NSEvent) {
        guard let i = self.index(at: self.convert(event.locationInWindow, from: nil)) else { return }
        self.select(ISRange.allCases[i])
    }

    public func select(_ range: ISRange) {
        guard range != ISRange.current else { return }
        ISRange.current = range
        self.needsDisplay = true
        self.onChange?(range)
    }
}

// MARK: - Panel content

public protocol ISDetailContent: AnyObject {
    // called when the panel opens, when the range changes, then every two seconds
    func refresh()
}

// a card with a history chart and its time axis; the module adds its own rows and fills them in `summary`
public final class ISHistoryCard: ISCard, ISDetailContent {
    public let chart: ISHistoryChart
    public var summary: ((ISHistoryCard, [ISPoint?]) -> Void)?
    private let axis: ISAxisRow = ISAxisRow()
    private let series: ISSeries

    public init(title: String, series: ISSeries, style: ISHistoryChart.Style, colors: [NSColor], dims: [Int], height: CGFloat = 64, scale: Double? = nil) {
        self.series = series
        self.chart = ISHistoryChart(style: style, colors: colors, dims: dims, height: height, scale: scale)
        super.init(title: title, value: "")
        self.add(self.chart, spacingAfter: 2)
        self.add(self.axis, spacingAfter: 1)
        if let header = self.header {
            self.setCustomSpacing(3, after: header)
        }
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func refresh() {
        let range = ISRange.current
        let points = self.series.points(range)
        self.chart.set(points)
        self.axis.set(range)
        self.summary?(self, points)
    }
}

// a card of a side panel whose rows are filled by the module: at opening, then every two seconds
public final class ISLiveCard: ISCard, ISDetailContent {
    public var update: ((ISLiveCard) -> Void)?
    
    public func refresh() {
        self.update?(self)
    }
}

// what a side panel shows: the range switch on top when it holds history, then cards
public final class ISDetailStack: NSStackView, ISDetailContent {
    public init(width: CGFloat = 256, ranges: Bool = true) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = ISMetrics.spacing
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: width).isActive = true

        if ranges {
            let selector = ISRangeSelector()
            selector.onChange = { [weak self] _ in
                self?.refresh()
            }
            self.add(selector)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func add(_ view: NSView) {
        self.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
    }

    public func refresh() {
        self.arrangedSubviews.forEach { ($0 as? ISDetailContent)?.refresh() }
    }
}

// MARK: - Panel

private final class ISDetailRoot: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?

    init(content: NSView) {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.backgroundColor = ISTheme.current.background.cgColor
        self.translatesAutoresizingMaskIntoConstraints = false

        let margin = Constants.Popup.margins
        content.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: self.topAnchor, constant: margin),
            content.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -margin),
            content.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -margin)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        self.layer?.backgroundColor = ISTheme.current.background.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking {
            self.removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.tracking = area
    }

    override func mouseEntered(with event: NSEvent) { self.onEnter?() }
    override func mouseExited(with event: NSEvent) { self.onExit?() }
}

// same frame as a popup (rounded corners, shadow), but it never takes the keyboard:
// the popup stays the key window and keeps closing on a click elsewhere
private final class ISDetailPanel: NSPanel {
    let content: NSView
    let root: ISDetailRoot

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(content: NSView) {
        let root = ISDetailRoot(content: content)
        self.content = content
        self.root = root
        (content as? ISDetailContent)?.refresh()

        let holder = NSView(frame: .zero)
        holder.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: holder.topAnchor),
            root.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        let size = root.fittingSize
        holder.setFrameSize(size)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.contentView = holder
        self.setContentSize(size)
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.collectionBehavior = .moveToActiveSpace
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.appearance = NSAppearance(named: .darkAqua)
    }
    
    // the content can change height while the panel is open (a card that shows up): follow it, top edge fixed
    func fit() {
        let size = self.root.fittingSize
        guard abs(size.height - self.frame.height) > 0.5 || abs(size.width - self.frame.width) > 0.5 else { return }
        self.setFrame(NSRect(x: self.frame.minX, y: self.frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

// opens, moves and closes the side panel as the pointer travels over the cards of a popup
public final class ISDetailController {
    public static let shared = ISDetailController()

    private var panel: ISDetailPanel?
    private weak var card: ISCard?
    private var currentID: String?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var timer: Timer?
    private var debugPanels: [ISDetailPanel] = []

    private init() {}

    private func id(_ card: ISCard) -> String {
        card.detailID ?? "\(ObjectIdentifier(card).hashValue)"
    }

    internal func cardEntered(_ card: ISCard) {
        self.hideWork?.cancel()
        self.hideWork = nil
        guard card.detail != nil else { return }

        // cards that share a panel: it stays where it is, only the outline follows the pointer
        if self.panel != nil, self.currentID == self.id(card) {
            self.showWork?.cancel()
            self.showWork = nil
            self.setSource(card)
            return
        }

        self.showWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak card] in
            guard let self, let card else { return }
            self.show(card)
        }
        self.showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (self.panel == nil ? 0.18 : 0.1), execute: work)
    }

    internal func cardExited(_ card: ISCard) {
        self.showWork?.cancel()
        self.showWork = nil
        if self.panel != nil {
            self.scheduleHide()
        }
    }

    private func scheduleHide() {
        self.hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.close()
        }
        self.hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func setSource(_ card: ISCard?) {
        if self.card !== card {
            self.card?.detailOpen = false
        }
        self.card = card
        card?.detailOpen = true
    }

    public func close() {
        self.showWork?.cancel()
        self.showWork = nil
        self.hideWork?.cancel()
        self.hideWork = nil
        if self.debugPanels.isEmpty {
            self.timer?.invalidate()
            self.timer = nil
        }
        self.card?.detailOpen = false
        self.card = nil
        self.currentID = nil
        if let panel = self.panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    private func show(_ card: ISCard) {
        guard let window = card.window, window.isVisible, let builder = card.detail else { return }
        self.close()

        let panel = ISDetailPanel(content: builder())
        panel.root.onEnter = { [weak self] in
            self?.hideWork?.cancel()
            self?.hideWork = nil
        }
        panel.root.onExit = { [weak self] in
            self?.scheduleHide()
        }
        panel.level = window.level
        panel.setFrameOrigin(self.origin(panel.frame.size, card: card, window: window))
        window.addChildWindow(panel, ordered: .above)

        self.panel = panel
        self.currentID = self.id(card)
        self.setSource(card)
        self.startTimer()
    }

    // on the left of the popup (on the right when there is no room), its first card level with the hovered one
    private func origin(_ size: NSSize, card: ISCard, window: NSWindow) -> NSPoint {
        let gap: CGFloat = 4
        let rect = window.convertToScreen(card.convert(card.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame

        var x = window.frame.minX - size.width - gap
        if x < visible.minX + 3 {
            x = window.frame.maxX + gap
        }
        var y = rect.maxY + Constants.Popup.margins - size.height
        y = min(y, window.frame.maxY - size.height)
        y = max(y, visible.minY + 3)
        return NSPoint(x: x, y: y)
    }

    private func startTimer() {
        guard self.timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            (self.panel?.content as? ISDetailContent)?.refresh()
            self.panel?.fit()
            self.debugPanels.forEach {
                ($0.content as? ISDetailContent)?.refresh()
                $0.fit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // review mode: a click on the n-th segment of the range switch of the open panel,
    // sent through the application the way a real click arrives
    public func debugClickRange(_ index: Int) -> String {
        guard let panel = self.panel else { return "no panel open" }
        var selector: ISRangeSelector?
        func walk(_ parent: NSView) {
            if let found = parent as? ISRangeSelector { selector = found }
            parent.subviews.forEach { walk($0) }
        }
        walk(panel.root)
        guard let selector else { return "no range switch in the panel" }
        
        let cell = selector.bounds.width / CGFloat(ISRange.allCases.count)
        let point = selector.convert(NSPoint(x: (CGFloat(index) + 0.5) * cell, y: selector.bounds.midY), to: nil)
        let before = ISRange.current
        for type in [NSEvent.EventType.leftMouseDown, NSEvent.EventType.leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) {
                NSApp.sendEvent(event)
            }
        }
        return "range \(before.rawValue) -> \(ISRange.current.rawValue), panel became key: \(panel.isKeyWindow), popup still visible: \(panel.parent?.isVisible ?? false)"
    }
    
    // review mode: which views would receive a click in the open panel, and whether they take it
    // although the panel is not the key window (nothing is clicked)
    public func debugHitReport() -> [String] {
        guard let panel = self.panel, let content = panel.contentView else { return ["no panel open"] }
        var seen: [String: Int] = [:]
        var y: CGFloat = 4
        while y < content.bounds.height {
            for x in [0.1, 0.5, 0.94] {
                if let view = content.hitTest(NSPoint(x: content.bounds.width * CGFloat(x), y: y)) {
                    seen["\(type(of: view)) acceptsFirstMouse=\(view.acceptsFirstMouse(for: nil))", default: 0] += 1
                }
            }
            y += 6
        }
        return seen.map({ "\($0.key) x\($0.value)" }).sorted()
    }
    
    // review mode: the panel of a card, opened on its own under the wallpaper and left open
    public func debugOpen(_ card: ISCard, at origin: NSPoint) -> Int? {
        guard let builder = card.detail else { return nil }
        let panel = ISDetailPanel(content: builder())
        panel.level = Module.debugWindowLevel
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.debugPanels.append(panel)
        self.startTimer()
        return panel.windowNumber
    }
}
