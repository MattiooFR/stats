//
//  istat.swift
//  Kit
//
//  Card based popup design kit: a dark panel made of outlined cards, ring gauges,
//  bar history charts and process lists. Every module popup is built from these parts.
//

import Cocoa

// MARK: - Theme

public struct ISTheme {
    public let key: String
    public let name: String

    public let background: NSColor
    public let border: NSColor
    public let hover: NSColor
    public let title: NSColor
    public let label: NSColor
    public let value: NSColor
    public let dim: NSColor
    public let track: NSColor

    public let blue: NSColor
    public let pink: NSColor
    public let yellow: NSColor
    public let green: NSColor
    public let red: NSColor

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    public static let indigo = ISTheme(
        key: "indigo", name: "Indigo",
        background: rgb(0x252449), border: rgb(0x3a395b), hover: rgb(0x2f3a78),
        title: rgb(0x3478f6), label: rgb(0xcdcccd), value: rgb(0xffffff), dim: rgb(0x8f8ea6), track: rgb(0x60606c),
        blue: rgb(0x3478f6), pink: rgb(0xe45c9c), yellow: rgb(0xf6c844), green: rgb(0x45c466), red: rgb(0xf0524f)
    )
    public static let graphite = ISTheme(
        key: "graphite", name: "Graphite",
        background: rgb(0x272628), border: rgb(0x3c3b3c), hover: rgb(0x34425f),
        title: rgb(0x3478f6), label: rgb(0xcdcdcd), value: rgb(0xffffff), dim: rgb(0x8e8e93), track: rgb(0x616061),
        blue: rgb(0x3478f6), pink: rgb(0xe45c9c), yellow: rgb(0xf6c844), green: rgb(0x45c466), red: rgb(0xf0524f)
    )
    public static let navy = ISTheme(
        key: "navy", name: "Navy",
        background: rgb(0x151c33), border: rgb(0x2c3350), hover: rgb(0x22346b),
        title: rgb(0x3478f6), label: rgb(0xcdcccd), value: rgb(0xffffff), dim: rgb(0x858aa0), track: rgb(0x525768),
        blue: rgb(0x3478f6), pink: rgb(0xe45c9c), yellow: rgb(0xf6c844), green: rgb(0x45c466), red: rgb(0xf0524f)
    )
    public static let black = ISTheme(
        key: "black", name: "Black",
        background: rgb(0x0b0b0f), border: rgb(0x2a2a30), hover: rgb(0x1c2a52),
        title: rgb(0x3478f6), label: rgb(0xcdcdcd), value: rgb(0xffffff), dim: rgb(0x8e8e93), track: rgb(0x4a4a50),
        blue: rgb(0x3478f6), pink: rgb(0xe45c9c), yellow: rgb(0xf6c844), green: rgb(0x45c466), red: rgb(0xf0524f)
    )

    public static let all: [ISTheme] = [.indigo, .navy, .graphite, .black]
    public static let storeKey: String = "popup_theme"

    public static var current: ISTheme {
        let key = Store.shared.string(key: ISTheme.storeKey, defaultValue: ISTheme.indigo.key)
        return ISTheme.all.first(where: { $0.key == key }) ?? .indigo
    }
}

public struct ISMetrics {
    public static let spacing: CGFloat = 8
    public static let radius: CGFloat = 8
    public static let padH: CGFloat = 8
    public static let padV: CGFloat = 6
    public static let row: CGFloat = 17
    public static let icon: CGFloat = 16
}

