//
//  popup.swift
//  Battery
//
//  Created by Serhiy Mytrovtsiy on 06/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

// one point of the level history: how full the battery was and where the power came from
private struct BatterySample {
    let level: Double
    let onAC: Bool
}

internal class Popup: PopupWrapper {
    // Stats stores no battery history: the popup keeps its own, one point a minute, 24 hours
    private let levelHistory = ISHistory<BatterySample>(capacity: 1440)
    private var lastSampleAt: Date? = nil
    private var lastSampleOnAC: Bool? = nil

    private var levelRing: ISRing? = nil
    private var healthRing: ISRing? = nil
    private var chart: ISBarChart? = nil
    private var strip: BatterySourceStrip? = nil

    private var modeCard: ISCard? = nil

    private var significantApps: ISProcessList? = nil
    private var significantNone: NSView? = nil
    private var processes: ISProcessList? = nil

    private var adapterCard: ISCard? = nil
    private var adapterPowerRow: ISRow? = nil
    private var adapterCurrentRow: ISRow? = nil
    private var adapterVoltageRow: ISRow? = nil
    private var chargingRow: ISRow? = nil

    private var powerRow: ISRow? = nil
    private var currentRow: ISRow? = nil
    private var voltageRow: ISRow? = nil
    private var temperatureRow: ISRow? = nil
    private var sourceRow: ISRow? = nil
    private var timeRow: ISRow? = nil

    private var cyclesRow: ISRow? = nil
    private var conditionRow: ISRow? = nil
    private var designCapacityRow: ISRow? = nil
    private var maxCapacityRow: ISRow? = nil

    private let processesCache = PopupCache<[TopProcess]>()
    private let usageCache = PopupCache<Battery_Usage>()

    // energy mode of the current power source, read with pmset on a background queue
    private var modeInfo: PowerModeInfo? = nil
    private var modeReadAt: Date? = nil
    private var modeReading: Bool = false
    private var modeReadAgain: Bool = false
    private var modeChanging: Bool = false

    // battery condition, only fetched when the reader does not provide it (Apple silicon)
    private var condition: String? = nil
    private var conditionReadAt: Date? = nil
    private var conditionReading: Bool = false

    // process pid -> pid of the app it is shown under (0 = not an app)
    private var ownerCache: [Int: pid_t] = [:]

