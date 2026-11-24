//
//  popup.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 22/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

// value of the fan rows in the popup: revolutions per minute unless the user chose the percentage
// (the ring at the top already gives the percentage)
private func popupFanValue() -> FanValue {
    FanValue(rawValue: Store.shared.string(key: "Sensors_popup_fanValue", defaultValue: FanValue.rpm.rawValue)) ?? .rpm
}

private func groupedNumber(_ value: Double) -> String {
    NumberFormatter.localizedString(from: NSNumber(value: value.isFinite ? Int(value) : 0), number: .decimal)
}

// share of the range of the fan: 0% at its lowest speed, 100% at its highest (the ring and the rows use the same)
private func fanUsage(_ fan: Fan) -> Double {
    guard fan.maxSpeed > 1, fan.value.isFinite else { return 0 }
    if fan.maxSpeed > fan.minSpeed {
        return max(0, min(1, (fan.value - fan.minSpeed) / (fan.maxSpeed - fan.minSpeed)))
    }
    return max(0, min(1, fan.value / fan.maxSpeed))
}

// like the sensors of iStat Menus the unit has the size of the digits: "2 222 tpm", "44,5 °C", "34%"
private func plainValue(_ number: String, _ unit: String) -> String {
    unit.isEmpty || unit == "%" ? "\(number)\(unit)" : "\(number) \(unit)"
}

// ("2 222", "tpm") or ("34", "%")
private func fanDisplay(_ fan: Fan) -> (String, String) {
    if popupFanValue() == .percentage && fan.maxSpeed > 1 {
        return ("\(Int((fanUsage(fan) * 100).rounded()))", "%")
    }
    return (groupedNumber(fan.value), isL("RPM", fr: "tpm"))
}

internal class Popup: PopupWrapper {
    private let ringDiameter: CGFloat = 68
    private let historyCapacity: Int = 80
    
    private var rows: [String: SensorRowView] = [:]
    private var fanViews: [String: FanView] = [:]
    // last readings of every sensor, drawn when a row is opened (the views are destroyed each time the popup closes)
    private var histories: [String: ISHistory<Double>] = [:]
    
    private var cpuRing: ISRing? = nil
    private var gpuRing: ISRing? = nil
    private var fansRing: ISRing? = nil
    private var cpuKey: String? = nil
    private var gpuKey: String? = nil
    // [CPU temperature, GPU temperature, fans 0...1], kept up to 30 days for the side panel of the rings
    private let overviewHistory = ISHistoryStore.shared.series("sensors.overview", dimensions: 3)
    
    private var unknownSensorsState: Bool { Store.shared.bool(key: "Sensors_unknown", defaultValue: false) }
    
    private var sensors: [Sensor_p] = []
    private let settingsView: NSStackView = NSStackView()
    private var settingsLoaded: Bool = false
    private let sensorsCache = PopupCache<[Sensor_p]>()
    
    private var fanControlState: Bool {
        get { Store.shared.bool(key: "Sensors_fanControl", defaultValue: true) }
        set { Store.shared.set(key: "Sensors_fanControl", value: newValue) }
    }
    