public struct ISFont {
    public static func label(_ size: CGFloat = 13) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .regular)
    }
    public static func value(_ size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// number in the value font, unit in a smaller one: "15,7" + "Go"
public func isValue(_ number: String, _ unit: String = "", size: CGFloat = 13, color: NSColor? = nil, weight: NSFont.Weight = .medium, space: Bool = true) -> NSAttributedString {
    let c = color ?? ISTheme.current.value
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    paragraph.lineBreakMode = .byTruncatingTail
    let result = NSMutableAttributedString(string: number, attributes: [
        .font: ISFont.value(size, weight: weight),
        .foregroundColor: c,
        .paragraphStyle: paragraph
    ])
    if !unit.isEmpty {
        result.append(NSAttributedString(string: (space ? " " : "") + unit, attributes: [
            .font: ISFont.value((size * 0.8).rounded(), weight: weight),
            .foregroundColor: c,
            .paragraphStyle: paragraph
        ]))
    }
    return result
}

// "1,2 Go" -> ("1,2", "Go"), "45%" -> ("45", "%")
public func isSplit(_ string: String) -> (String, String) {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    guard let idx = trimmed.lastIndex(where: { $0.isNumber }) else { return (trimmed, "") }
    let number = String(trimmed[...idx])
    let unit = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    // only plain numbers are split ("1 day, 5 hours" stays as it is)
    if number.contains(where: { $0.isLetter }) || unit.count > 6 { return (trimmed, "") }
    return (number, unit)
}

public func isValue(split string: String, size: CGFloat = 13, color: NSColor? = nil) -> NSAttributedString {
    let (n, u) = isSplit(string)
    return isValue(n, u, size: size, color: color, space: u != "%" && u != "°")
}

// MARK: - Text

public class ISText: NSTextField {
    public init(_ string: String = "", font: NSFont = ISFont.label(), color: NSColor? = nil, alignment: NSTextAlignment = .left) {
        super.init(frame: .zero)
        self.isEditable = false
        self.isSelectable = false
        self.isBezeled = false
        self.drawsBackground = false
        self.font = font
        self.textColor = color ?? ISTheme.current.label
        self.alignment = alignment
        self.stringValue = string
        self.lineBreakMode = .byTruncatingTail
        self.maximumNumberOfLines = 1
        self.cell?.usesSingleLineMode = true
        self.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // a side panel never becomes the key window: without this, a click on a text inside it would be dropped
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

public class ISDot: NSView {
    public var color: NSColor {
        didSet { self.needsDisplay = true }
    }

    public init(_ color: NSColor, size: CGFloat = 9) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: size).isActive = true
        self.heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func draw(_ dirtyRect: NSRect) {
        self.color.setFill()
        NSBezierPath(ovalIn: self.bounds).fill()
    }
}

// MARK: - Card

open class ISCard: NSStackView {
    public private(set) var titleField: ISText?
    public private(set) var valueField: ISText?
    public private(set) var header: NSView?

    public var onClick: (() -> Void)? {
        didSet { self.updateTrackingAreas() }
    }
    // builds the side panel shown next to the popup while the pointer rests on this card
    public var detail: (() -> NSView)? {
        didSet { self.updateTrackingAreas() }
    }
    // cards with the same id share one panel: moving from one to the other keeps it open
    public var detailID: String?
    internal var detailOpen: Bool = false {
        didSet { if oldValue != self.detailOpen { self.needsDisplay = true } }
    }
    private var hovered: Bool = false {
        didSet { if oldValue != self.hovered { self.needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    public init(title: String? = nil, value: String? = nil) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: ISMetrics.padV, left: ISMetrics.padH, bottom: ISMetrics.padV, right: ISMetrics.padH)
        self.translatesAutoresizingMaskIntoConstraints = false

        if title != nil || value != nil {
            self.setHeader(title: title ?? "", value: value)
        }
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setHeader(title: String, value: String?) {
        let theme = ISTheme.current
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: ISMetrics.row + 1).isActive = true

        let titleField = ISText(title.uppercased(), font: ISFont.label(13), color: theme.title)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let valueField = ISText(value ?? "", font: ISFont.value(13), color: theme.value, alignment: .right)
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.setContentHuggingPriority(.required, for: .horizontal)

        row.addSubview(titleField)
        row.addSubview(valueField)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueField.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            valueField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: valueField.leadingAnchor, constant: -6)
        ])

        self.titleField = titleField
        self.valueField = valueField
        self.header = row
        self.add(row)
    }

    // column titles on the right side of the header (process lists: R/W, up/down)
    public func setHeaderColumns(_ titles: [String], width: CGFloat) {
        guard let header = self.header else { return }
        self.valueField?.isHidden = true
        var trailing = header.trailingAnchor
        var offset: CGFloat = 0
        for title in titles.reversed() {
            let field = ISText(title, font: ISFont.value(13), color: ISTheme.current.value, alignment: .right)
            header.addSubview(field)
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: trailing, constant: offset),
                field.widthAnchor.constraint(equalToConstant: width),
                field.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
            trailing = field.leadingAnchor
            offset = 0
        }
    }

    public func add(_ view: NSView, spacingAfter: CGFloat? = nil) {
        self.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -(ISMetrics.padH * 2)).isActive = true
        if let spacingAfter {
            self.setCustomSpacing(spacingAfter, after: view)
        }
    }

    public func removeAll(keepHeader: Bool = true) {
        self.arrangedSubviews.forEach { view in
            if keepHeader && view === self.header { return }
            self.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let path = NSBezierPath(roundedRect: self.bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ISMetrics.radius, yRadius: ISMetrics.radius)
        if (self.hovered && (self.onClick != nil || self.detail != nil)) || self.detailOpen {
            theme.hover.withAlphaComponent(0.55).setFill()
            path.fill()
            theme.blue.setStroke()
        } else {
            theme.border.setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking {
            self.removeTrackingArea(tracking)
            self.tracking = nil
        }
        guard self.onClick != nil || self.detail != nil else { return }
        let area = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.tracking = area
    }

    // same reason as ISText: cards also live in side panels, which never are the key window
    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseEntered(with event: NSEvent) {
        self.hovered = true
        if self.detail != nil {
            ISDetailController.shared.cardEntered(self)
        }
    }
    public override func mouseExited(with event: NSEvent) {
        self.hovered = false
        if self.detail != nil {
            ISDetailController.shared.cardExited(self)
        }
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil && self.detailOpen {
            ISDetailController.shared.close()
        }
    }
    public override func mouseUp(with event: NSEvent) {
        if let onClick = self.onClick, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
            onClick()
        } else {
            super.mouseUp(with: event)
        }
    }
}