    private let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1
    // "energy impact" (the power column of top) from which an app is listed as using significant energy
    private let significantPower: Double = 20

    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 5)
    }
    private var timeFormat: String {
        Store.shared.string(key: "\(self.title)_timeFormat", defaultValue: "short")
    }
    private var contentWidth: CGFloat {
        self.frame.width - (ISMetrics.padH * 2)
    }
    private var modeTitle: String {
        isL("Energy Mode", fr: "Mode d’énergie")
    }

    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 240, height: 0))

        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadContent() {
        self.addSection(self.initRings())
        self.addSection(self.initHistory())
        self.addSection(self.initMode())
        if self.numberOfProcesses > 0 {
            self.addSection(self.initSignificant())
            self.addSection(self.initProcesses())
        }
        self.addSection(ISShortcutBar(module: .battery, extra: [
            ISShortcut.link(
                "x-apple.systempreferences:com.apple.Battery-Settings.extension",
                symbol: "battery.100",
                toolTip: isL("Battery Settings", fr: "Réglages Batterie")
            )
        ]))

        self.resizeToFitContent()
    }

    public override func unloadContent() {
        self.levelRing = nil
        self.healthRing = nil
        self.chart = nil
        self.strip = nil
        self.modeCard = nil
        self.significantApps = nil
        self.significantNone = nil
        self.processes = nil
        self.adapterCard = nil
        self.adapterPowerRow = nil
        self.adapterCurrentRow = nil
        self.adapterVoltageRow = nil
        self.chargingRow = nil
        self.powerRow = nil
        self.currentRow = nil
        self.voltageRow = nil
        self.temperatureRow = nil
        self.sourceRow = nil
        self.timeRow = nil
        self.cyclesRow = nil
        self.conditionRow = nil
        self.designCapacityRow = nil
        self.maxCapacityRow = nil
    }

    public override func appear() {
        self.ownerCache.removeAll()
        self.replay(self.usageCache, render: self.renderUsage)
        self.replay(self.processesCache, render: self.renderProcesses)
        self.renderMode()
        self.renderCondition()
        self.refreshMode()
        self.refreshCondition()
    }

    // MARK: - Views

    private func initRings() -> NSView {
        let card = ISCard()
        card.edgeInsets = NSEdgeInsets(top: ISMetrics.padV, left: 16, bottom: ISMetrics.padV, right: 16)

        let row = ISRingRow(count: 2, diameter: 96, lineWidth: 7, vertical: 2)
        card.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -32).isActive = true

        self.levelRing = row.rings[0]
        self.healthRing = row.rings[1]
        self.levelRing?.setText("—", caption: localizedString("Battery"))
        self.healthRing?.setText("—", caption: localizedString("Health"))
        self.attachDetails(card)

        return card
    }

    private func initHistory() -> NSView {
        let theme = ISTheme.current
        let card = ISCard()
        card.edgeInsets = NSEdgeInsets(top: 8, left: ISMetrics.padH, bottom: 4, right: ISMetrics.padH)

        // blue while on the power adapter, pink while on battery
        let chart = ISBarChart(colors: [theme.blue, theme.pink], height: 48)
        chart.barWidth = self.barWidth
        chart.gap = self.barGap
        chart.maxValue = 1
        card.add(chart, spacingAfter: 1)
        self.chart = chart

        let strip = BatterySourceStrip(height: 14)
        strip.barWidth = self.barWidth
        strip.gap = self.barGap
        card.add(strip)
        self.strip = strip
        self.attachDetails(card)

        return card
    }

    private func initMode() -> NSView {
        let card = ISCard(title: self.modeTitle, value: "—")
        card.onClick = { [weak self] in
            self?.showModeMenu()
        }
        // hidden on Macs without an energy mode setting
        card.isHidden = self.modeReadAt != nil && self.modeInfo == nil
        self.modeCard = card
        return card
    }

    private func initSignificant() -> NSView {
        let theme = ISTheme.current
        let title = isL("Using Significant Energy", fr: "Haute consommation d’énergie").uppercased()
        // the French title is wider than the card: it goes on two lines, as in iStat Menus
        let lines = self.wrap(title, font: ISFont.label(13), width: self.contentWidth - 16)
        let card = ISCard(title: lines.first ?? title)
        lines.dropFirst().forEach { card.add(self.textRow($0, color: theme.title)) }

        let none = self.textRow(localizedString("None"), color: theme.value)
        card.add(none)
        self.significantNone = none

        let list = ISProcessList(n: 5)
        list.isHidden = true
        card.add(list)
        self.significantApps = list

        return card
    }

    private func initProcesses() -> NSView {
        let card = ISCard(title: isL("Processes", fr: "Processus"))
        let list = ISProcessList(n: self.numberOfProcesses)
        card.add(list)
        self.processes = list
        return card
    }

    // as in iStat Menus, the figures of the adapter, the battery and its health are not in the menu:
    // they open next to it while the pointer is on the gauges or on the history
    private func attachDetails(_ card: ISCard) {
        card.detailID = "details"
        card.detail = { [weak self] in
            self?.detailsPanel() ?? NSView()
        }
    }

    private func detailsPanel() -> NSView {
        let stack = ISDetailStack(width: self.frame.width, ranges: false)
        stack.add(self.initAdapter())
        stack.add(self.initBattery())
        stack.add(self.initHealth())
        if let value = self.usageCache.value {
            self.renderUsage(value)
        }
        self.renderCondition()
        return stack
    }

    private func initAdapter() -> NSView {
        let card = ISCard(title: localizedString("Power adapter"))

        let power = ISRow(localizedString("Power"))
        let current = ISRow(isL("Amperage", fr: "Ampérage"))
        let voltage = ISRow(localizedString("Voltage"))
        let charging = ISRow(localizedString("Is charging"))
        [power, current, voltage, charging].forEach { card.add($0) }

        self.adapterPowerRow = power
        self.adapterCurrentRow = current
        self.adapterVoltageRow = voltage
        self.chargingRow = charging

        // only shown while the Mac is plugged in
        card.isHidden = self.usageCache.value?.isBatteryPowered ?? true
        self.adapterCard = card
        return card
    }

    private func initBattery() -> NSView {
        let card = ISCard(title: localizedString("Battery"))

        let power = ISRow(localizedString("Power"))
        let current = ISRow(isL("Amperage", fr: "Ampérage"))
        let voltage = ISRow(localizedString("Voltage"))
        let heat = ISRow(localizedString("Temperature"))
        let source = ISRow(localizedString("Source"))
        let time = ISRow(localizedString("Time to discharge"))
        [power, current, voltage, heat, source, time].forEach { card.add($0) }

        self.powerRow = power
        self.currentRow = current
        self.voltageRow = voltage
        self.temperatureRow = heat
        self.sourceRow = source
        self.timeRow = time

        return card
    }

    private func initHealth() -> NSView {
        let card = ISCard(title: localizedString("Health"))

        let cycles = ISRow(isL("Charge cycles", fr: "Cycles de charge"))
        let condition = ISRow(isL("Condition", fr: "Conditions"))
        let design = ISRow(isL("Design capacity", fr: "Capacité théorique"))
        // iStat calls it the current capacity: what the battery holds today when full
        let full = ISRow(isL("Current capacity", fr: "Capacité actuelle"))
        full.toolTip = localizedString("Max capacity")
        [cycles, condition, design, full].forEach { card.add($0) }
        condition.setPlain("—")

        self.cyclesRow = cycles
        self.conditionRow = condition
        self.designCapacityRow = design
        self.maxCapacityRow = full

        return card
    }

    // a line of plain text, as high as a row (second title line, "None")
    private func textRow(_ string: String, color: NSColor) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true

        let field = ISText(string, font: ISFont.label(13), color: color)
        view.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            field.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        return view
    }

    private func wrap(_ string: String, font: NSFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in string.split(separator: " ") {
            let candidate = line.isEmpty ? String(word) : "\(line) \(word)"
            if !line.isEmpty && candidate.widthOfString(usingFont: font) > width {
                lines.append(line)
                line = String(word)
            } else {
                line = candidate
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    // MARK: - Usage

    public func usageCallback(_ value: Battery_Usage) {
        let date = Date()
        DispatchQueue.main.async {
            self.record(value, at: date)
        }
        self.apply(value, to: self.usageCache, render: self.renderUsage)
    }

    // the reader fires every few seconds: keep one point a minute, plus one when the charger is plugged or unplugged
    private func record(_ value: Battery_Usage, at date: Date) {
        let onAC = !value.isBatteryPowered
        if let last = self.lastSampleAt, abs(date.timeIntervalSince(last)) < 60, self.lastSampleOnAC == onAC { return }
        self.lastSampleAt = date
        self.lastSampleOnAC = onAC
        self.levelHistory.append(BatterySample(level: min(max(abs(value.level), 0), 1), onAC: onAC))
    }

    // one bar per point while they fit, then the whole history is squeezed into the width of the chart
    private func historyBars() -> [BatterySample] {
        let samples = self.levelHistory.values
        let capacity = max(1, Int(self.contentWidth / (self.barWidth + self.barGap)))
        guard samples.count > capacity else { return samples }

        return (0..<capacity).map { i in
            let from = i * samples.count / capacity
            let to = max(from + 1, (i + 1) * samples.count / capacity)
            let slice = samples[from..<to]
            let level = slice.reduce(0) { $0 + $1.level } / Double(slice.count)
            let onAC = slice.filter({ $0.onAC }).count * 2 >= slice.count
            return BatterySample(level: level, onAC: onAC)
        }
    }

    // h:mm left on battery or until the battery is full, nil when macOS has no estimate
    private func shortTime(_ value: Battery_Usage) -> String? {
        if value.isBatteryPowered {
            guard value.timeToEmpty > 0 else { return nil }
            return Double(value.timeToEmpty * 60).printSecondsToHoursMinutesSeconds(short: true)
        }
        guard !value.isCharged, !value.optimizedChargingEngaged, value.timeToCharge > 0 else { return nil }
        return Double(value.timeToCharge * 60).printSecondsToHoursMinutesSeconds(short: true)
    }

    private func capacity(_ value: Int, row: ISRow?) {
        // the reader falls back to 1 when the battery does not report a capacity
        if value > 1 {
            row?.set(NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal), unit: "mAh")
        } else {
            row?.setPlain(localizedString("Unavailable"))
        }
    }

    private func renderUsage(_ value: Battery_Usage) {
        let theme = ISTheme.current
        let onAC = !value.isBatteryPowered
        let level = min(max(abs(value.level), 0), 1)

        // rings
        let remaining = self.shortTime(value)
        self.levelRing?.set(value: level, color: theme.blue)
        self.levelRing?.setText(
            "\(Int((level * 100).rounded()))",
            unit: "%",
            caption: remaining == nil ? localizedString("Battery") : nil,
            symbol: onAC ? self.bolt : nil,
            footer: remaining
        )
        self.levelRing?.toolTip = "\(value.currentCapacity) mAh"
        self.healthRing?.set(value: Double(value.health) / 100, color: theme.pink)
        self.healthRing?.setText("\(value.health)", unit: "%", caption: localizedString("Health"))

        // history
        let bars = self.historyBars()
        self.chart?.set(bars.map { $0.onAC ? [$0.level, 0] : [0, $0.level] })
        self.strip?.set(bars.map { $0.onAC })

        // power adapter
        if onAC {
            var power = value.adapterPower > 0 ? isNumber(value.adapterPower, digits: 1) : ""
            if value.ACwatts > 0 {
                power = power.isEmpty ? "\(value.ACwatts)" : "\(power) / \(value.ACwatts)"
            }
            self.adapterPowerRow?.set(power.isEmpty ? "0" : power, unit: "W")
            self.adapterPowerRow?.toolTip = value.adapterPower > 0 && value.ACwatts > 0
                ? isL("Power drawn / adapter rating", fr: "Puissance fournie / puissance de l’adaptateur")
                : nil

            let amperage = value.adapterVoltage > 0 ? value.adapterPower / value.adapterVoltage : 0
            self.adapterCurrentRow?.set(isNumber(amperage, digits: 2), unit: "A")
            self.adapterCurrentRow?.toolTip = "\(localizedString("Charging")): \(value.chargingCurrent) mA"

            let whole = value.adapterVoltage == value.adapterVoltage.rounded()
            self.adapterVoltageRow?.set(isNumber(value.adapterVoltage, digits: whole ? 0 : 2), unit: "V")
            self.adapterVoltageRow?.toolTip = "\(localizedString("Charging")): \(isNumber(Double(value.chargingVoltage) / 1000, digits: 2)) V"

            self.chargingRow?.setPlain(localizedString(value.isCharging ? "Yes" : "No"))
        }
        if let card = self.adapterCard, card.isHidden == onAC {
            card.isHidden = !onAC
            self.resizeToFitContent()
        }

        // battery
        self.powerRow?.set(isNumber(abs(value.batteryPower), digits: 1), unit: "W")
        self.currentRow?.set(isNumber(Double(value.current) / 1000, digits: 2), unit: "A")
        self.voltageRow?.set(isNumber(value.voltage, digits: 2), unit: "V")
        if let degrees = value.temperature {
            self.temperatureRow?.set(temperature(degrees))
        } else {
            self.temperatureRow?.setPlain(localizedString("Unavailable"))
        }
        self.sourceRow?.setPlain(localizedString(value.powerSource))

        let minutes = onAC ? value.timeToCharge : value.timeToEmpty
        var time = localizedString("Unknown")
        if minutes == -1 {
            time = localizedString("Calculating")
        } else if minutes > 0 {
            time = Double(minutes * 60).printSecondsToHoursMinutesSeconds(short: self.timeFormat == "short")
        }
        if onAC {
            if value.isCharged {
                // "Fully charged" does not fit next to the label
                time = isL("Charged", fr: "Chargée")
            } else if value.optimizedChargingEngaged {
                time = localizedString("On hold")
            }
        }
        self.timeRow?.labelField.stringValue = localizedString(onAC ? "Time to charge" : "Time to discharge")
        self.timeRow?.setPlain(time)

        // health
        self.cyclesRow?.setPlain("\(value.cycles)")
        self.capacity(value.designedCapacity, row: self.designCapacityRow)
        self.capacity(value.maxCapacity, row: self.maxCapacityRow)
        self.renderCondition()

        // the energy mode is set per power source: read it again when the source changes, and from time to time
        if let info = self.modeInfo, info.onBattery != value.isBatteryPowered {
            self.refreshMode(force: true)
        } else if let at = self.modeReadAt, Date().timeIntervalSince(at) > 30 {
            self.refreshMode()
        }
    }

    // MARK: - Battery condition

    private func conditionName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "good", "normal":
            return localizedString("Normal")
        case "fair":
            return isL("Fair", fr: "Correct")
        case "poor":
            return isL("Poor", fr: "Mauvais")
        case "check battery", "service battery", "service recommended", "replace soon", "replace now":
            return isL("Service Recommended", fr: "Réparation recommandée")
        default:
            return localizedString(raw)
        }
    }

    private func renderCondition() {
        guard let raw = self.usageCache.value?.state ?? self.condition else { return }
        self.conditionRow?.setPlain(self.conditionName(raw))
    }

    // system_profiler is slow (0.2 s): background queue, at most every 30 minutes
    private func refreshCondition() {
        guard self.usageCache.value?.state == nil, !self.conditionReading else { return }
        if let at = self.conditionReadAt, Date().timeIntervalSince(at) < 1800 { return }

        self.conditionReading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = PowerTools.batteryCondition()
            DispatchQueue.main.async {
                guard let self else { return }
                self.conditionReading = false
                self.conditionReadAt = Date()
                if let value {
                    self.condition = value
                }
                self.renderCondition()
            }
        }
    }

    // MARK: - Energy mode

    // the full name when it fits next to the title, a short one otherwise
    private func modeLabel(_ mode: Int) -> String {
        let name = PowerTools.modeName(mode)
        let needed = self.modeTitle.uppercased().widthOfString(usingFont: ISFont.label(13)) + name.widthOfString(usingFont: ISFont.value(13))
        return needed + 14 <= self.contentWidth ? name : PowerTools.shortModeName(mode)
    }

    private func sourceName(onBattery: Bool) -> String {
        onBattery ? localizedString("On battery") : isL("On power adapter", fr: "Sur adaptateur secteur")
    }

    private func renderMode() {
        guard let card = self.modeCard else { return }

        let hidden = self.modeReadAt != nil && self.modeInfo == nil
        if card.isHidden != hidden {
            card.isHidden = hidden
            self.resizeToFitContent()
        }

        guard let info = self.modeInfo else {
            card.valueField?.stringValue = "—"
            card.toolTip = nil
            return
        }
        card.valueField?.stringValue = self.modeLabel(info.current)
        card.toolTip = "\(PowerTools.modeName(info.current)) (\(self.sourceName(onBattery: info.onBattery)))"
    }

    private func refreshMode(force: Bool = false) {
        if self.modeReading {
            if force { self.modeReadAgain = true }
            return
        }

        self.modeReading = true
        let onBattery = self.usageCache.value?.isBatteryPowered
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = PowerTools.readMode(onBattery: onBattery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.modeReading = false
                self.modeReadAt = Date()
                self.modeInfo = info
                self.renderMode()
                if self.modeReadAgain {
                    self.modeReadAgain = false
                    self.refreshMode()
                }
            }
        }
    }

    private func showModeMenu() {
        guard let card = self.modeCard, !self.modeChanging else { return }
        guard let info = self.modeInfo, info.modes.count > 1 else {
            self.refreshMode()
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        // the mode is changed for the power source in use
        let onBattery = self.usageCache.value?.isBatteryPowered ?? info.onBattery
        let header = NSMenuItem(title: self.sourceName(onBattery: onBattery), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for mode in info.modes {
            let item = NSMenuItem(title: PowerTools.modeName(mode), action: #selector(self.selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode
            item.state = onBattery == info.onBattery && mode == info.current ? .on : .off
            menu.addItem(item)
        }

        menu.minimumWidth = card.bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: card)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let info = self.modeInfo, !self.modeChanging, info.modes.contains(sender.tag) else { return }
        let onBattery = self.usageCache.value?.isBatteryPowered ?? info.onBattery
        if onBattery == info.onBattery && sender.tag == info.current { return }

        let mode = sender.tag
        let key = info.key
        self.modeChanging = true
        // pmset needs root: this may show the administrator password dialog, so never on the main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = PowerTools.writeMode(mode, key: key, onBattery: onBattery)
            DispatchQueue.main.async {
                guard let self else { return }
                self.modeChanging = false
                self.refreshMode(force: true)
            }
        }
    }

    // MARK: - Processes

    public func processCallback(_ list: [TopProcess]) {
        self.apply(list, to: self.processesCache, render: self.renderProcesses)
    }

    private func renderProcesses(_ list: [TopProcess]) {
        if let processes = self.processes {
            let n = min(list.count, processes.count)
            for i in 0..<n {
                // the power column of top: an energy impact figure, it has no unit
                processes.set(i, list[i], [isNumber(list[i].usage, digits: 1)])
            }
            processes.clear(from: n)
        }
        self.renderSignificant(list)
    }

    private func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // the app a process is shown under: itself or the closest parent that is a regular app (a shell command
    // counts for its terminal, a browser helper for its browser), else the outermost menu bar or background app
    private func owningApp(of pid: Int) -> NSRunningApplication? {
        if let cached = self.ownerCache[pid] {
            return cached > 0 ? NSRunningApplication(processIdentifier: cached) : nil
        }

        var owner: NSRunningApplication? = nil
        var current = pid_t(pid)
        for _ in 0..<12 {
            if let app = NSRunningApplication(processIdentifier: current) {
                if app.activationPolicy == .regular {
                    owner = app
                    break
                }
                if app.bundleURL?.pathExtension == "app" {
                    owner = app
                }
            }
            guard let parent = self.parentPID(current), parent > 1, parent != current else { break }
            current = parent
        }

        self.ownerCache[pid] = owner?.processIdentifier ?? 0
        return owner
    }

    // names only, as in iStat Menus: the apps whose processes add up to a significant energy impact
    private func renderSignificant(_ list: [TopProcess]) {
        guard let rows = self.significantApps, let none = self.significantNone else { return }

        var apps: [pid_t: NSRunningApplication] = [:]
        var usage: [pid_t: Double] = [:]
        for process in list where process.usage > 0 {
            guard let app = self.owningApp(of: process.pid) else { continue }
            apps[app.processIdentifier] = app
            usage[app.processIdentifier, default: 0] += process.usage
        }
        let significant = usage.filter({ $0.value >= self.significantPower }).sorted(by: { $0.value > $1.value }).prefix(rows.count)

        for (i, item) in significant.enumerated() {
            let app = apps[item.key]
            rows.set(i, icon: app?.icon, name: app?.localizedName ?? "", values: [])
        }

        var resized = false
        for (i, row) in rows.arrangedSubviews.enumerated() where row.isHidden != (i >= significant.count) {
            row.isHidden = i >= significant.count
            resized = true
        }
        if rows.isHidden != significant.isEmpty {
            rows.isHidden = significant.isEmpty
            resized = true
        }
        if none.isHidden == significant.isEmpty {
            none.isHidden = !significant.isEmpty
            resized = true
        }
        if resized {
            self.resizeToFitContent()
        }
    }

    public func numberOfProcessesUpdated() {
        DispatchQueue.main.async {
            guard self.contentLoaded, self.processes?.count != self.numberOfProcesses else { return }
            self.releaseContent()
            self.processesCache.initialized = false
            self.prepareForDisplay()
        }
    }

    // MARK: - Settings

    public override func settings() -> NSView? {
        let view = SettingsContainerView()

        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))

        return view
    }
}

