//
//  popup.swift
//  CPU
//
//  Created by Serhiy Mytrovtsiy on 15/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    // [user, system] per tick, drawn as stacked bars
    private let loadHistory = ISHistory<[Double]>(capacity: 160)
    // [user, system, both] and the load averages, kept up to 30 days for the side panel
    private let longHistory = ISHistoryStore.shared.series("cpu.load", dimensions: 3)
    private let averageHistory = ISHistoryStore.shared.series("cpu.average", dimensions: 3)

    private var usageCard: ISCard? = nil
    private var chart: ISBarChart? = nil
    private var legend: ISLegendRow? = nil

    private var coreRings: ISCoreRings? = nil
    private var eCoresRow: ISRow? = nil
    private var pCoresRow: ISRow? = nil
    private var sCoresRow: ISRow? = nil

    private var processes: ISProcessList? = nil
    // the GPU inside the CPU menu, as in iStat Menus: readings shared by the GPU module
    private var gpuCard: ISCard? = nil
    private var gpuRings: ISRingRow? = nil
    private var gpuProcesses: ISProcessList? = nil
    private var appearedAt: Date = .distantPast
    private var averageCard: ISCard? = nil
    private var frequencyCard: ISCard? = nil
    private var uptimeCard: ISCard? = nil

    private let processCache = PopupCache<[TopProcess]>()
    private let loadCache = PopupCache<CPU_Load>()
    private let temperatureCache = PopupCache<Double?>()
    private let frequencyCache = PopupCache<CPU_Frequency?>()
    private let averageCache = PopupCache<CPU_AverageLoad>()

    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 5)
    }
    private var uptimeValue: String {
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        var value = localizedString("Unknown")
        if let bootDate = SystemKit.shared.device.bootDate {
            if let duration = form.string(from: bootDate, to: Date()) {
                // "1 jour, 5 heures" as iStat Menus writes it: shorter, the title keeps more room
                value = duration.replacingOccurrences(of: " et ", with: ", ")
            }
        }
        return value
    }

    private var hasSuperCores: Bool { SystemKit.shared.device.info.cpu?.sCores != nil }
    private var pCoresColor: NSColor { ISTheme.current.pink }
    private var sCoresColor: NSColor { ISTheme.current.blue }
    private var eCoresColor: NSColor { self.hasSuperCores ? ISTheme.current.yellow : ISTheme.current.blue }

    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 256, height: 0))

        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.gpuUpdated), name: ISGPUShare.updated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.gpuProcessesUpdated), name: ISGPUShare.processesUpdated, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadContent() {
        self.addSection(self.initUsage())
        self.addSection(self.initCores())
        if self.numberOfProcesses > 0 {
            self.addSection(self.initProcesses())
        }
        self.addSection(self.initGPU())
        self.addSection(self.initAverage())
        self.addSection(self.initFrequency())
        self.addSection(self.initUptime())
        self.addSection(ISShortcutBar(module: .CPU, extra: [ISShortcut.app("com.apple.SystemProfiler")]))

        self.resizeToFitContent()
    }

    public override func unloadContent() {
        self.usageCard = nil
        self.chart = nil
        self.legend = nil
        self.coreRings = nil
        self.eCoresRow = nil
        self.pCoresRow = nil
        self.sCoresRow = nil
        self.processes = nil
        self.gpuCard = nil
        self.gpuRings = nil
        self.gpuProcesses = nil
        self.averageCard = nil
        self.frequencyCard = nil
        self.uptimeCard = nil
    }

    public override func appear() {
        // the GPU module keeps its process list running while this popup shows the GPU card
        ISGPUShare.shared.watch(self.title, true)
        self.appearedAt = Date()
        self.renderGPU()
        self.renderGPUProcesses()
        self.uptimeCard?.valueField?.stringValue = self.uptimeValue
        self.replay(self.loadCache, render: self.renderLoad)
        self.replay(self.temperatureCache, render: self.renderTemperature)
        self.replay(self.frequencyCache, render: self.renderFrequency)
        self.replay(self.averageCache, render: self.renderAverage)
        self.replay(self.processCache, render: self.renderProcesses)
    }

    public override func disappear() {
        ISGPUShare.shared.watch(self.title, false)
    }
    
    // MARK: - Views

    private func initUsage() -> NSView {
        let theme = ISTheme.current
        let card = ISCard(title: isL("Processor", fr: "Processeur"), value: "")

        let chart = ISBarChart(colors: [theme.blue, theme.pink], height: 60)
        card.add(chart, spacingAfter: 5)
        self.chart = chart

        let legend = ISLegendRow([
            (localizedString("User"), theme.blue),
            (localizedString("System"), theme.pink)
        ])
        card.add(legend)
        self.legend = legend

        self.attachHistory(card)
        self.usageCard = card
        return card
    }

    private func initCores() -> NSView {
        let card = ISCard()
        let count = Int(SystemKit.shared.device.info.cpu?.logicalCores ?? 0)

        let rings = ISCoreRings(count: max(count, 1))
        card.add(rings, spacingAfter: 3)
        self.coreRings = rings

        if SystemKit.shared.device.info.cpu?.pCores != nil {
            let row = ISRow(isL("Performance cores", fr: "Cœurs performants"), color: self.pCoresColor)
            card.add(row)
            self.pCoresRow = row
        }
        if SystemKit.shared.device.info.cpu?.sCores != nil {
            let row = ISRow(localizedString("Super cores"), color: self.sCoresColor)
            card.add(row)
            self.sCoresRow = row
        }
        if SystemKit.shared.device.info.cpu?.eCores != nil {
            let row = ISRow(isL("Efficiency cores", fr: "Cœurs efficaces"), color: self.eCoresColor)
            card.add(row)
            self.eCoresRow = row
        }
        self.attachHistory(card)

        return card
    }

    private func initProcesses() -> NSView {
        let card = ISCard(title: isL("Processes", fr: "Processus"))
        let list = ISProcessList(n: self.numberOfProcesses)
        card.add(list)
        self.processes = list
        return card
    }

    // hidden until the GPU module publishes something (it can be turned off)
    private func initGPU() -> NSView {
        let card = ISCard(title: "GPU", value: "")
        
        let row = ISRingRow(count: 4, diameter: 52, lineWidth: 4.5)
        card.add(row, spacingAfter: 3)
        self.gpuRings = row
        
        let list = ISProcessList(n: 3)
        list.isHidden = true
        card.add(list)
        self.gpuProcesses = list
        
        card.detailID = "gpu"
        card.detail = {
            ISGPUShare.shared.historyDetail()
        }
        card.isHidden = !ISGPUShare.shared.live
        self.gpuCard = card
        return card
    }
    
    private func initAverage() -> NSView {
        let card = ISCard(title: localizedString("Average load"), value: "—")
        self.attachHistory(card)
        self.averageCard = card
        return card
    }

    private func initFrequency() -> NSView {
        let card = ISCard(title: localizedString("Frequency"), value: "—")
        card.isHidden = true
        self.frequencyCard = card
        return card
    }

    private func initUptime() -> NSView {
        let card = ISCard(title: isL("Uptime", fr: "Durée de fonctionnement"), value: self.uptimeValue)
        self.uptimeCard = card
        return card
    }

    // MARK: - History panel

    // the cards about the load share one side panel: history of the usage and of the load averages
    private func attachHistory(_ card: ISCard) {
        card.detailID = "history"
        card.detail = { [weak self] in
            self?.historyDetail() ?? NSView()
        }
    }

    private func historyDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()

        let usage = ISHistoryCard(
            title: isL("Processor", fr: "Processeur"),
            series: self.longHistory,
            style: .stacked,
            colors: [theme.blue, theme.pink],
            dims: [0, 1],
            height: 72,
            scale: 1
        )
        let legend = ISLegendRow([
            (localizedString("User"), theme.blue),
            (localizedString("System"), theme.pink)
        ])
        let average = ISRow(isL("Average", fr: "Moyenne"))
        let peak = ISRow(isL("Peak", fr: "Pic"))
        usage.add(legend)
        usage.add(average)
        usage.add(peak)
        usage.summary = { _, points in
            legend.set(0, points.isAverage(0).map({ isPercent($0) }) ?? "—")
            legend.set(1, points.isAverage(1).map({ isPercent($0) }) ?? "—")
            average.set(points.isAverage(2).map({ isPercent($0) }) ?? "—")
            peak.set(points.isMaximum(2).map({ isPercent(min($0, 1)) }) ?? "—")
        }
        stack.add(usage)

        let colors = [theme.blue, theme.pink, theme.yellow]
        let load = ISHistoryCard(
            title: localizedString("Average load"),
            series: self.averageHistory,
            style: .lines,
            colors: colors,
            dims: [0, 1, 2],
            height: 48
        )
        let rows = [
            ISRow(isL("1 minute", fr: "1 minute"), color: colors[0]),
            ISRow(isL("5 minutes", fr: "5 minutes"), color: colors[1]),
            ISRow(isL("15 minutes", fr: "15 minutes"), color: colors[2])
        ]
        rows.forEach { load.add($0) }
        let loadPeak = ISRow(isL("Peak", fr: "Pic"))
        load.add(loadPeak)
        load.summary = { _, points in
            for (i, row) in rows.enumerated() {
                row.setPlain(points.isAverage(i).map({ isNumber($0, digits: 2) }) ?? "—")
            }
            loadPeak.setPlain(points.isMaximum(0).map({ isNumber($0, digits: 2) }) ?? "—")
        }
        stack.add(load)

        stack.refresh()
        return stack
    }

    // MARK: - Updates

    public func loadCallback(_ value: CPU_Load) {
        self.longHistory.record([value.userLoad, value.systemLoad, value.userLoad + value.systemLoad])
        DispatchQueue.main.async {
            self.loadHistory.append([value.userLoad, value.systemLoad])
        }
        self.apply(value, to: self.loadCache, render: self.renderLoad)
    }

    private func renderLoad(_ value: CPU_Load) {
        // the GPU module was turned off while this popup is open: its card goes away instead of freezing
        if let card = self.gpuCard, !card.isHidden, !ISGPUShare.shared.live {
            card.isHidden = true
            self.resizeToFitContent()
        }
        self.legend?.set(0, isPercent(value.userLoad))
        self.legend?.set(1, isPercent(value.systemLoad))
        self.chart?.set(self.loadHistory.values)

        if let usage = value.usagePCores { self.pCoresRow?.set(isPercent(usage)) }
        if let usage = value.usageSCores { self.sCoresRow?.set(isPercent(usage)) }
        if let usage = value.usageECores { self.eCoresRow?.set(isPercent(usage)) }

        var usagePerCore: [ColorValue] = []
        let cores = SystemKit.shared.device.info.cpu?.cores ?? []
        for i in 0..<value.usagePerCore.count {
            let core = cores.first(where: { $0.id == i })
            let color = core?.type == .efficiency ? self.eCoresColor : core?.type == .super ? self.sCoresColor : self.pCoresColor
            usagePerCore.append(ColorValue(value.usagePerCore[i], color: cores.isEmpty ? ISTheme.current.blue : color))
        }
        self.coreRings?.set(usagePerCore)
    }

    @objc private func gpuUpdated() {
        guard self.contentLoaded else { return }
        // safety net: the content was prepared but the window never came on screen (a toggle received while
        // it was closing). Without this the GPU module would keep its process list running for nobody.
        if self.window?.isVisible != true && Date().timeIntervalSince(self.appearedAt) > 2 {
            ISGPUShare.shared.watch(self.title, false)
            return
        }
        self.renderGPU()
    }
    
    @objc private func gpuProcessesUpdated() {
        guard self.contentLoaded else { return }
        self.renderGPUProcesses()
    }
    
    private func renderGPU() {
        guard let card = self.gpuCard, let snapshot = ISGPUShare.shared.snapshot, ISGPUShare.shared.live else { return }
        card.valueField?.stringValue = snapshot.fps.map { "\(Int($0.rounded())) FPS" } ?? ""
        
        let gauges = Array(snapshot.gauges.prefix(4))
        for (i, ring) in (self.gpuRings?.rings ?? []).enumerated() {
            let hidden = i >= gauges.count
            if ring.isHidden != hidden {
                ring.isHidden = hidden
            }
            guard !hidden else { continue }
            ring.set(value: gauges[i].arc)
            ring.setText(gauges[i].number, unit: gauges[i].unit, caption: gauges[i].caption)
            if ring.toolTip != gauges[i].toolTip {
                ring.toolTip = gauges[i].toolTip
            }
        }
        
        if card.isHidden {
            card.isHidden = false
            self.resizeToFitContent()
        }
    }
    
    private func renderGPUProcesses() {
        guard let list = self.gpuProcesses else { return }
        let processes = ISGPUShare.shared.processes
        let n = min(processes.count, list.count)
        for i in 0..<n {
            let usage = processes[i].usage
            list.set(i, processes[i], [usage < 0.05 ? "0%" : "\(isNumber(usage))%"])
        }
        list.clear(from: n)
        
        if list.isHidden != (n == 0) {
            list.isHidden = n == 0
            self.resizeToFitContent()
        }
    }
    
    public func temperatureCallback(_ value: Double?) {
        self.apply(value, to: self.temperatureCache, render: self.renderTemperature)
    }

    private func renderTemperature(_ value: Double?) {
        self.usageCard?.valueField?.stringValue = value.map { temperature($0) } ?? ""
    }

    public func frequencyCallback(_ value: CPU_Frequency?) {
        self.apply(value, to: self.frequencyCache, render: self.renderFrequency)
    }

    private func renderFrequency(_ value: CPU_Frequency?) {
        guard let card = self.frequencyCard else { return }
        guard let frequency = value?.value else {
            if !card.isHidden {
                card.isHidden = true
                self.resizeToFitContent()
            }
            return
        }
        card.valueField?.attributedStringValue = isValue(isNumber(frequency / 1000, digits: 2), "GHz")
        if card.isHidden {
            card.isHidden = false
            self.resizeToFitContent()
        }
    }

    public func processCallback(_ list: [TopProcess]?) {
        guard let list else { return }
        self.apply(list, to: self.processCache, render: self.renderProcesses)
    }

    private func renderProcesses(_ list: [TopProcess]) {
        guard let processes = self.processes else { return }
        let n = min(list.count, processes.count)
        for i in 0..<n {
            let usage = list[i].usage
            processes.set(i, list[i], [usage < 0.05 ? "0%" : "\(isNumber(usage))%"])
        }
        processes.clear(from: n)
    }

    public func numberOfProcessesUpdated() {
        DispatchQueue.main.async {
            guard self.contentLoaded, self.processes?.count != self.numberOfProcesses else { return }
            self.releaseContent()
            self.processCache.initialized = false
            self.prepareForDisplay()
        }
    }

    public func limitCallback(_ value: CPU_Limit?) {}

    public func averageCallback(_ value: CPU_AverageLoad?) {
        guard let value else { return }
        self.averageHistory.record([value.load1, value.load5, value.load15])
        self.apply(value, to: self.averageCache, render: self.renderAverage)
    }

    private func renderAverage(_ value: CPU_AverageLoad) {
        // two decimals like iStat, one when the numbers get too long to fit next to the title
        let loads = [value.load1, value.load5, value.load15]
        let digits = loads.contains(where: { $0 >= 10 }) ? 1 : 2
        self.averageCard?.valueField?.stringValue = loads.map({ isNumber($0, digits: digits) }).joined(separator: " ")
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
