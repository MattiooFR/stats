//
//  popup.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private enum Gauge {
        case utilization
        case memory
        case temperature
        case ane
        case render
        case tiler
        
        var caption: String {
            switch self {
            case .utilization: return "GPU"
            case .memory: return "MEM"
            case .temperature: return "TMP"
            case .ane: return "ANE"
            case .render: return isL("RENDER", fr: "RENDU")
            case .tiler: return "TILER"
            }
        }
        
        var toolTip: String {
            switch self {
            case .utilization: return localizedString("GPU utilization")
            case .memory: return localizedString("Memory usage")
            case .temperature: return localizedString("Temperature")
            case .ane: return localizedString("ANE utilization")
            case .render: return localizedString("Renderer utilization")
            case .tiler: return localizedString("Tiler utilization")
            }
        }
    }
    
    private struct GaugeValue {
        let gauge: Gauge
        let arc: Double
        let number: String
        let unit: String
    }
    
    private let ringDiameter: CGFloat = 52
    private let maxRings: Int = 4
    
    // GPU utilization per tick, one history per GPU (the selected GPU can change in the settings)
    private var histories: [String: ISHistory<[Double]>] = [:]
    // Stats has no GPU temperature in the module readings: it is read from the SMC while the popup is open
    private let temperatureReader = GPUTemperatureReader()
    private var temperatureValue: Double? = nil
    // [utilization, renderer, tiler, memory in bytes, frames per second] and the temperature, kept up to 30 days for the side panel
    private let longHistory = ISHistoryStore.shared.series("gpu.usage", dimensions: 5)
    private let temperatureHistory = ISHistoryStore.shared.series("gpu.temperature", dimensions: 1)
    private var temperatureReadAt: TimeInterval = 0
    
    private var card: ISCard? = nil
    private var ringRow: ISRingRow? = nil
    private var ringCount: Int = -1
    private var chart: ISBarChart? = nil
    private var processes: ISProcessList? = nil
    private var processRows: Int = 0
    
    private var modelRow: ISRow? = nil
    private var coresRow: ISRow? = nil
    private var memoryRow: ISRow? = nil
    private var renderRow: ISRow? = nil
    private var tilerRow: ISRow? = nil
    
    private let loadCache = PopupCache<GPU_Info>()
    private let processesCache = PopupCache<[TopProcess]>()
    
    private var numberOfProcesses: Int {
        #if arch(arm64)
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
        #else
        0
        #endif
    }
    private var multipleGPUs: Bool {
        (SystemKit.shared.device.info.gpu?.count ?? 1) > 1
    }
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 256, height: 0))
        
        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadContent() {
        self.temperatureReader.isActive = true
        if let value = self.temperatureReader.read(ioClass: self.loadCache.value?.IOClass) {
            self.temperatureValue = value
        }
        
        self.addSection(self.initGPU())
        self.addSection(self.initDetails())
        self.addSection(ISShortcutBar(module: .GPU, extra: [ISShortcut.app("com.apple.SystemProfiler")]))
        
        self.resizeToFitContent()
    }
    
    public override func unloadContent() {
        self.temperatureReader.isActive = false
        
        self.card = nil
        self.ringRow = nil
        self.ringCount = -1
        self.chart = nil
        self.processes = nil
        self.processRows = 0
        self.modelRow = nil
        self.coresRow = nil
        self.memoryRow = nil
        self.renderRow = nil
        self.tilerRow = nil
    }
    
    public override func appear() {
        self.replay(self.loadCache, render: self.renderLoad)
        self.replay(self.processesCache, render: self.renderProcesses)
    }
    
    // MARK: - Views
    
    private func initGPU() -> NSView {
        let theme = ISTheme.current
        let card = ISCard(title: "GPU", value: "")
        
        let row = ISRingRow(count: self.maxRings, diameter: self.ringDiameter, lineWidth: 4.5)
        let placeholders: [Gauge] = [.utilization, .memory, .temperature, .ane]
        for (i, ring) in row.rings.enumerated() where placeholders.indices.contains(i) {
            ring.setText("—", caption: placeholders[i].caption)
            ring.toolTip = placeholders[i].toolTip
        }
        card.add(row, spacingAfter: 4)
        self.ringRow = row
        
        let chart = ISBarChart(colors: [theme.blue], height: 44)
        chart.toolTip = localizedString("Usage history")
        card.add(chart, spacingAfter: 5)
        self.chart = chart
        
        if self.numberOfProcesses > 0 {
            let list = ISProcessList(n: self.numberOfProcesses)
            card.add(list)
            self.processes = list
        }
        
        self.attachHistory(card)
        self.card = card
        return card
    }
    
    private func initDetails() -> NSView {
        let card = ISCard(title: localizedString("Details"))
        
        let model = ISRow(localizedString("Model"))
        model.setPlain("—")
        let cores = ISRow(isL("Cores", fr: "Cœurs"))
        let memory = ISRow(localizedString("Memory"))
        let render = ISRow(isL("Renderer", fr: "Rendu"))
        render.toolTip = localizedString("Renderer utilization")
        let tiler = ISRow("Tiler")
        tiler.toolTip = localizedString("Tiler utilization")
        
        [model, cores, memory, render, tiler].forEach { card.add($0) }
        [cores, memory, render, tiler].forEach { $0.isHidden = true }
        
        self.modelRow = model
        self.coresRow = cores
        self.memoryRow = memory
        self.renderRow = render
        self.tilerRow = tiler
        self.attachHistory(card)
        
        return card
    }
    
    // MARK: - History panel
    
    // both cards share one side panel: utilization, renderer and tiler, memory and temperature over time
    private func attachHistory(_ card: ISCard) {
        card.detailID = "history"
        card.detail = { [weak self] in
            self?.historyDetail() ?? NSView()
        }
    }
    
    private func bytes(_ value: Double) -> String {
        Units(bytes: Int64(max(0, value))).getReadableMemory(style: .memory)
    }
    
    private func historyDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()
        let current = self.loadCache.value
        
        let usage = ISHistoryCard(
            title: isL("Utilization", fr: "Utilisation"),
            series: self.longHistory,
            style: .stacked,
            colors: [theme.blue],
            dims: [0],
            height: 72,
            scale: 1
        )
        let average = ISRow(isL("Average", fr: "Moyenne"))
        let peak = ISRow(isL("Peak", fr: "Pic"))
        let frames = ISRow(isL("Frames per second", fr: "Images par seconde"))
        usage.add(average)
        usage.add(peak)
        usage.add(frames)
        frames.isHidden = current?.fps == nil
        usage.summary = { _, points in
            average.set(points.isAverage(0).map({ isPercent($0) }) ?? "—")
            peak.set(points.isMaximum(0).map({ isPercent(min($0, 1)) }) ?? "—")
            frames.setPlain(points.isAverage(4).map({ "\(Int($0.rounded()))" }) ?? "—")
        }
        stack.add(usage)
        
        if current?.renderUtilization != nil || current?.tilerUtilization != nil {
            let stages = ISHistoryCard(
                title: isL("Renderer and tiler", fr: "Rendu et tiler"),
                series: self.longHistory,
                style: .lines,
                colors: [theme.blue, theme.pink],
                dims: [1, 2],
                height: 44,
                scale: 1
            )
            let render = ISRow(isL("Renderer", fr: "Rendu"), color: theme.blue)
            let tiler = ISRow("Tiler", color: theme.pink)
            stages.add(render)
            stages.add(tiler)
            stages.summary = { _, points in
                render.set(points.isAverage(1).map({ isPercent($0) }) ?? "—")
                tiler.set(points.isAverage(2).map({ isPercent($0) }) ?? "—")
            }
            stack.add(stages)
        }
        
        if current?.memory != nil {
            // scaled to the highest value on screen: against the whole unified memory the bars would stay flat
            let memory = ISHistoryCard(
                title: localizedString("Memory"),
                series: self.longHistory,
                style: .stacked,
                colors: [theme.yellow],
                dims: [3],
                height: 40
            )
            let memoryAverage = ISRow(isL("Average", fr: "Moyenne"))
            let memoryPeak = ISRow(isL("Peak", fr: "Pic"))
            memory.add(memoryAverage)
            memory.add(memoryPeak)
            memory.summary = { [weak self] _, points in
                guard let self else { return }
                memoryAverage.set(points.isAverage(3).map({ self.bytes($0) }) ?? "—")
                memoryPeak.set(points.isMaximum(3).map({ self.bytes($0) }) ?? "—")
            }
            stack.add(memory)
        }
        
        if self.temperatureValue != nil {
            let heat = ISHistoryCard(
                title: localizedString("Temperature"),
                series: self.temperatureHistory,
                style: .lines,
                colors: [theme.pink],
                dims: [0],
                height: 40,
                scale: 110
            )
            let heatAverage = ISRow(isL("Average", fr: "Moyenne"))
            let heatPeak = ISRow(isL("Peak", fr: "Pic"))
            heat.add(heatAverage)
            heat.add(heatPeak)
            heat.summary = { _, points in
                heatAverage.set(points.isAverage(0).map({ temperature($0) }) ?? "—")
                heatPeak.set(points.isMaximum(0).map({ temperature($0) }) ?? "—")
            }
            stack.add(heat)
        }
        
        stack.refresh()
        return stack
    }
    
    // MARK: - Updates
    
    private func history(for id: String) -> ISHistory<[Double]> {
        if let history = self.histories[id] { return history }
        let history = ISHistory<[Double]>(capacity: 160)
        self.histories[id] = history
        return history
    }
    
    // share of the memory the GPU may use: the wired limit when one is set, the whole (unified) memory otherwise
    private func memoryUsage(_ value: GPU_Info) -> Double? {
        guard let used = value.memory else { return nil }
        var limit = Double(ProcessInfo.processInfo.physicalMemory)
        if let megabytes = value.memoryLimit, megabytes > 0 {
            limit = megabytes * 1024 * 1024
        }
        guard limit > 0 else { return nil }
        return max(0, min(1, used / limit))
    }
    
    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))"
    }
    
    @discardableResult
    private func setHidden(_ view: NSView?, _ hidden: Bool) -> Bool {
        guard let view, view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }
    
    public func loadCallback(_ value: GPU_Info) {
        // the SMC is read at every tick while the popup is open, every 30 seconds otherwise (enough for the history)
        let now = Date().timeIntervalSince1970
        var temperature: Double? = nil
        if self.temperatureReader.isActive || now - self.temperatureReadAt >= 30 {
            temperature = self.temperatureReader.read(ioClass: value.IOClass)
            self.temperatureReadAt = now
            if let temperature {
                self.temperatureHistory.record([temperature])
            }
        }
        if let utilization = value.utilization {
            self.longHistory.record([
                utilization,
                value.renderUtilization ?? 0,
                value.tilerUtilization ?? 0,
                value.memory ?? 0,
                value.fps ?? 0
            ])
        }
        DispatchQueue.main.async {
            if let utilization = value.utilization {
                self.history(for: value.id).append([utilization])
            }
            if let temperature {
                self.temperatureValue = temperature
            }
        }
        self.apply(value, to: self.loadCache, render: self.renderLoad)
    }
    
    private func renderLoad(_ value: GPU_Info) {
        self.card?.titleField?.stringValue = self.multipleGPUs && !value.model.isEmpty ? value.model.uppercased() : "GPU"
        self.card?.valueField?.stringValue = value.fps.map { "\(Int($0.rounded())) FPS" } ?? ""
        
        var gauges: [GaugeValue] = []
        if let v = value.utilization {
            gauges.append(GaugeValue(gauge: .utilization, arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.memoryUsage(value) {
            gauges.append(GaugeValue(gauge: .memory, arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.temperatureValue {
            let local = Measurement(value: v, unit: UnitTemperature.celsius).converted(to: UnitTemperature.current).value
            // the degree sign stays at the size of the digits (as a small unit it is hardly readable)
            gauges.append(GaugeValue(gauge: .temperature, arc: v / 100, number: "\(Int(local.rounded()))°", unit: ""))
        }
        if let v = value.aneUtilization {
            gauges.append(GaugeValue(gauge: .ane, arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = value.renderUtilization {
            gauges.append(GaugeValue(gauge: .render, arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = value.tilerUtilization {
            gauges.append(GaugeValue(gauge: .tiler, arc: v, number: self.percent(v), unit: "%"))
        }
        let shown = Array(gauges.prefix(self.maxRings))
        
        self.layoutRings(shown.count)
        if let rings = self.ringRow?.rings {
            for (i, item) in shown.enumerated() where rings.indices.contains(i) {
                rings[i].set(value: item.arc)
                rings[i].setText(item.number, unit: item.unit, caption: item.gauge.caption)
                rings[i].toolTip = item.gauge.toolTip
            }
        }
        
        self.chart?.set(self.history(for: value.id).values)
        
        // details: what the rings do not already show
        var changed = false
        self.modelRow?.setPlain(value.model.isEmpty ? localizedString("Unknown") : value.model)
        
        let devices = SystemKit.shared.device.info.gpu ?? []
        let device = devices.first(where: { $0.name == value.model }) ?? (devices.count == 1 ? devices.first : nil)
        if let cores = device?.cores {
            self.coresRow?.setPlain("\(cores)")
            changed = self.setHidden(self.coresRow, false) || changed
        } else {
            changed = self.setHidden(self.coresRow, true) || changed
        }
        
        if let memory = value.memory {
            self.memoryRow?.set(Units(bytes: Int64(max(0, memory))).getReadableMemory(style: .memory))
            changed = self.setHidden(self.memoryRow, false) || changed
        } else {
            changed = self.setHidden(self.memoryRow, true) || changed
        }
        
        let ringed = shown.map { $0.gauge }
        if let v = value.renderUtilization, !ringed.contains(.render) {
            self.renderRow?.set(isPercent(v))
            changed = self.setHidden(self.renderRow, false) || changed
        } else {
            changed = self.setHidden(self.renderRow, true) || changed
        }
        if let v = value.tilerUtilization, !ringed.contains(.tiler) {
            self.tilerRow?.set(isPercent(v))
            changed = self.setHidden(self.tilerRow, false) || changed
        } else {
            changed = self.setHidden(self.tilerRow, true) || changed
        }
        
        if changed {
            self.resizeToFitContent()
        }
    }
    
    // only the rings that have a value are shown, spread over the width of the card
    private func layoutRings(_ count: Int) {
        guard let row = self.ringRow, self.ringCount != count else { return }
        self.ringCount = count
        
        for (i, ring) in row.rings.enumerated() {
            ring.isHidden = i >= count
        }
        
        let width = self.frame.width - (ISMetrics.padH * 2)
        var inset: CGFloat = 0
        switch count {
        case 1: inset = max(0, (width - self.ringDiameter) / 2)
        case 2: inset = 40
        case 3: inset = 12
        default: inset = 0
        }
        row.edgeInsets = NSEdgeInsets(top: row.edgeInsets.top, left: inset, bottom: row.edgeInsets.bottom, right: inset)
    }
    
    public func processCallback(_ list: [TopProcess]?) {
        guard let list else { return }
        self.apply(list, to: self.processesCache, render: self.renderProcesses)
    }
    
    private func renderProcesses(_ list: [TopProcess]) {
        guard let processes = self.processes else { return }
        let n = min(list.count, processes.count)
        for i in 0..<n {
            let usage = list[i].usage
            processes.set(i, list[i], [usage < 0.05 ? "0%" : "\(isNumber(usage))%"])
        }
        processes.clear(from: n)
        
        // rows without a process are not shown; the list only grows while the popup is open (no flicker)
        self.processRows = max(self.processRows, n)
        var changed = false
        for (i, row) in processes.arrangedSubviews.enumerated() {
            changed = self.setHidden(row, i >= self.processRows) || changed
        }
        changed = self.setHidden(processes, self.processRows == 0) || changed
        if changed {
            self.resizeToFitContent()
        }
    }
    
    public func numberOfProcessesUpdated() {
        DispatchQueue.main.async {
            guard self.contentLoaded, (self.processes?.count ?? 0) != self.numberOfProcesses else { return }
            self.releaseContent()
            self.processesCache.initialized = false
            self.loadCache.initialized = false
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

// GPU temperature from the SMC: average of the GPU sensors of the chip (same keys as the Sensors module)
private final class GPUTemperatureReader {
    private let lock = NSLock()
    private var active: Bool = false
    
    // the popup is open: only then the SMC is read
    var isActive: Bool {
        get {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.active
        }
        set {
            self.lock.lock()
            self.active = newValue
            self.lock.unlock()
        }
    }
    
    private lazy var keys: [String] = {
        guard let platform = SystemKit.shared.device.platform else { return [] }
        switch platform {
        case .m1, .m1Pro, .m1Max, .m1Ultra:
            return ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
        case .m2, .m2Pro, .m2Max, .m2Ultra:
            return ["Tg0f", "Tg0j"]
        case .m3, .m3Pro, .m3Max, .m3Ultra:
            return ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        case .m4:
            return ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m4Pro, .m4Max:
            return ["Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
        case .m5, .m5Pro, .m5Max, .m5Ultra:
            return ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
        case .m6, .m6Pro, .m6Max:
            return ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"]
        case .a18Pro:
            return ["Tg05", "Tg0D", "Tg0L", "Tg0e"]
        case .intel:
            return []
        }
    }()
    
    private func valid(_ key: String) -> Double? {
        guard let value = SMC.shared.getValue(key), value >= 10 && value <= 120 else { return nil }
        return value
    }
    
    func read(ioClass: String?) -> Double? {
        self.lock.lock()
        let keys = self.keys
        self.lock.unlock()
        
        if !keys.isEmpty {
            let values = keys.compactMap { self.valid($0) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        
        // Intel Macs: one diode per GPU
        let name = (ioClass ?? "").lowercased()
        var candidates: [String] = ["TGDD", "TG0D", "TCGC", "TG0P"]
        if name.contains("intel") {
            candidates = ["TCGC"]
        } else if name.contains("amd") || name.contains("nvidia") || name == "nvaccelerator" {
            candidates = ["TGDD", "TG0D", "TG0P"]
        }
        for key in candidates {
            if let value = self.valid(key) { return value }
        }
        return nil
    }
}