// thin strip under the level history: one blue segment for each period spent on the power adapter
private final class BatterySourceStrip: NSView {
    var barWidth: CGFloat = 2
    var gap: CGFloat = 1

    private var states: [Bool] = []
    private let thickness: CGFloat = 8
    private let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)

    init(height: CGFloat) {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(_ states: [Bool]) {
        self.states = states
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let step = self.barWidth + self.gap
        let capacity = Int(self.bounds.width / step)
        guard capacity > 0, !self.states.isEmpty else { return }

        let theme = ISTheme.current
        let visible = Array(self.states.suffix(capacity))
        // same geometry as ISBarChart: the newest value is the last bar on the right
        let origin = self.bounds.width - self.barWidth - (CGFloat(visible.count - 1) * step)
        let y = ((self.bounds.height - self.thickness) / 2).rounded()

        var first: Int? = nil
        var bolts: [CGFloat] = []
        theme.blue.setFill()
        for i in 0...visible.count {
            if i < visible.count && visible[i] {
                if first == nil { first = i }
                continue
            }
            guard let start = first else { continue }
            first = nil

            let x = origin + (CGFloat(start) * step)
            let width = (CGFloat(i - start) * step) - self.gap
            let radius = min(2.5, width / 2)
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: self.thickness), xRadius: radius, yRadius: radius).fill()
            // a bolt on the long periods only
            if width >= 24 { bolts.append(x + (width / 2)) }
        }

        bolts.forEach { self.drawBolt(at: $0, outline: theme.background, color: theme.value) }
    }

    // white bolt with a thin outline in the background colour
    private func drawBolt(at x: CGFloat, outline: NSColor, color: NSColor) {
        guard let bolt = self.bolt, bolt.size.height > 0 else { return }

        let height = self.bounds.height - 2
        let width = height * (bolt.size.width / bolt.size.height)
        let rect = NSRect(x: (x - (width / 2)).rounded(), y: 1, width: width, height: height)

        let shadow = self.tinted(bolt, outline)
        let offsets: [(CGFloat, CGFloat)] = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)]
        for (dx, dy) in offsets {
            shadow.draw(in: rect.offsetBy(dx: dx, dy: dy))
        }
        self.tinted(bolt, color).draw(in: rect)
    }

    private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}