    public init() {
        super.init(ModuleType.sensors, frame: NSRect(x: 0, y: 0, width: 256, height: 0))
        
        self.orientation = .vertical
        self.spacing = ISMetrics.spacing
        
        self.settingsView.orientation = .vertical
        self.settingsView.spacing = Constants.Settings.margin
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        self.settingsView.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Fan value"), component: self.selectView(
                action: #selector(self.toggleFanValue),
                items: FanValues,
                selected: popupFanValue().rawValue
            ))
        ]))
        #if arch(arm64)
        NotificationCenter.default.addObserver(self, selector: #selector(self.checkFanModesAndResetFtst), name: .checkFanModes, object: nil)
        #endif
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    #if arch(arm64)
    @objc private func checkFanModesAndResetFtst() {
        let fanViews = Array(self.fanViews.values)
        guard !fanViews.isEmpty else { return }
        guard fanViews.allSatisfy({ $0.fan.mode.isAutomatic }) else { return }
        SMCHelper.shared.resetFanControl()
    }
    #endif
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadContent() {
        self.setup(reload: true)
    }
    
    public override func unloadContent() {
        self.fanViews.values.forEach {
            $0.unloadContent()
            $0.removeFromSuperview()
        }
        self.rows.removeAll()
        self.cpuRing = nil
        self.gpuRing = nil
        self.fansRing = nil
    }
    
    public override func appear() {
        self.replay(self.sensorsCache, render: self.renderSensors)
    }
    
    // called by the module each time the list of sensors changes, and with reload when a visibility setting changes
    internal func setup(_ values: [Sensor_p]? = nil, reload: Bool = false) {
        guard let values = reload ? self.sensors : values else { return }
        let fans = values.filter({ $0.type == .fan && $0.popupState })
        if !reload {
            self.sensors = values
            let keys = Set(values.map { $0.key })
            self.histories = self.histories.filter { keys.contains($0.key) }
            if self.settingsLoaded { self.loadSettings() }
        }
        
        // the fan views live as long as the fan is shown: they hold the fan mode, the sleep and wake handling
        let keys = Set(fans.filter({ !$0.isComputed }).map { $0.key })
        self.fanViews.filter({ !keys.contains($0.key) }).values.forEach {
            $0.unloadContent()
            $0.removeFromSuperview()
        }
        self.fanViews = self.fanViews.filter { keys.contains($0.key) }
        fans.compactMap { $0 as? Fan }.filter { !$0.isComputed }.forEach { fan in
            if let view = self.fanViews[fan.key] {
                if !reload { view.fan = fan }
            } else {
                self.fanViews[fan.key] = FanView(fan, width: self.frame.width - (ISMetrics.padH * 2)) {}
            }
        }
        
        guard self.contentLoaded else { return }
        self.build()
        self.replay(self.sensorsCache, render: self.renderSensors)
        self.resizeToFitContent()
    }
    
    // MARK: - Views
    
    private func build() {
        self.rows.removeAll()
        self.cpuRing = nil
        self.gpuRing = nil
        self.fansRing = nil
        self.arrangedSubviews.forEach { self.removeArrangedSubview($0) }
        self.subviews.forEach { $0.removeFromSuperview() }
        
        var sensors = self.sensors
        if !self.unknownSensorsState {
            sensors = sensors.filter({ $0.group != .unknown })
        }
        
        if let rings = self.initRings(self.sensors) {
            self.addSection(rings)
        }
        
        // same order as iStat Menus: temperature, fans, current, power, voltage (energy only exists in Stats)
        let order: [SensorType] = [.temperature, .fan, .current, .power, .voltage, .energy]
        order.forEach { type in
            if type == .fan {
                let fans = self.sensors.filter({ $0.type == .fan && $0.popupState })
                if !fans.isEmpty {
                    self.addSection(self.initFans(fans))
                }
                return
            }
            let all = sensors.filter { $0.type == type }
            let visible = all.filter { $0.popupState }
            if !visible.isEmpty {
                self.addSection(self.initCard(type, all: all, visible: visible))
            }
        }
        
        self.addSection(ISShortcutBar(module: .sensors, extra: [ISShortcut.app("com.apple.SystemProfiler")]))
    }
    
    private func initRings(_ sensors: [Sensor_p]) -> NSView? {
        let temperatures = sensors.filter { $0.type == .temperature }
        let keys = Set(temperatures.map { $0.key })
        
        let picked = self.pickKeys(sensors)
        self.cpuKey = picked.cpu
        self.gpuKey = picked.gpu
        let hasFans = sensors.contains(where: { $0 is Fan && !$0.isComputed })
        
        let count = (self.cpuKey == nil ? 0 : 1) + (self.gpuKey == nil ? 0 : 1) + (hasFans ? 1 : 0)
        guard count > 0 else { return nil }
        
        let card = ISCard()
        let row = ISRingRow(count: count, diameter: self.ringDiameter, lineWidth: 3)
        let width = self.frame.width - (ISMetrics.padH * 2)
        // one ring sits in the middle, two or three are spread over the width
        let inset: CGFloat = count == 1 ? max(0, (width - self.ringDiameter) / 2) : (count == 2 ? 34 : 6)
        row.edgeInsets = NSEdgeInsets(top: row.edgeInsets.top, left: inset, bottom: row.edgeInsets.bottom, right: inset)
        card.add(row)
        
        var rings = row.rings
        if self.cpuKey != nil, !rings.isEmpty {
            let ring = rings.removeFirst()
            ring.setText("—", caption: "CPU")
            ring.toolTip = self.cpuKey.map { localizedString($0) }
            self.cpuRing = ring
        }
        if self.gpuKey != nil, !rings.isEmpty {
            let ring = rings.removeFirst()
            ring.setText("—", caption: "GPU")
            ring.toolTip = self.gpuKey.map { localizedString($0) }
            self.gpuRing = ring
        }
        if hasFans, !rings.isEmpty {
            let ring = rings.removeFirst()
            ring.setText("—", caption: self.fansCaption)
            ring.toolTip = localizedString("Fans")
            self.fansRing = ring
        }
        
        card.detailID = "history"
        card.detail = { [weak self] in
            self?.historyDetail(fans: hasFans) ?? NSView()
        }
        
        return card
    }
    
    // the sensors behind the CPU and GPU rings
    private func pickKeys(_ sensors: [Sensor_p]) -> (cpu: String?, gpu: String?) {
        let temperatures = sensors.filter { $0.type == .temperature }
        let keys = Set(temperatures.map { $0.key })
        
        let cpu = ["Average CPU", "Hottest CPU", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H", "TCAD"].first(where: { keys.contains($0) })
            ?? temperatures.first(where: { $0.group == .CPU })?.key
            ?? ["Average SOC", "Hottest SOC"].first(where: { keys.contains($0) })
        let gpu = ["Average GPU", "Hottest GPU", "TGDD", "TG0D", "TCGC", "TG0P", "TG0H"].first(where: { keys.contains($0) })
            ?? temperatures.first(where: { $0.key.hasPrefix("GPU MTR Temp") })?.key
        return (cpu, gpu)
    }
    
    // side panel of the rings: the two temperatures and the fans over time
    private func historyDetail(fans: Bool) -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()
        let hasCPU = self.cpuKey != nil
        let hasGPU = self.gpuKey != nil
        
        if hasCPU || hasGPU {
            let heat = ISHistoryCard(
                title: localizedString("Temperature"),
                series: self.overviewHistory,
                style: .lines,
                colors: [theme.blue, theme.pink],
                dims: [0, 1],
                height: 64,
                scale: 110
            )
            let cpu = ISRow("CPU", color: theme.blue)
            let cpuPeak = ISRow(isL("CPU, peak", fr: "CPU, pic"))
            let gpu = ISRow("GPU", color: theme.pink)
            let gpuPeak = ISRow(isL("GPU, peak", fr: "GPU, pic"))
            [cpu, cpuPeak, gpu, gpuPeak].forEach { heat.add($0) }
            cpu.isHidden = !hasCPU
            cpuPeak.isHidden = !hasCPU
            gpu.isHidden = !hasGPU
            gpuPeak.isHidden = !hasGPU
            heat.summary = { _, points in
                cpu.set(points.isAverage(0).map({ temperature($0) }) ?? "—")
                cpuPeak.set(points.isMaximum(0).map({ temperature($0) }) ?? "—")
                gpu.set(points.isAverage(1).map({ temperature($0) }) ?? "—")
                gpuPeak.set(points.isMaximum(1).map({ temperature($0) }) ?? "—")
            }
            stack.add(heat)
        }
        
        if fans {
            let speed = ISHistoryCard(
                title: localizedString("Fans"),
                series: self.overviewHistory,
                style: .stacked,
                colors: [theme.yellow],
                dims: [2],
                height: 40,
                scale: 1
            )
            let average = ISRow(isL("Average", fr: "Moyenne"))
            let peak = ISRow(isL("Peak", fr: "Pic"))
            speed.add(average)
            speed.add(peak)
            speed.summary = { _, points in
                average.set(points.isAverage(2).map({ isPercent($0) }) ?? "—")
                peak.set(points.isMaximum(2).map({ isPercent(min($0, 1)) }) ?? "—")
            }
            stack.add(speed)
        }
        
        stack.refresh()
        return stack
    }
    
    // called at every reading, popup open or not
    private func recordOverview(_ values: [Sensor_p]) {
        if self.cpuKey == nil && self.gpuKey == nil {
            let picked = self.pickKeys(values)
            self.cpuKey = picked.cpu
            self.gpuKey = picked.gpu
        }
        let cpu = self.cpuKey.flatMap({ key in values.first(where: { $0.key == key })?.value }) ?? 0
        let gpu = self.gpuKey.flatMap({ key in values.first(where: { $0.key == key })?.value }) ?? 0
        let fans = values.compactMap({ $0 as? Fan }).filter({ !$0.isComputed })
        let usage = fans.isEmpty ? 0 : fans.map({ fanUsage($0) }).reduce(0, +) / Double(fans.count)
        guard self.cpuKey != nil || self.gpuKey != nil || !fans.isEmpty else { return }
        self.overviewHistory.record([cpu, gpu, usage])
    }
    
    private func initCard(_ type: SensorType, all: [Sensor_p], visible: [Sensor_p]) -> NSView {
        let card = ISCard(title: self.title(type))
        
        var groups: [SensorGroup] = []
        all.forEach { (s: Sensor_p) in
            if !groups.contains(s.group) {
                groups.append(s.group)
            }
        }
        
        groups.forEach { (group: SensorGroup) in
            visible.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                let key = s.key
                let row = SensorRowView(name: localizedString(s.name), key: key, expandable: s is Sensor)
                row.onToggle = { [weak self, weak row] in
                    guard let self, let row else { return }
                    if let sensor = (self.sensorsCache.value ?? self.sensors).first(where: { $0.key == key }) {
                        self.feed(row, sensor)
                    }
                    self.resizeToFitContent()
                }
                self.render(s, in: row)
                card.add(row)
                self.rows[key] = row
            }
        }
        
        return card
    }
    
    private func initFans(_ fans: [Sensor_p]) -> NSView {
        let card = ISCard(title: localizedString("Fans"))
        
        // shows or hides the speed control of the fans
        if fans.contains(where: { !$0.isComputed }), let header = card.header {
            let button = PopupButton(toolTip: localizedString("Control"), state: self.fanControlState) { [weak self] in
                self?.toggleFanControl()
            }
            header.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
        }
        
        fans.forEach { (f: Sensor_p) in
            guard let fan = f as? Fan else { return }
            if fan.isComputed {
                let row = SensorRowView(name: localizedString(fan.name), key: fan.key, expandable: false)
                self.render(fan, in: row)
                card.add(row)
                self.rows[fan.key] = row
            } else if let view = self.fanViews[fan.key] {
                view.removeFromSuperview()
                view.loadContent()
                view.sizeCallback = { [weak self] in
                    self?.resizeToFitContent()
                }
                card.add(view)
            }
        }
        
        return card
    }
    
    // MARK: - Formatting
    
    private var fansCaption: String { isL("FANS", fr: "VENT.") }
    
    private func title(_ type: SensorType) -> String {
        switch type {
        case .current: return isL("Current", fr: "Ampérage")
        default: return localizedString(type.rawValue)
        }
    }
    
    // same precision as before, with the decimal separator of the user and the unit apart: ("44,5", "°C")
    private func format(_ type: SensorType, _ value: Double) -> (String, String) {
        let whole = value >= 100 && value.isFinite
        switch type {
        case .temperature:
            let unit = UnitTemperature.current
            let local = Measurement(value: value, unit: UnitTemperature.celsius).converted(to: unit).value
            return (isNumber(local, digits: 1), unit.symbol)
        case .voltage:
            return (whole ? "\(Int(value))" : isNumber(value, digits: 3), "V")
        case .power:
            return (whole ? "\(Int(value))" : isNumber(value, digits: 2), "W")
        case .energy:
            return (whole ? "\(Int(value))" : isNumber(value, digits: 2), "Wh")
        case .current:
            return (whole ? "\(Int(value))" : isNumber(value, digits: 2), "A")
        case .fan:
            return (groupedNumber(value), isL("RPM", fr: "tpm"))
        }
    }
    
    // MARK: - Updates
    
    private func history(for key: String) -> ISHistory<Double> {
        if let history = self.histories[key] { return history }
        let history = ISHistory<Double>(capacity: self.historyCapacity)
        self.histories[key] = history
        return history
    }
    
    internal func usageCallback(_ values: [Sensor_p]) {
        DispatchQueue.main.async(execute: {
            values.forEach { (s: Sensor_p) in
                guard s is Sensor, s.value.isFinite else { return }
                self.history(for: s.key).append(s.value)
            }
            self.recordOverview(values)
            
            self.sensorsCache.value = values
            guard self.contentLoaded else { return }
            self.sensorsCache.apply(values, visible: self.window?.isVisible ?? false, render: self.renderSensors)
        })
    }
    
    private func renderSensors(_ values: [Sensor_p]) {
        values.forEach { (s: Sensor_p) in
            if let fan = s as? Fan, !fan.isComputed {
                self.fanViews[fan.key]?.update(fan)
                return
            }
            if let row = self.rows[s.key] {
                self.render(s, in: row)
            }
        }
        self.renderRings(values)
    }
    
    private func render(_ sensor: Sensor_p, in row: SensorRowView) {
        if let fan = sensor as? Fan {
            let (number, unit) = fanDisplay(fan)
            row.row.setPlain(plainValue(number, unit))
            return
        }
        let (number, unit) = self.format(sensor.type, sensor.value)
        row.row.setPlain(plainValue(number, unit))
        self.feed(row, sensor)
    }
    
    // history of an opened row
    private func feed(_ row: SensorRowView, _ sensor: Sensor_p) {
        guard row.isExpanded else { return }
        let values = self.histories[sensor.key]?.values ?? []
        let lowest = self.format(sensor.type, values.min() ?? sensor.value)
        let highest = self.format(sensor.type, values.max() ?? sensor.value)
        row.setHistory(values, range: "\(lowest.0) – \(highest.0)", unit: highest.1)
    }
    
    private func renderRings(_ values: [Sensor_p]) {
        if let ring = self.cpuRing, let key = self.cpuKey, let sensor = values.first(where: { $0.key == key }) {
            self.setTemperature(ring, sensor.value, caption: "CPU")
        }
        if let ring = self.gpuRing, let key = self.gpuKey, let sensor = values.first(where: { $0.key == key }) {
            self.setTemperature(ring, sensor.value, caption: "GPU")
        }
        if let ring = self.fansRing {
            let fans = values.compactMap({ $0 as? Fan }).filter({ !$0.isComputed })
            guard !fans.isEmpty else { return }
            let usage = fans.map({ fanUsage($0) }).reduce(0, +) / Double(fans.count)
            ring.set(value: usage)
            ring.setText("\(Int((usage * 100).rounded()))", unit: "%", caption: self.fansCaption)
        }
    }
    
    // the arc is the temperature out of 100 °C
    private func setTemperature(_ ring: ISRing, _ value: Double, caption: String) {
        guard value.isFinite else { return }
        let local = Measurement(value: value, unit: UnitTemperature.celsius).converted(to: UnitTemperature.current).value
        ring.set(value: value / 100)
        // the degree sign stays at the size of the digits (as a small unit it is hardly readable)
        ring.setText("\(Int(local.rounded()))°", caption: caption)
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        if !self.settingsLoaded {
            self.loadSettings()
            self.settingsLoaded = true
        }
        return self.settingsView
    }
    
    private func loadSettings() {
        self.settingsView.subviews.filter({ $0.identifier == NSUserInterfaceItemIdentifier("sensor") }).forEach { v in
            v.removeFromSuperview()
        }
        
        let sensors = self.sensors.filter({ self.unknownSensorsState || $0.group != .unknown })
        var types: [SensorType] = []
        sensors.forEach { (s: Sensor_p) in
            if !types.contains(s.type) {
                types.append(s.type)
            }
        }
        
        types.forEach { (typ: SensorType) in
            let filtered = sensors.filter{ $0.type == typ }
            var groups: [SensorGroup] = []
            filtered.forEach { (s: Sensor_p) in
                if !groups.contains(s.group) {
                    groups.append(s.group)
                }
            }
            
            let section = PreferencesSection(title: localizedString(typ.rawValue))
            section.identifier = NSUserInterfaceItemIdentifier("sensor")
            groups.forEach { (group: SensorGroup) in
                filtered.filter{ $0.group == group }.forEach { (s: Sensor_p) in
                    let btn = self.switchView(
                        action: #selector(self.toggleSensor),
                        state: s.popupState
                    )
                    btn.identifier = NSUserInterfaceItemIdentifier(rawValue: s.key)
                    section.add(PreferencesRow(localizedString(s.name), component: btn))
                }
            }
            self.settingsView.addArrangedSubview(section)
        }
    }
    
    @objc private func toggleFanValue(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String, let value = FanValue(rawValue: key) {
            Store.shared.set(key: "Sensors_popup_fanValue", value: value.rawValue)
            if self.contentLoaded {
                self.replay(self.sensorsCache, render: self.renderSensors)
            }
        }
    }
    
    // MARK: helpers
    
    @objc private func toggleSensor(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "sensor_\(id.rawValue)_popup", value: controlState(sender))
        self.setup(reload: true)
    }
    
    @objc private func toggleFanControl() {
        self.fanControlState = !self.fanControlState
        NotificationCenter.default.post(name: .toggleFanControl, object: nil, userInfo: ["state": self.fanControlState])
    }
}