// MARK: - Row

public class ISRow: NSView {
    public let labelField: ISText
    public let valueField: ISText
    public private(set) var dot: ISDot?
    public private(set) var iconView: NSImageView?

    public init(_ label: String, value: String = "", color: NSColor? = nil, icon: NSImage? = nil, dim: Bool = false, height: CGFloat = ISMetrics.row) {
        let theme = ISTheme.current
        self.labelField = ISText(label, font: ISFont.label(13), color: dim ? theme.dim : theme.label)
        self.valueField = ISText("", font: ISFont.value(13), color: dim ? theme.dim : theme.value, alignment: .right)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true

        self.labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.valueField.setContentHuggingPriority(.required, for: .horizontal)
        self.addSubview(self.labelField)
        self.addSubview(self.valueField)

        var leading = self.leadingAnchor
        var gap: CGFloat = 0
        if let color {
            let dot = ISDot(color)
            self.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: self.centerYAnchor)
            ])
            self.dot = dot
            leading = dot.trailingAnchor
            gap = 3
        } else if let icon {
            let view = NSImageView(image: icon)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = theme.blue
            self.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: self.leadingAnchor),
                view.centerYAnchor.constraint(equalTo: self.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: ISMetrics.icon),
                view.heightAnchor.constraint(equalToConstant: ISMetrics.icon)
            ])
            self.iconView = view
            leading = view.trailingAnchor
            gap = 4
        }

        NSLayoutConstraint.activate([
            self.labelField.leadingAnchor.constraint(equalTo: leading, constant: gap),
            self.labelField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.valueField.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.valueField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.labelField.trailingAnchor.constraint(lessThanOrEqualTo: self.valueField.leadingAnchor, constant: -6)
        ])

        if !value.isEmpty { self.set(value) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // "12,3 Go" is split automatically: digits in normal size, unit smaller
    public func set(_ value: String) {
        self.valueField.attributedStringValue = isValue(split: value, color: self.valueField.textColor)
    }
    public func set(_ number: String, unit: String) {
        self.valueField.attributedStringValue = isValue(number, unit, color: self.valueField.textColor, space: unit != "%" && unit != "°")
    }
    public func setPlain(_ value: String) {
        self.valueField.stringValue = value
    }
}