// MARK: - Command line tools (they block: never call them on the main thread)

private struct PowerModeInfo {
    let key: String      // "powermode", or "lowpowermode" on Macs that only know on and off
    let current: Int     // 0 automatic, 1 low power, 2 high power
    let modes: [Int]     // what can be chosen for the power source in use
    let onBattery: Bool
}

private enum PowerTools {
    static func modeName(_ mode: Int) -> String {
        switch mode {
        case 1: return isL("Low Power", fr: "Économie d’énergie")
        case 2: return isL("High Power", fr: "Haute performance")
        default: return localizedString("Automatic")
        }
    }

    static func shortModeName(_ mode: Int) -> String {
        switch mode {
        case 1: return isL("Low Power", fr: "Économie")
        case 2: return isL("High Power", fr: "Performance")
        default: return localizedString("Automatic")
        }
    }

    // `pmset -g` prints the settings of the power source in use
    static func readMode(onBattery known: Bool?) -> PowerModeInfo? {
        guard let settings = self.run("/usr/bin/pmset", ["-g"]), settings.status == 0 else { return nil }

        var values: [String: Int] = [:]
        settings.output.enumerateLines { line, _ in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let value = Int(parts[1]) else { return }
            values[String(parts[0])] = value
        }

        let onBattery = known ?? (self.run("/usr/bin/pmset", ["-g", "ps"])?.output.contains("'Battery Power'") ?? false)

        if let current = values["powermode"] {
            // high power only where the Mac lists it for this power source
            let capabilities = self.run("/usr/bin/pmset", ["-g", "cap"])?.output ?? ""
            let highPower = capabilities.contains("highpowermode") || current == 2
            return PowerModeInfo(key: "powermode", current: current, modes: highPower ? [0, 1, 2] : [0, 1], onBattery: onBattery)
        }
        if let current = values["lowpowermode"] {
            return PowerModeInfo(key: "lowpowermode", current: current == 0 ? 0 : 1, modes: [0, 1], onBattery: onBattery)
        }
        return nil
    }