// MARK: - Sensor row

// "name … value" row of a card; a click opens the history of the sensor under the row
private class SensorRowView: NSStackView {
    fileprivate let row: ISRow
    fileprivate var onToggle: (() -> Void)? = nil
    fileprivate var isExpanded: Bool { self.chart != nil }
    
    private let expandable: Bool
    private var chart: ISBarChart? = nil
    private var rangeRow: ISRow? = nil
    private var tracking: NSTrackingArea? = nil
    
    fileprivate init(name: String, key: String, expandable: Bool) {
        self.row = ISRow(name)
        self.expandable = expandable
        
        super.init(frame: .zero)
        
        self.orientation = .vertical
        self.alignment = .leading
        self.distribution = .fill
        self.spacing = 0
        self.translatesAutoresizingMaskIntoConstraints = false
        self.toolTip = key
        
        self.row.wantsLayer = true
        self.row.layer?.cornerRadius = 3
        self.addArrangedSubview(self.row)
        self.row.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // values are drawn between the lowest and the highest reading of the history, the row under the chart names them
    fileprivate func setHistory(_ values: [Double], range: String, unit: String) {
        guard let chart = self.chart else { return }
        let lowest = values.min() ?? 0
        let span = (values.max() ?? 0) - lowest
        chart.set(values.map { [span > 0 ? 0.12 + (0.88 * (($0 - lowest) / span)) : 0.5] })
        if values.isEmpty {
            self.rangeRow?.setPlain("—")
        } else {
            self.rangeRow?.setPlain(plainValue(range, unit))
        }
    }
    
    private func toggle() {
        if let chart = self.chart {
            [chart, self.rangeRow].forEach { view in
                guard let view else { return }
                self.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            self.chart = nil
            self.rangeRow = nil
            self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        } else {
            let chart = ISBarChart(colors: [ISTheme.current.blue], height: 40)
            let range = ISRow("Min / max", dim: true)
            self.addArrangedSubview(chart)
            self.addArrangedSubview(range)
            chart.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
            range.widthAnchor.constraint(equalTo: self.widthAnchor).isActive = true
            self.setCustomSpacing(3, after: self.row)
            self.setCustomSpacing(1, after: chart)
            self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
            self.chart = chart
            self.rangeRow = range
        }
        self.onToggle?()
    }
    
    // the whole row is the click target, not its labels
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return self.expandable && view != nil ? self : view
    }
    
    override func mouseDown(with event: NSEvent) {
        guard self.expandable else {
            super.mouseDown(with: event)
            return
        }
        self.toggle()
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = self.tracking {
            self.removeTrackingArea(tracking)
            self.tracking = nil
        }
        guard self.expandable else { return }
        let area = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.tracking = area
    }
    
    override func mouseEntered(with event: NSEvent) {
        self.row.layer?.backgroundColor = ISTheme.current.hover.withAlphaComponent(0.55).cgColor
    }
    
    override func mouseExited(with event: NSEvent) {
        self.row.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// row of the sensors list of the portal (Modules/Sensors/portal.swift)
internal class ValueSensorView: NSStackView {
    public var callback: (() -> Void)
    
    private var labelView: LabelField = {
        let view = LabelField(frame: NSRect.zero)
        view.cell?.truncatesLastVisibleLine = true
        return view
    }()
    private var valueView: ValueField = ValueField(frame: NSRect.zero)
    
    private let isToggleable: Bool
    
    public init(_ sensor: Sensor_p, width: CGFloat, toggleable: Bool = true, callback: @escaping (() -> Void)) {
        self.callback = callback
        self.isToggleable = toggleable
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        
        self.wantsLayer = true
        self.orientation = .horizontal
        self.distribution = .fillProportionally
        self.spacing = 0
        self.layer?.cornerRadius = 3
        
        self.labelView.stringValue = sensor.name
        self.labelView.toolTip = sensor.key
        self.valueView.stringValue = sensor.formattedValue
        
        self.addArrangedSubview(self.labelView)
        self.addArrangedSubview(self.valueView)
        
        if self.isToggleable {
            self.addTrackingArea(NSTrackingArea(
                rect: NSRect(x: 0, y: 0, width: self.frame.width, height: 22),
                options: [NSTrackingArea.Options.activeAlways, NSTrackingArea.Options.mouseEnteredAndExited, NSTrackingArea.Options.activeInActiveApp],
                owner: self,
                userInfo: nil
            ))
        }
        
        NSLayoutConstraint.activate([
            self.labelView.heightAnchor.constraint(equalToConstant: 16),
            self.heightAnchor.constraint(equalToConstant: self.bounds.height)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func update(_ value: String) {
        self.valueView.stringValue = value
    }
    
    override func mouseDown(with theEvent: NSEvent) {
        guard self.isToggleable else { return }
        self.callback()
    }
    
    public override func mouseEntered(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .init(gray: 0.01, alpha: 0.05)
    }
    
    public override func mouseExited(with: NSEvent) {
        guard self.isToggleable else { return }
        self.layer?.backgroundColor = .none
    }
}

// MARK: - Fan view

// colors of the fan controls, taken from the popup theme (the popup is dark whatever the system appearance)
private struct FanStyle {
    static var text: NSColor { ISTheme.current.label }
    static var dim: NSColor { ISTheme.current.dim }
    static var accent: NSColor { ISTheme.current.blue }
    static var box: NSColor { ISTheme.current.border.withAlphaComponent(0.55) }
    static var groove: NSColor { NSColor.black.withAlphaComponent(0.25) }
    static var selected: NSColor { ISTheme.current.track }
}

// one fan of the fans card: "name … 2 222 tpm" row, then the speed control (mode, slider, helper installation)
internal class FanView: NSStackView {
    public var sizeCallback: (() -> Void)
    
    internal var fan: Fan
    private var ready: Bool = false
    private let contentWidth: CGFloat
    
    private var row: ISRow? = nil
    private var helperView: NSView? = nil
    private var controlView: NSView? = nil
    private var buttonsView: NSView? = nil
    
    private var sliderValueField: NSTextField? = nil
    
    private var slider: NSSlider? = nil
    private var modeButtons: ModeButtons? = nil
    private var debouncer: DispatchWorkItem? = nil
    
    private var minBtn: NSButton? = nil
    private var maxBtn: NSButton? = nil
    
    private var speedState: Bool { Store.shared.bool(key: "Sensors_speed", defaultValue: false) }
    private var syncState: Bool { Store.shared.bool(key: "Sensors_fansSync", defaultValue: false) }
    private var speed: Double {
        get {
            if let v = self.fan.customSpeed, self.speedState {
                return Double(v)
            }
            return self.fan.value
        }
    }
    private var resetModeAfterSleep: Bool = false
    private var controlState: Bool
    private var helperInstalled: Bool = false
    private var helperButton: NSButton? = nil
    private var approvalPollTimer: Timer? = nil
    
    private var willSleepMode: FanMode? = nil // fan mode before sleep
    private var willSleepSpeed: Int? = nil // fan speed before sleep
    
    public init(_ fan: Fan, width: CGFloat, callback: @escaping (() -> Void)) {
        self.fan = fan
        self.contentWidth = width
        self.sizeCallback = callback
        self.controlState = Store.shared.bool(key: "Sensors_fanControl", defaultValue: true)
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        
        self.translatesAutoresizingMaskIntoConstraints = false
        self.orientation = .vertical
        self.alignment = .centerX
        self.distribution = .fill
        self.spacing = 0
        self.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.wakeListener), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.sleepListener), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.syncFanSpeed), name: .syncFansControl, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.changeHelperState), name: .fanHelperState, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.controlCallback), name: .toggleFanControl, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.recheckHelperState), name: NSApplication.didBecomeActiveNotification, object: nil)
        