// two "● label value" items on a single line (User 26%  ● System 7%)
public class ISLegendRow: NSView {
    private var fields: [ISText] = []

    public init(_ items: [(String, NSColor)]) {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true

        let theme = ISTheme.current
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        for (title, color) in items {
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            let dot = ISDot(color)
            let label = ISText(title, font: ISFont.label(13), color: theme.label)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let value = ISText("", font: ISFont.value(13), color: theme.value, alignment: .right)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            cell.addSubview(dot)
            cell.addSubview(label)
            cell.addSubview(value)
            NSLayoutConstraint.activate([
                dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                value.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                value.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -4)
            ])
            stack.addArrangedSubview(cell)
            self.fields.append(value)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ idx: Int, _ value: String) {
        guard self.fields.indices.contains(idx) else { return }
        self.fields[idx].attributedStringValue = isValue(split: value)
    }
}

// MARK: - Ring gauge

public struct ISRingSegment {
    public let value: Double
    public let color: NSColor

    public init(_ value: Double, _ color: NSColor) {
        self.value = value
        self.color = color
    }
}

public class ISRing: NSView {
    private var segments: [ISRingSegment] = []
    private var main: NSAttributedString?
    private var caption: String?
    private var symbol: NSImage?
    private var footer: String?

    public var lineWidth: CGFloat
    private let diameter: CGFloat

    public init(diameter: CGFloat, lineWidth: CGFloat) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: diameter).isActive = true
        self.heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ segments: [ISRingSegment]) {
        self.segments = segments
        self.needsDisplay = true
    }

    public func set(value: Double, color: NSColor? = nil) {
        self.set([ISRingSegment(value, color ?? ISTheme.current.blue)])
    }

    // number + small unit in the middle, optional caption under it, optional symbol above
    public func setText(_ number: String, unit: String = "", caption: String? = nil, symbol: NSImage? = nil, footer: String? = nil) {
        let big = self.diameter >= 80
        let size: CGFloat = big ? 27 : (self.diameter >= 60 ? 16 : 14)
        let theme = ISTheme.current
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: big ? .regular : .medium),
            .foregroundColor: theme.value
        ])
        if !unit.isEmpty {
            text.append(NSAttributedString(string: unit, attributes: [
                .font: NSFont.systemFont(ofSize: (size * 0.62).rounded(), weight: .medium),
                .foregroundColor: theme.value
            ]))
        }
        self.main = text
        self.caption = caption
        self.symbol = symbol
        self.footer = footer
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let center = NSPoint(x: self.bounds.midX, y: self.bounds.midY)
        let radius = (min(self.bounds.width, self.bounds.height) - self.lineWidth) / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = self.lineWidth
        theme.track.setStroke()
        track.stroke()

        var start: CGFloat = 90
        for segment in self.segments {
            let value = CGFloat(max(0, min(1, segment.value)))
            guard value > 0 else { continue }
            let end = start - (360 * value)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = self.lineWidth
            segment.color.setStroke()
            arc.stroke()
            start = end
        }

        guard let main = self.main else { return }
        let big = self.diameter >= 80
        let captionAttr: NSAttributedString? = self.caption.map {
            NSAttributedString(string: $0.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: big ? 10 : 9, weight: .medium),
                .foregroundColor: big ? theme.value : theme.label
            ])
        }
        let footerAttr: NSAttributedString? = self.footer.map {
            NSAttributedString(string: $0, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: big ? 13 : 10, weight: .medium),
                .foregroundColor: theme.value
            ])
        }

        let mainSize = main.size()
        let mainHeight = mainSize.height * 0.86
        let symbolHeight: CGFloat = self.symbol == nil ? 0 : (big ? 15 : 10)
        let captionHeight: CGFloat = (captionAttr?.size().height ?? 0) * 0.92
        let footerHeight: CGFloat = (footerAttr?.size().height ?? 0) * 0.92
        let total = symbolHeight + mainHeight + captionHeight + footerHeight
        var y = center.y + total / 2

        if let symbol = self.symbol {
            y -= symbolHeight
            let ratio = symbol.size.height > 0 ? symbol.size.width / symbol.size.height : 1
            let rect = NSRect(x: center.x - (symbolHeight * ratio) / 2, y: y, width: symbolHeight * ratio, height: symbolHeight)
            let color = theme.value
            let tinted = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }
        y -= mainHeight
        main.draw(at: NSPoint(x: center.x - mainSize.width / 2, y: y - mainSize.height * 0.07))
        if let captionAttr {
            y -= captionHeight
            captionAttr.draw(at: NSPoint(x: center.x - captionAttr.size().width / 2, y: y))
        }
        if let footerAttr {
            y -= footerHeight
            footerAttr.draw(at: NSPoint(x: center.x - footerAttr.size().width / 2, y: y))
        }
    }
}