    // pmset needs root to write: sudo without a password first (works with a sudoers rule),
    // otherwise macOS asks for an administrator password
    static func writeMode(_ mode: Int, key: String, onBattery: Bool) -> Bool {
        // every word of the command comes from these fixed lists, nothing from outside
        guard ["powermode", "lowpowermode"].contains(key), (0...(key == "powermode" ? 2 : 1)).contains(mode) else { return false }
        let arguments = [onBattery ? "-b" : "-c", key, "\(mode)"]

        if let result = self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + arguments), result.status == 0 {
            return true
        }

        let prompt = isL("Stats wants to change the energy mode.", fr: "Stats veut changer le mode d’énergie.")
        let script = "do shell script \"/usr/bin/pmset \(arguments.joined(separator: " "))\" with prompt \"\(prompt)\" with administrator privileges"
        return self.run("/usr/bin/osascript", ["-e", script])?.status == 0
    }

    // "Good", "Fair", "Poor"… as shown in System Information
    static func batteryCondition() -> String? {
        guard let result = self.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]), result.status == 0,
              let data = result.output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPPowerDataType"] as? [[String: Any]] else { return nil }

        for section in sections {
            if let health = section["sppower_battery_health_info"] as? [String: Any],
               let condition = health["sppower_battery_health"] as? String, !condition.isEmpty {
                return condition
            }
        }
        return nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