        if let fanMode = self.fan.customMode, self.speedState && fanMode != FanMode.automatic {
            SMCHelper.shared.setFanMode(fan.id, mode: fanMode.rawValue)
            self.fan.mode = fanMode
            self.modeButtons?.setMode(FanMode(rawValue: fanMode.rawValue) ?? .automatic)
            
            self.setSpeed(value: Int(self.speed), then: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.sliderValueField?.textColor = FanStyle.accent
                }
            })
        }
    }
    
    public func loadContent() {
        guard self.row == nil else { return }
        self.helperView = self.noHelper()
        self.controlView = self.control()
        self.buttonsView = self.mode()
        self.nameAndSpeed()
        self.setupControls()
    }
    
    public func unloadContent() {
        self.arrangedSubviews.forEach { self.removeArrangedSubview($0) }
        self.subviews.forEach { $0.removeFromSuperview() }
        self.row = nil
        self.helperView = nil
        self.controlView = nil
        self.buttonsView = nil
        self.sliderValueField = nil
        self.slider = nil
        self.modeButtons = nil
        self.minBtn = nil
        self.maxBtn = nil
        self.helperButton = nil
        self.ready = false
        self.sizeCallback = {}
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.approvalPollTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: .syncFansControl, object: nil)
        NotificationCenter.default.removeObserver(self, name: .fanHelperState, object: nil)
        NotificationCenter.default.removeObserver(self, name: .toggleFanControl, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    
    private func nameAndSpeed() {
        let row = ISRow(self.fan.name)
        row.toolTip = self.fan.key
        self.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
        self.row = row
        self.setValue(self.fan)
    }
    
    private func setValue(_ value: Fan) {
        guard let row = self.row else { return }
        if value.value == 1 {
            row.setPlain("")
        } else {
            let (number, unit) = fanDisplay(value)
            row.setPlain(plainValue(number, unit))
        }
        row.valueField.toolTip = value.formattedValue
    }
    
    private func noHelper() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.contentWidth, height: 30))
        view.widthAnchor.constraint(equalToConstant: view.bounds.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let container = NSStackView(frame: NSRect(x: 0, y: 4, width: view.frame.width, height: view.frame.height - 8))
        container.wantsLayer = true
        container.layer?.cornerRadius = Constants.Popup.radius
        container.orientation = .horizontal
        container.alignment = .centerY
        container.distribution = .fillProportionally
        container.spacing = 0
        container.layer?.backgroundColor = FanStyle.box.cgColor
        
        let button: NSButton = NSButton()
        button.isBordered = false
        button.target = self
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Install fan helper"), attributes: [
            .foregroundColor: FanStyle.text,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        button.action = #selector(self.installHelper)
        self.helperButton = button
        
        container.addArrangedSubview(button)
        view.addSubview(container)
        
        return view
    }
    
    private func mode() -> NSView {
        let view: NSView = NSView(frame: NSRect(x: 0, y: 0, width: self.contentWidth, height: 44))
        view.widthAnchor.constraint(equalToConstant: view.bounds.width).isActive = true
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        
        let buttons = ModeButtons(frame: NSRect(
            x: 0,
            y: 4,
            width: view.frame.width,
            height: view.frame.height - 8
        ), mode: self.fan.mode)
        buttons.callback = { [weak self] (mode: FanMode) in
            if let fan = self?.fan, mode == .automatic || fan.mode != mode {
                self?.fan.mode = mode
                self?.fan.customMode = mode
                SMCHelper.shared.setFanMode(fan.id, mode: mode.rawValue)
            }
            self?.toggleControlView(mode == .forced)
        }
        buttons.off = { [weak self] in
            if let fan = self?.fan {
                if self?.fan.mode != .forced {
                    self?.fan.mode = .forced
                    SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                }
                self?.fan.customMode = .forced
                SMCHelper.shared.setFanSpeed(fan.id, speed: 0)
                self?.fan.customSpeed = 0
            }
            self?.toggleControlView(false)
        }
        buttons.turbo = { [weak self] in
            if let fan = self?.fan {
                if self?.fan.mode != .forced {
                    self?.fan.mode = .forced
                    SMCHelper.shared.setFanMode(fan.id, mode: FanMode.forced.rawValue)
                }
                self?.fan.customMode = .forced
                SMCHelper.shared.setFanSpeed(fan.id, speed: Int(fan.maxSpeed))
                self?.fan.customSpeed = Int(fan.maxSpeed)
            }
            self?.toggleControlView(false)
        }
        
        view.addSubview(buttons)
        self.modeButtons = buttons
        
        return view
    }
    
    private func control() -> NSView {
        let view: NSStackView = NSStackView(frame: NSRect(x: 0, y: 0, width: self.contentWidth, height: 40))
        view.heightAnchor.constraint(equalToConstant: view.bounds.height).isActive = true
        view.widthAnchor.constraint(equalToConstant: self.contentWidth).isActive = true
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: "control")
        
        view.orientation = .vertical
        view.distribution = .fill
        view.edgeInsets = NSEdgeInsets(top: 0, left: Constants.Popup.margins/2, bottom: Constants.Popup.margins/2, right: Constants.Popup.margins/2)
        
        let slider: NSSlider = NSSlider()
        slider.minValue = self.fan.minSpeed
        slider.maxValue = self.fan.maxSpeed
        slider.doubleValue = self.speed
        slider.isContinuous = true
        slider.action = #selector(self.sliderCallback)
        slider.target = self
        
        let levels: NSStackView = NSStackView()
        levels.heightAnchor.constraint(equalToConstant: 16).isActive = true
        levels.orientation = .horizontal
        levels.distribution = .fill
        
        let minBtn: NSButtonWithPadding = NSButtonWithPadding()
        minBtn.horizontalPadding = 4
        minBtn.title = "\(Int(self.fan.minSpeed))"
        minBtn.toolTip = localizedString("Min")
        minBtn.setButtonType(.toggle)
        minBtn.isBordered = false
        minBtn.target = self
        minBtn.state = .off
        minBtn.action = #selector(self.setMin)
        minBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        minBtn.wantsLayer = true
        minBtn.layer?.cornerRadius = Constants.Popup.radius
        minBtn.layer?.borderWidth = 1
        minBtn.layer?.borderColor = FanStyle.selected.cgColor
        
        let valueField: NSTextField = TextView()
        valueField.font = NSFont.systemFont(ofSize: 11, weight: .light)
        valueField.textColor = FanStyle.dim
        valueField.alignment = .center
        valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let speed = self.fan.customSpeed {
            valueField.stringValue = "\(Int(speed))"
        }
        
        let maxBtn: NSButtonWithPadding = NSButtonWithPadding()
        maxBtn.horizontalPadding = 4
        maxBtn.title = "\(Int(self.fan.maxSpeed))"
        maxBtn.toolTip = localizedString("Max")
        maxBtn.setButtonType(.toggle)
        maxBtn.isBordered = false
        maxBtn.target = self
        maxBtn.state = .off
        maxBtn.wantsLayer = true
        maxBtn.action = #selector(self.setMax)
        maxBtn.layer?.cornerRadius = Constants.Popup.radius
        maxBtn.layer?.borderWidth = 1
        maxBtn.layer?.borderColor = FanStyle.selected.cgColor
        maxBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        levels.addArrangedSubview(minBtn)
        levels.addArrangedSubview(valueField)
        levels.addArrangedSubview(maxBtn)
        
        view.addArrangedSubview(slider)
        view.addArrangedSubview(levels)
        
        levels.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -Constants.Popup.margins).isActive = true
        
        self.slider = slider
        self.sliderValueField = valueField
        self.minBtn = minBtn
        self.maxBtn = maxBtn
        
        return view
    }
    
    private func toggleControlView(_ state: Bool) {
        guard let view = self.controlView else {
            return
        }
        
        if state {
            self.slider?.doubleValue = self.speed
            if self.speedState {
                self.setSpeed(value: Int(self.speed), then: {
                    DispatchQueue.main.async {
                        self.sliderValueField?.textColor = FanStyle.accent
                    }
                })
            }
            self.addArrangedSubview(view)
        } else {
            self.sliderValueField?.stringValue = ""
            self.sliderValueField?.textColor = FanStyle.dim
            self.minBtn?.state = .off
            self.maxBtn?.state = .off
            view.removeFromSuperview()
        }
        
        self.sizeCallback()
    }
    
    private func setSpeed(value: Int, then: @escaping () -> Void = {}) {
        self.sliderValueField?.stringValue = "\(value) RPM"
        self.sliderValueField?.textColor = FanStyle.dim
        self.fan.customSpeed = value
        
        self.debouncer?.cancel()
        
        let task = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                if let id = self?.fan.id {
                    SMCHelper.shared.setFanSpeed(id, speed: value)
                }
                then()
            }
        }
        
        self.debouncer = task
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.3, execute: task)
    }
    
    @objc private func sliderCallback(_ sender: NSSlider) {
        var value = sender.doubleValue
        if value > self.fan.maxSpeed {
            value = self.fan.maxSpeed
        } else if value < self.fan.minSpeed {
            value = self.fan.minSpeed
        }
        
        self.minBtn?.state = .off
        self.maxBtn?.state = .off
        
        self.setSpeed(value: Int(value), then: {
            DispatchQueue.main.async {
                self.slider?.intValue = Int32(value)
                self.sliderValueField?.textColor = FanStyle.accent
            }
        })
        
        if sender.tag != 4 {
            if self.fan.minSpeed != 0 && self.fan.maxSpeed != 0 && self.fan.maxSpeed != self.fan.minSpeed {
                let percentage = Int((100*(value-self.fan.minSpeed))/(self.fan.maxSpeed - self.fan.minSpeed))
                NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["percentage": percentage])
            } else {
                NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(value)])
            }
        }
    }
    
    @objc func setMin() {
        self.slider?.doubleValue = self.fan.minSpeed
        self.maxBtn?.state = .off
        self.setSpeed(value: Int(self.fan.minSpeed))
        NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(self.fan.minSpeed)])
    }
    
    @objc func setMax() {
        self.slider?.doubleValue = self.fan.maxSpeed
        self.minBtn?.state = .off
        self.setSpeed(value: Int(self.fan.maxSpeed))
        NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["speed": Int(self.fan.maxSpeed)])
    }
    
    @objc private func wakeListener() {
        self.resetModeAfterSleep = true
        
        if self.speedState {
            if let mode = self.willSleepMode, let speed = self.willSleepSpeed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    SMCHelper.shared.setFanMode(self.fan.id, mode: mode.rawValue)
                    self.modeButtons?.setMode(mode)
                    if !mode.isAutomatic {
                        self.setSpeed(value: speed, then: { [weak self] in
                            DispatchQueue.main.async { [weak self] in
                                self?.sliderValueField?.textColor = FanStyle.accent
                            }
                        })
                    }
                }
            }
            self.willSleepMode = nil
            self.willSleepSpeed = nil
        }
        
        if let value = self.fan.customSpeed, !self.fan.mode.isAutomatic {
            self.setSpeed(value: value, then: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.sliderValueField?.textColor = FanStyle.accent
                }
            })
        }
    }
    
    @objc private func sleepListener() {
        guard SMCHelper.shared.isActive(), let mode = self.fan.customMode, !mode.isAutomatic else { return }
        
        self.willSleepMode = mode
        self.willSleepSpeed = self.fan.customSpeed
        SMCHelper.shared.setFanMode(self.fan.id, mode: FanMode.automatic.rawValue)
        self.modeButtons?.setMode(.automatic)
    }
    
    @objc private func syncFanSpeed(_ notification: Notification) {
        guard self.syncState else { return }
        var speed = notification.userInfo?["speed"] as? Int
        if let percentage = notification.userInfo?["percentage"] as? Int {
            speed = ((Int(self.fan.maxSpeed - self.fan.minSpeed)*percentage)/100) + Int(self.fan.minSpeed)
        }
        
        guard let speed, self.fan.customSpeed != speed else { return }
        
        let slider = NSSlider()
        slider.tag = 4
        slider.maxValue = 30000
        slider.intValue = Int32(speed)
        
        self.sliderCallback(slider)
    }
    
    public func update(_ value: Fan) {
        DispatchQueue.main.async(execute: {
            if (self.window?.isVisible ?? false) || !self.ready {
                self.fan.value = value.value
                self.setValue(value)
                
                if self.resetModeAfterSleep && !value.mode.isAutomatic {
                    if self.sliderValueField?.stringValue.isEmpty != true && self.slider?.doubleValue != value.value {
                        self.slider?.doubleValue = value.value
                        self.sliderValueField?.stringValue = ""
                    }
                    self.modeButtons?.setMode(.forced)
                    self.resetModeAfterSleep = false
                }
                
                self.ready = true
            }
        })
    }
    
    @objc private func installHelper() {
        SMCHelper.shared.install { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .enabled:
                    NotificationCenter.default.post(name: .fanHelperState, object: nil, userInfo: ["state": true])
                case .requiresApproval:
                    self?.showApprovalPending()
                case .failed:
                    self?.showInstallFailed()
                    NotificationCenter.default.post(name: .fanHelperState, object: nil, userInfo: ["state": false])
                }
            }
        }
    }
    
    @objc private func openLoginItems() {
        guard #available(macOS 13, *) else { return }
        (self.window as? PopupWindow)?.dismissIfUnlocked()
        SMCHelper.shared.openLoginItems()
    }
    
    private func showApprovalPending() {
        self.helperButton?.title = localizedString("Approve in System Settings ▸ Login Items")
        self.helperButton?.action = #selector(self.openLoginItems)
        
        self.startApprovalPolling()
        
        let alert = NSAlert()
        alert.messageText = localizedString("Fan helper needs your approval")
        alert.informativeText = localizedString("To control the fans, enable Stats in System Settings ▸ Login Items.")
        alert.addButton(withTitle: localizedString("Open Login Items"))
        alert.addButton(withTitle: localizedString("Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            self.openLoginItems()
        }
    }
    
    private func showInstallFailed() {
        let alert = NSAlert()
        alert.messageText = localizedString("Could not enable the fan helper")
        alert.informativeText = localizedString("Open System Settings ▸ Login Items, make sure Stats is allowed in the background, then try again.")
        alert.addButton(withTitle: localizedString("Open Login Items"))
        alert.addButton(withTitle: localizedString("Cancel"))
        
        if alert.runModal() == .alertFirstButtonReturn {
            self.openLoginItems()
        }
    }
    
    private func startApprovalPolling() {
        self.approvalPollTimer?.invalidate()
        var elapsed: TimeInterval = 0
        self.approvalPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            elapsed += 2
            if SMCHelper.shared.isInstalled {
                timer.invalidate()
                self?.approvalPollTimer = nil
                DispatchQueue.main.async {
                    self?.helperButton?.title = localizedString("Install fan helper")
                    self?.helperButton?.action = #selector(FanView.installHelper)
                    self?.setupControls(true)
                }
            } else if elapsed >= 60 {
                timer.invalidate()
                self?.approvalPollTimer = nil
            }
        }
    }
    
    // which controls follow the row: nothing, the helper installation, or the mode buttons and the slider
    private func setupControls(_ isInstalled: Bool? = nil) {
        let helperState = isInstalled ?? SMCHelper.shared.isInstalled
        self.helperInstalled = helperState
        guard self.row != nil else { return }
        
        if !self.controlState {
            self.helperView?.removeFromSuperview()
            self.controlView?.removeFromSuperview()
            self.buttonsView?.removeFromSuperview()
        } else {
            if helperState {
                self.helperView?.removeFromSuperview()
                if self.fan.maxSpeed != self.fan.minSpeed, let v = self.buttonsView {
                    self.addArrangedSubview(v)
                }
                if self.fan.mode == .forced, let v = self.controlView {
                    self.addArrangedSubview(v)
                }
            } else {
                self.buttonsView?.removeFromSuperview()
                self.controlView?.removeFromSuperview()
                if let v = self.helperView {
                    self.addArrangedSubview(v)
                }
            }
        }
        
        self.sizeCallback()
    }
    
    @objc private func changeHelperState(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.setupControls(state)
    }
    
    @objc private func recheckHelperState() {
        guard SMCHelper.shared.isInstalled != self.helperInstalled else { return }
        self.setupControls()
    }
    
    @objc private func controlCallback(_ notification: Notification) {
        guard let state = notification.userInfo?["state"] as? Bool else { return }
        self.controlState = state
        self.setupControls()
    }
}