// a row of ring gauges spread over the full width
public class ISRingRow: NSStackView {
    public private(set) var rings: [ISRing] = []

    public init(count: Int, diameter: CGFloat, lineWidth: CGFloat, vertical: CGFloat = 4) {
        super.init(frame: .zero)
        self.orientation = .horizontal
        self.distribution = .equalSpacing
        self.alignment = .centerY
        self.translatesAutoresizingMaskIntoConstraints = false
        self.edgeInsets = NSEdgeInsets(top: vertical, left: 0, bottom: vertical, right: 0)

        if count == 1 {
            self.distribution = .equalCentering
        }
        for _ in 0..<count {
            let ring = ISRing(diameter: diameter, lineWidth: lineWidth)
            self.rings.append(ring)
            self.addArrangedSubview(ring)
        }
        self.heightAnchor.constraint(equalToConstant: diameter + vertical * 2).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// grid of small rings, one per CPU core
public class ISCoreRings: NSView {
    private var values: [ColorValue] = []
    private let count: Int
    private let perRow: Int
    private let gap: CGFloat = 3
    private let maxDiameter: CGFloat = 24
    private var heightConstraint: NSLayoutConstraint?

    public init(count: Int) {
        self.count = max(1, count)
        self.perRow = self.count <= 12 ? self.count : Int((Double(self.count) / 2).rounded(.up))
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightConstraint = self.heightAnchor.constraint(equalToConstant: self.maxDiameter + 4)
        self.heightConstraint?.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var diameter: CGFloat {
        let available = self.bounds.width - (CGFloat(self.perRow - 1) * self.gap)
        return max(8, min(self.maxDiameter, available / CGFloat(self.perRow)))
    }
    private var rows: Int {
        Int((Double(self.count) / Double(self.perRow)).rounded(.up))
    }

    public override func layout() {
        super.layout()
        let height = (CGFloat(self.rows) * self.diameter) + (CGFloat(self.rows - 1) * self.gap) + 4
        if self.heightConstraint?.constant != height {
            self.heightConstraint?.constant = height
        }
    }

    public func set(_ values: [ColorValue]) {
        self.values = values
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let d = self.diameter
        let lineWidth = max(2, d * 0.13)
        let radius = (d - lineWidth) / 2
        let pitch = self.perRow > 1 ? (self.bounds.width - d) / CGFloat(self.perRow - 1) : 0

        for i in 0..<self.count {
            let col = i % self.perRow
            let row = i / self.perRow
            let center = NSPoint(
                x: (d / 2) + (CGFloat(col) * pitch),
                y: self.bounds.height - 2 - (d / 2) - (CGFloat(row) * (d + self.gap))
            )
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            theme.track.setStroke()
            track.stroke()

            guard self.values.indices.contains(i) else { continue }
            let value = CGFloat(max(0, min(1, self.values[i].value)))
            guard value > 0.005 else { continue }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - (360 * value), clockwise: true)
            arc.lineWidth = lineWidth
            (self.values[i].color ?? theme.blue).setStroke()
            arc.stroke()
        }
    }
}

// MARK: - Charts

// history of stacked bars, newest value on the right
public class ISBarChart: NSView {
    public var colors: [NSColor]
    public var barWidth: CGFloat = 2
    public var gap: CGFloat = 1
    // nil = scale to the highest value on screen
    public var maxValue: Double? = 1
    private var points: [[Double]] = []

    public init(colors: [NSColor], height: CGFloat) {
        self.colors = colors
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ points: [[Double]]) {
        self.points = points
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !self.points.isEmpty else { return }
        let step = self.barWidth + self.gap
        let capacity = Int(self.bounds.width / step)
        guard capacity > 0 else { return }
        let visible = Array(self.points.suffix(capacity))
        let peak = self.maxValue ?? max(visible.map({ $0.reduce(0, +) }).max() ?? 1, 0.0001)

        var x = self.bounds.width - self.barWidth
        for point in visible.reversed() {
            var y: CGFloat = 0
            for (i, raw) in point.enumerated() {
                let value = CGFloat(max(0, raw) / peak)
                var h = value * self.bounds.height
                if y + h > self.bounds.height { h = self.bounds.height - y }
                if h > 0 {
                    (self.colors.indices.contains(i) ? self.colors[i] : self.colors.last ?? .white).setFill()
                    NSRect(x: x, y: y, width: self.barWidth, height: max(h, 0.5)).fill()
                }
                y += h
            }
            x -= step
        }
    }
}

// two series around a middle line: first one goes up, second one goes down
public class ISMirrorChart: NSView {
    public var upColor: NSColor
    public var downColor: NSColor
    public var barWidth: CGFloat = 2
    public var gap: CGFloat = 1
    private var points: [(Double, Double)] = []

    public init(up: NSColor, down: NSColor, height: CGFloat) {
        self.upColor = up
        self.downColor = down
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ points: [(Double, Double)]) {
        self.points = points
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !self.points.isEmpty else { return }
        let step = self.barWidth + self.gap
        let capacity = Int(self.bounds.width / step)
        guard capacity > 0 else { return }
        let visible = Array(self.points.suffix(capacity))
        let upPeak = max(visible.map({ $0.0 }).max() ?? 0, 1)
        let downPeak = max(visible.map({ $0.1 }).max() ?? 0, 1)
        let half = (self.bounds.height - 1) / 2
        let middle = self.bounds.midY

        var x = self.bounds.width - self.barWidth
        for point in visible.reversed() {
            let up = max(CGFloat(point.0 / upPeak) * half, point.0 > 0 ? 1 : 0.5)
            let down = max(CGFloat(point.1 / downPeak) * half, point.1 > 0 ? 1 : 0.5)
            self.upColor.setFill()
            NSRect(x: x, y: middle, width: self.barWidth, height: up).fill()
            self.downColor.setFill()
            NSRect(x: x, y: middle - down, width: self.barWidth, height: down).fill()
            x -= step
        }
    }
}

public class ISProgressBar: NSView {
    public var color: NSColor?
    private var value: Double = 0

    public init(height: CGFloat = 7) {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ value: Double) {
        self.value = max(0, min(1, value))
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let theme = ISTheme.current
        let rect = self.bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(3, rect.height / 2)
        let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        track.addClip()
        (self.color ?? theme.blue).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(self.value), height: rect.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        theme.track.withAlphaComponent(0.75).setStroke()
        track.lineWidth = 1
        track.stroke()
    }
}

// "big value + ● caption" block used above the mirror charts (28 Ko/s ● Envoyé)
public class ISBigValue: NSView {
    private let valueField: ISText

    public init(caption: String, color: NSColor) {
        let theme = ISTheme.current
        self.valueField = ISText("—", font: ISFont.value(18, weight: .regular), color: theme.value, alignment: .center)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false

        let dot = ISDot(color)
        let captionField = ISText(caption, font: ISFont.label(13), color: theme.label)
        let legend = NSStackView(views: [dot, captionField])
        legend.orientation = .horizontal
        legend.spacing = 4
        legend.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(self.valueField)
        self.addSubview(legend)
        NSLayoutConstraint.activate([
            self.valueField.topAnchor.constraint(equalTo: self.topAnchor),
            self.valueField.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.valueField.widthAnchor.constraint(lessThanOrEqualTo: self.widthAnchor),
            legend.topAnchor.constraint(equalTo: self.valueField.bottomAnchor, constant: -3),
            legend.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            legend.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ value: String) {
        self.valueField.stringValue = value
    }
}

// MARK: - Process list

public class ISProcessList: NSStackView {
    private var rows: [ISProcessRow] = []
    public var count: Int { self.rows.count }

    public init(n: Int, columns: Int = 1, columnWidth: CGFloat = 56) {
        super.init(frame: .zero)
        self.orientation = .vertical
        self.alignment = .leading
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false

        for _ in 0..<n {
            let row = ISProcessRow(columns: columns, columnWidth: columnWidth)
            self.rows.append(row)
            self.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func set(_ idx: Int, _ process: Process_p, _ values: [String]) {
        guard self.rows.indices.contains(idx) else { return }
        self.rows[idx].set(icon: process.icon, name: process.name, pid: process.pid, values: values)
    }

    public func set(_ idx: Int, icon: NSImage?, name: String, values: [String]) {
        guard self.rows.indices.contains(idx) else { return }
        self.rows[idx].set(icon: icon, name: name, pid: nil, values: values)
    }

    public func clear(from idx: Int = 0) {
        guard idx < self.rows.count else { return }
        for i in max(0, idx)..<self.rows.count {
            self.rows[i].clear()
        }
    }
}

public class ISProcessRow: NSView {
    private let iconView: NSImageView = NSImageView()
    private let nameField: ISText
    private var valueFields: [ISText] = []
    private var pid: Int?

    public init(columns: Int, columnWidth: CGFloat) {
        let theme = ISTheme.current
        self.nameField = ISText("", font: ISFont.label(13), color: theme.value)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true

        self.iconView.translatesAutoresizingMaskIntoConstraints = false
        self.iconView.imageScaling = .scaleProportionallyUpOrDown
        self.nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.addSubview(self.iconView)
        self.addSubview(self.nameField)

        var trailing = self.trailingAnchor
        for _ in 0..<max(1, columns) {
            let field = ISText("", font: ISFont.value(13), color: theme.value, alignment: .right)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            self.addSubview(field)
            NSLayoutConstraint.activate([
                field.trailingAnchor.constraint(equalTo: trailing),
                field.centerYAnchor.constraint(equalTo: self.centerYAnchor)
            ])
            if columns > 1 {
                field.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            } else {
                field.setContentHuggingPriority(.required, for: .horizontal)
            }
            trailing = field.leadingAnchor
            // fields are created right to left, keep them in reading order
            self.valueFields.insert(field, at: 0)
        }

        NSLayoutConstraint.activate([
            self.iconView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.iconView.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.iconView.widthAnchor.constraint(equalToConstant: 15),
            self.iconView.heightAnchor.constraint(equalToConstant: 15),
            self.nameField.leadingAnchor.constraint(equalTo: self.iconView.trailingAnchor, constant: 5),
            self.nameField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.nameField.trailingAnchor.constraint(lessThanOrEqualTo: trailing, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    fileprivate func set(icon: NSImage?, name: String, pid: Int?, values: [String]) {
        self.pid = pid
        self.iconView.image = icon
        self.nameField.stringValue = name
        self.toolTip = pid.map { "pid: \($0)" }
        for (i, field) in self.valueFields.enumerated() {
            field.attributedStringValue = values.indices.contains(i) ? isValue(split: values[i]) : NSAttributedString(string: "")
        }
    }

    fileprivate func clear() {
        self.pid = nil
        self.iconView.image = nil
        self.nameField.stringValue = ""
        self.toolTip = nil
        self.valueFields.forEach { $0.stringValue = "" }
    }
}

// MARK: - Shortcut bar

public struct ISShortcut {
    public let icon: NSImage?
    public let toolTip: String
    public let action: () -> Void

    public init(icon: NSImage?, toolTip: String, action: @escaping () -> Void) {
        self.icon = icon
        self.toolTip = toolTip
        self.action = action
    }

    public static func app(_ bundleID: String, fallbackPath: String? = nil, toolTip: String? = nil, before: (() -> Void)? = nil) -> ISShortcut? {
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        if url == nil, let fallbackPath, FileManager.default.fileExists(atPath: fallbackPath) {
            url = URL(fileURLWithPath: fallbackPath)
        }
        guard let url else { return nil }
        let name = toolTip ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return ISShortcut(icon: NSWorkspace.shared.icon(forFile: url.path), toolTip: name) {
            before?()
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    public static func link(_ string: String, symbol: String, toolTip: String) -> ISShortcut? {
        guard let url = URL(string: string) else { return nil }
        return ISShortcut(icon: NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip), toolTip: toolTip) {
            NSWorkspace.shared.open(url)
        }
    }
}

private class ISShortcutButton: NSButton {
    var handler: (() -> Void)?

    @objc func fire() {
        (self.window as? PopupWindow)?.dismissIfUnlocked()
        self.handler?()
    }
}

public class ISShortcutBar: ISCard {
    public init(module: ModuleType, extra: [ISShortcut?] = []) {
        super.init()
        self.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

        var items: [ISShortcut] = []
        if let item = ISShortcut.app("com.apple.ActivityMonitor", before: {
            if let tab = module.activityMonitorTab {
                UserDefaults(suiteName: "com.apple.ActivityMonitor")?.set(tab, forKey: "SelectedTab")
            }
        }) {
            items.append(item)
        }
        if let item = ISShortcut.app("com.apple.Console") { items.append(item) }
        if let item = ISShortcut.app("com.apple.Terminal") { items.append(item) }
        extra.forEach { if let item = $0 { items.append(item) } }
        items.append(ISShortcut(icon: NSApp.applicationIconImage, toolTip: localizedString("Open module")) {
            NotificationCenter.default.post(name: .toggleSettings, object: nil, userInfo: ["module": module.stringValue])
        })

        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 18).isActive = true

        for item in items {
            let button = ISShortcutButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.image = item.icon
            button.contentTintColor = ISTheme.current.label
            button.toolTip = item.toolTip
            button.focusRingType = .none
            button.handler = item.action
            button.target = button
            button.action = #selector(ISShortcutButton.fire)
            button.widthAnchor.constraint(equalToConstant: 18).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(button)
        }

        self.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: self.widthAnchor, constant: -24).isActive = true
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - History buffer

// fixed size history kept by the popup object, the charts only draw it
public final class ISHistory<T> {
    public private(set) var values: [T] = []
    private let capacity: Int

    public init(capacity: Int = 160) {
        self.capacity = capacity
    }

    public func append(_ value: T) {
        self.values.append(value)
        if self.values.count > self.capacity {
            self.values.removeFirst(self.values.count - self.capacity)
        }
    }
}

// MARK: - Helpers

// wording that only exists in this design, without touching every Localizable.strings
public func isL(_ en: String, fr: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("fr") ? fr : en
}

public func isNumber(_ value: Double, digits: Int = 1) -> String {
    String(format: "%.\(digits)f", locale: Locale.current, value)
}

public func isPercent(_ value: Double) -> String {
    "\(Int((max(0, value) * 100).rounded()))%"
}