internal class BatteryView: NSView {
    private var percentage: Double = 0
    private var connected: Bool = false
    private var charging: Bool = false
    
    public override init(frame: NSRect = NSRect.zero) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let scale: CGFloat = Swift.min(self.frame.width/130, self.frame.height/60, 1)
        let w: CGFloat = 130 * scale
        let h: CGFloat = 60 * scale
        let x: CGFloat = (self.frame.width - w)/2
        let y: CGFloat = (self.frame.size.height - h) / 2
        let lineWidth: CGFloat = Swift.max(1, 2*scale)
        let pointWidth: CGFloat = 7 * scale
        let batteryFrame = NSBezierPath(roundedRect: NSRect(
            x: x + lineWidth/2,
            y: y + lineWidth/2,
            width: w - pointWidth - lineWidth,
            height: h - lineWidth
        ), xRadius: 16*scale, yRadius: 16*scale)
        
        NSColor.secondaryLabelColor.set()
        
        let bPX: CGFloat = batteryFrame.bounds.origin.x + batteryFrame.bounds.width
        let bPY: CGFloat = batteryFrame.bounds.origin.y + (batteryFrame.bounds.height/2) - (12*scale)
        let batteryPoint = NSBezierPath(roundedRect: NSRect(x: bPX, y: bPY, width: pointWidth, height: 24*scale), xRadius: 6*scale, yRadius: 6*scale)
        batteryPoint.fill()
        