private class ModeButtons: NSStackView {
    public var callback: (FanMode) -> Void = {_ in }
    public var turbo: () -> Void = {}
    public var off: () -> Void = {}
    
    private var fansSyncState: Bool { Store.shared.bool(key: "Sensors_fansSync", defaultValue: false) }
    
    private var modes: ModeSwitch
    
    private var offBtn: NSButton
    private var turboBtn: NSButton
    
    public init(frame: NSRect, mode: FanMode) {
        self.modes = .init(mode)
        
        self.offBtn = NSButton(image: iconFromSymbol(name: "nosign", scale: .medium), target: nil, action: #selector(self.offMode))
        self.turboBtn = NSButton(image: iconFromSymbol(name: "snowflake", scale: .large), target: nil, action: #selector(self.turboMode))
        
        super.init(frame: frame)
        
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fillProportionally
        self.spacing = 0
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.layer?.backgroundColor = FanStyle.box.cgColor
        self.edgeInsets = .init(top: 0, left: Constants.Popup.margins/2, bottom: 0, right: Constants.Popup.margins/2)
        
        self.modes.autoCallback = { [weak self] in
            if let self {
                self.offBtn.state = .off
                self.turboBtn.state = .off
                self.callback(.automatic)
            }
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "automatic"])
            NotificationCenter.default.post(name: .checkFanModes, object: nil)
        }
        self.modes.manualCallback = { [weak self] in
            if let self {
                self.offBtn.state = .off
                self.turboBtn.state = .off
                self.callback(.forced)
            }
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "forced"])
        }
        
        self.offBtn.setButtonType(.toggle)
        self.offBtn.isBordered = false
        self.offBtn.target = self
        
        self.turboBtn.setButtonType(.toggle)
        self.turboBtn.isBordered = false
        self.turboBtn.target = self
        
        self.addArrangedSubview(self.modes)
        self.addArrangedSubview(self.offBtn)
        self.addArrangedSubview(self.turboBtn)
        
        NSLayoutConstraint.activate([
            self.modes.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -Constants.Popup.margins),
            self.offBtn.widthAnchor.constraint(equalToConstant: 26),
            self.offBtn.heightAnchor.constraint(equalToConstant: self.frame.height),
            self.turboBtn.widthAnchor.constraint(equalToConstant: 26),
            self.turboBtn.heightAnchor.constraint(equalToConstant: self.frame.height)
        ])
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.syncFanMode), name: .syncFansControl, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = FanStyle.box.cgColor
    }
    
    @objc private func offMode(_ sender: NSButton) {
        if sender.state.rawValue == 0 {
            self.offBtn.state = .on
            return
        }
        
        if !Store.shared.bool(key: "Sensors_turnOffFanAlert", defaultValue: false) {
            let alert = NSAlert()
            alert.messageText = localizedString("Turn off fan")
            alert.informativeText = localizedString("You are going to turn off the fan. This is not recommended action that can damage your mac, are you sure you want to do that?")
            alert.showsSuppressionButton = true
            alert.addButton(withTitle: localizedString("Turn off"))
            alert.addButton(withTitle: localizedString("Cancel"))
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let suppressionButton = alert.suppressionButton, suppressionButton.state == .on {
                    Store.shared.set(key: "Sensors_turnOffFanAlert", value: true)
                }
                self.toggleOffMode(sender)
            } else {
                self.offBtn.state = .off
            }
        } else {
            self.toggleOffMode(sender)
        }
    }
    
    private func toggleOffMode(_ sender: NSButton) {
        self.modes.change()
        self.offBtn.state = .on
        self.turboBtn.state = .off
        self.off()
        
        if sender.tag != 4 {
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "off"])
        }
    }
    
    @objc private func turboMode(_ sender: NSButton) {
        if sender.state.rawValue == 0 {
            self.turboBtn.state = .on
            return
        }
        
        self.modes.change()
        self.offBtn.state = .off
        self.turboBtn.state = .on
        self.turbo()
        
        if sender.tag != 4 {
            NotificationCenter.default.post(name: .syncFansControl, object: nil, userInfo: ["mode": "turbo"])
        }
    }
    
    @objc private func syncFanMode(_ notification: Notification) {
        guard let mode = notification.userInfo?["mode"] as? String, self.fansSyncState else {
            return
        }
        
        if mode == "automatic" {
            self.setMode(.automatic)
        } else if mode == "forced" {
            self.setMode(.forced)
        } else if mode == "off" {
            let btn = NSButton()
            btn.state = .on
            btn.tag = 4
            self.offMode(btn)
        } else if mode == "turbo" {
            let btn = NSButton()
            btn.state = .on
            btn.tag = 4
            self.turboMode(btn)
        }
    }
    
    public func setMode(_ mode: FanMode) {
        if mode.isAutomatic {
            self.modes.change(auto: true)
            self.offBtn.state = .off
            self.turboBtn.state = .off
            self.callback(.automatic)
        } else if mode == .forced {
            self.modes.change(manual: true)
            self.offBtn.state = .off
            self.turboBtn.state = .off
            self.callback(.forced)
        }
    }
}