        let batteryPointSeparator = NSBezierPath()
        batteryPointSeparator.move(to: CGPoint(x: bPX, y: batteryFrame.bounds.origin.y))
        batteryPointSeparator.line(to: CGPoint(x: bPX, y: batteryFrame.bounds.origin.y + batteryFrame.bounds.height))
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        NSColor.textColor.set()
        batteryPointSeparator.lineWidth = 6*scale
        batteryPointSeparator.stroke()
        ctx.restoreGState()
        
        batteryFrame.lineWidth = lineWidth
        batteryFrame.stroke()
        
        if self.percentage == 0 {
            return
        }
        
        let innerPadding: CGFloat = 5 * scale
        let innerHeight: CGFloat = h - (innerPadding*2)
        let minWidth: CGFloat = 8 * scale
        let track: CGFloat = w - (16*scale)
        var fillWidth: CGFloat = 0
        if self.percentage > 0 {
            fillWidth = minWidth + (track - minWidth) * CGFloat(self.percentage)
        }
        let fillRadius: CGFloat = Swift.min(12*scale, fillWidth/2, innerHeight/2)
        let inner = NSBezierPath(roundedRect: NSRect(
            x: x + innerPadding,
            y: y + innerPadding,
            width: fillWidth,
            height: innerHeight
        ), xRadius: fillRadius, yRadius: fillRadius)
        self.percentage.batteryColorV2().set()
        inner.lineWidth = 0
        inner.stroke()
        inner.close()
        inner.fill()
        