private class ModeSwitch: NSStackView {
    public var autoCallback: (() -> Void)?
    public var manualCallback: (() -> Void)?
    
    private var autoBtn: NSButton = {
        let button: NSButton = NSButton(title: localizedString("Automatic"), target: nil, action: #selector(ModeSwitch.autoMode))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Constants.Popup.radius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Automatic"), attributes: [
            .foregroundColor: FanStyle.text,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        return button
    }()
    
    private var manualBtn: NSButton = {
        let button: NSButton = NSButton(title: localizedString("Manual"), target: nil, action: #selector(ModeSwitch.manualMode))
        button.setButtonType(.toggle)
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Constants.Popup.radius
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.attributedTitle = NSAttributedString(string: localizedString("Manual"), attributes: [
            .foregroundColor: FanStyle.text,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ])
        return button
    }()
    
    private var selectedColor: CGColor {
        FanStyle.selected.cgColor
    }
    
    init(_ mode: FanMode) {
        super.init(frame: .zero)
        
        self.orientation = .horizontal
        self.alignment = .centerY
        self.distribution = .fillEqually
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.layer?.backgroundColor = FanStyle.groove.cgColor
        self.spacing = 0
        self.edgeInsets = .init(top: 2, left: 2, bottom: 2, right: 2)
        
        self.autoBtn.target = self
        self.autoBtn.state = mode.isAutomatic ? .on : .off
        self.autoBtn.layer?.backgroundColor = mode.isAutomatic ? self.selectedColor : NSColor.clear.cgColor
        
        self.manualBtn.target = self
        self.manualBtn.state = mode == .forced ? .on : .off
        self.manualBtn.layer?.backgroundColor = mode == .forced ? self.selectedColor : NSColor.clear.cgColor
        
        self.addArrangedSubview(self.autoBtn)
        self.addArrangedSubview(self.manualBtn)
        
        NSLayoutConstraint.activate([
            self.autoBtn.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -4),
            self.manualBtn.heightAnchor.constraint(equalTo: self.heightAnchor, constant: -4)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateLayer() {
        self.layer?.backgroundColor = FanStyle.groove.cgColor
        self.autoBtn.layer?.backgroundColor = self.autoBtn.state == .on ? self.selectedColor : NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = self.manualBtn.state == .on ? self.selectedColor : NSColor.clear.cgColor
    }
    
    public func change(auto: Bool = false, manual: Bool = false) {
        self.autoBtn.state = auto ? .on : .off
        self.manualBtn.state = manual ? .on : .off
        
        self.autoBtn.layer?.backgroundColor = auto ? self.selectedColor : NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = manual ? self.selectedColor : NSColor.clear.cgColor
    }
    
    @objc private func autoMode() {
        self.autoBtn.state = .on
        self.manualBtn.state = .off
        
        self.autoBtn.layer?.backgroundColor = self.selectedColor
        self.manualBtn.layer?.backgroundColor = NSColor.clear.cgColor
        
        self.autoCallback?()
    }
    
    @objc private func manualMode() {
        self.autoBtn.state = .off
        self.manualBtn.state = .on
        
        self.autoBtn.layer?.backgroundColor = NSColor.clear.cgColor
        self.manualBtn.layer?.backgroundColor = self.selectedColor
        
        self.manualCallback?()
    }
}