        if self.connected {
            let center = CGPoint(
                x: batteryFrame.bounds.origin.x + (batteryFrame.bounds.width/2),
                y: batteryFrame.bounds.origin.y + (batteryFrame.bounds.height/2)
            )
            let symbolName: String = self.charging ? "bolt.fill" : "powerplug.fill"
            let symbolSize: CGFloat = 24 * scale
            
            if self.percentage > 0.55 {
                guard let body = self.coloredSymbol(symbolName, color: .white, size: symbolSize) else { return }
                let size: NSSize = body.size
                body.draw(in: NSRect(x: center.x - (size.width/2), y: center.y - (size.height/2), width: size.width, height: size.height))
                return
            }
            
            guard let outline = self.coloredSymbol(symbolName, color: .black, size: symbolSize),
                  let body = self.coloredSymbol(symbolName, color: self.percentage.batteryColorV2(), size: symbolSize) else { return }
            
            let size: NSSize = body.size
            let border: CGFloat = Swift.max(1, 2*scale)
            let origin = CGPoint(x: center.x - (size.width/2), y: center.y - (size.height/2))
            
            let steps: Int = 24
            for i in 0..<steps {
                let angle: CGFloat = (CGFloat(i) / CGFloat(steps)) * 2 * .pi
                outline.draw(in: NSRect(
                    x: origin.x + (cos(angle) * border),
                    y: origin.y + (sin(angle) * border),
                    width: size.width,
                    height: size.height
                ), from: .zero, operation: .destinationOut, fraction: 1.0)
            }
            body.draw(in: NSRect(origin: origin, size: size))
        }
    }
    
    public func setValue(_ value: Double, connected: Bool, charging: Bool) {
        if self.percentage == value && self.connected == connected && self.charging == charging { return }
        
        self.percentage = value
        self.connected = connected
        self.charging = charging
        
        DispatchQueue.main.async(execute: {
            self.display()
        })
    }
    
    private func coloredSymbol(_ name: String, color: NSColor, size: CGFloat) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .bold)
        config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }
}
