//
//  popup.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 18/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    private var pressureRing: ISRing? = nil
    private var memoryRing: ISRing? = nil
    
    private var appRow: ISRow? = nil
    private var wiredRow: ISRow? = nil
    private var compressedRow: ISRow? = nil
    private var freeRow: ISRow? = nil
    
    private var processes: ISProcessList? = nil
    
    private var swapInRow: ISRow? = nil
    private var swapOutRow: ISRow? = nil
    private var swapCard: ISCard? = nil
    private var swapBar: ISProgressBar? = nil
    
    private let processesCache = PopupCache<[TopProcess]>()
    private let loadCache = PopupCache<RAM_Usage>()
    // [app, wired, compressed, pressure 0...1, swap used], kept up to 30 days for the side panel
    private let longHistory = ISHistoryStore.shared.series("ram.usage", dimensions: 5)
    
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 5)
    }
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 254, height: 0))
        
        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadContent() {
        self.addSection(self.initRings())
        self.addSection(self.initDetails())
        if self.numberOfProcesses > 0 {
            self.addSection(self.initProcesses())
        }
        self.addSection(self.initPages())
        self.addSection(self.initSwap())
        self.addSection(ISShortcutBar(module: .RAM, extra: [ISShortcut.app("com.apple.SystemProfiler")]))
        
        self.resizeToFitContent()
    }
    
    public override func unloadContent() {
        self.pressureRing = nil
        self.memoryRing = nil
        self.appRow = nil
        self.wiredRow = nil
        self.compressedRow = nil
        self.freeRow = nil
        self.processes = nil
        self.swapInRow = nil
        self.swapOutRow = nil
        self.swapCard = nil
        self.swapBar = nil
    }
    
    public override func appear() {
        self.replay(self.loadCache, render: self.renderLoad)
        self.replay(self.processesCache, render: self.renderProcesses)
    }
    
    // MARK: - Views
    
    private func initRings() -> NSView {
        let card = ISCard()
        let row = ISRingRow(count: 2, diameter: 96, lineWidth: 7, vertical: 2)
        card.add(row)
        card.edgeInsets = NSEdgeInsets(top: ISMetrics.padV, left: 16, bottom: ISMetrics.padV, right: 16)
        
        self.pressureRing = row.rings[0]
        self.memoryRing = row.rings[1]
        self.pressureRing?.setText("—", caption: isL("Pressure", fr: "Pression"))
        self.memoryRing?.setText("—", caption: localizedString("Memory"))
        self.attachHistory(card)
        
        return card
    }
    
    private func initDetails() -> NSView {
        let theme = ISTheme.current
        let card = ISCard()
        
        let app = ISRow("App", color: theme.blue)
        let wired = ISRow(isL("Wired", fr: "Résidente"), color: theme.pink)
        let compressed = ISRow(isL("Compressed", fr: "Compressé"), color: theme.yellow)
        let free = ISRow(isL("Available", fr: "Disponible"), color: theme.track)
        [app, wired, compressed, free].forEach { card.add($0) }
        
        self.appRow = app
        self.wiredRow = wired
        self.compressedRow = compressed
        self.freeRow = free
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
    
    private func initPages() -> NSView {
        let card = ISCard()
        let ins = ISRow(isL("Swap ins", fr: "Pages entrantes"))
        let outs = ISRow(isL("Swap outs", fr: "Pages sortantes"))
        card.add(ins)
        card.add(outs)
        self.swapInRow = ins
        self.swapOutRow = outs
        return card
    }
    
    private func initSwap() -> NSView {
        let card = ISCard(title: isL("Swap", fr: "Fichier d’échange"), value: "—")
        let bar = ISProgressBar()
        card.add(bar)
        card.setCustomSpacing(3, after: card.arrangedSubviews[0])
        card.edgeInsets.bottom = ISMetrics.padV + 2
        self.swapCard = card
        self.swapBar = bar
        return card
    }
    
    // MARK: - History panel

    // the rings and the breakdown share one side panel: memory, pressure and swap over time
    private func attachHistory(_ card: ISCard) {
        card.detailID = "history"
        card.detail = { [weak self] in
            self?.historyDetail() ?? NSView()
        }
    }

    private func pressure(_ value: RAM_Usage) -> Double {
        value.pressure.percentage.map { Double($0) / 100 } ?? (Double(value.pressure.value.number()) / 3)
    }

    private func historyDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()
        let total = max(self.loadCache.value?.total ?? Double(ProcessInfo.processInfo.physicalMemory), 1)

        let memory = ISHistoryCard(
            title: localizedString("Memory"),
            series: self.longHistory,
            style: .stacked,
            colors: [theme.blue, theme.pink, theme.yellow],
            dims: [0, 1, 2],
            height: 72,
            scale: total
        )
        let rows = [
            ISRow("App", color: theme.blue),
            ISRow(isL("Wired", fr: "Résidente"), color: theme.pink),
            ISRow(isL("Compressed", fr: "Compressé"), color: theme.yellow)
        ]
        rows.forEach { memory.add($0) }
        memory.summary = { [weak self] card, points in
            guard let self else { return }
            var used: Double = 0
            for (i, row) in rows.enumerated() {
                let value = points.isAverage(i)
                used += value ?? 0
                row.set(value.map({ self.memory($0) }) ?? "—")
            }
            card.valueField?.attributedStringValue = points.isAverage(0) == nil ? NSAttributedString(string: "") : isValue(split: isPercent(used / total))
        }
        stack.add(memory)

        let pressure = ISHistoryCard(
            title: isL("Pressure", fr: "Pression"),
            series: self.longHistory,
            style: .stacked,
            colors: [theme.blue],
            dims: [3],
            height: 40,
            scale: 1
        )
        let pressureAverage = ISRow(isL("Average", fr: "Moyenne"))
        let pressurePeak = ISRow(isL("Peak", fr: "Pic"))
        pressure.add(pressureAverage)
        pressure.add(pressurePeak)
        pressure.summary = { _, points in
            pressureAverage.set(points.isAverage(3).map({ isPercent($0) }) ?? "—")
            pressurePeak.set(points.isMaximum(3).map({ isPercent(min($0, 1)) }) ?? "—")
        }
        stack.add(pressure)

        let swap = ISHistoryCard(
            title: isL("Swap", fr: "Fichier d’échange"),
            series: self.longHistory,
            style: .stacked,
            colors: [theme.pink],
            dims: [4],
            height: 40
        )
        let swapAverage = ISRow(isL("Average", fr: "Moyenne"))
        let swapPeak = ISRow(isL("Peak", fr: "Pic"))
        swap.add(swapAverage)
        swap.add(swapPeak)
        swap.summary = { [weak self] _, points in
            guard let self else { return }
            swapAverage.set(points.isAverage(4).map({ self.memory($0) }) ?? "—")
            swapPeak.set(points.isMaximum(4).map({ self.memory($0) }) ?? "—")
        }
        stack.add(swap)

        stack.refresh()
        return stack
    }

    // MARK: - Updates
    
    private func memory(_ value: Double) -> String {
        Units(bytes: Int64(max(0, value))).getReadableMemory(style: .memory)
    }
    
    public func loadCallback(_ value: RAM_Usage) {
        self.longHistory.record([value.app, value.wired, value.compressed, self.pressure(value), value.swap.used])
        self.apply(value, to: self.loadCache, render: self.renderLoad)
    }
    
    private func renderLoad(_ value: RAM_Usage) {
        let theme = ISTheme.current
        let total = max(value.total, 1)
        
        self.appRow?.set(self.memory(value.app))
        self.wiredRow?.set(self.memory(value.wired))
        self.compressedRow?.set(self.memory(value.compressed))
        self.freeRow?.set(self.memory(value.total - value.app - value.wired - value.compressed))
        
        self.memoryRing?.set([
            ISRingSegment(value.app / total, theme.blue),
            ISRingSegment(value.wired / total, theme.pink),
            ISRingSegment(value.compressed / total, theme.yellow)
        ])
        self.memoryRing?.setText("\(Int((value.usage * 100).rounded()))", unit: "%", caption: localizedString("Memory"))
        
        let pressure: Double = self.pressure(value)
        let pressureColor: NSColor = value.pressure.value == .critical ? theme.red : (value.pressure.value == .warning ? theme.yellow : theme.blue)
        self.pressureRing?.set(value: pressure, color: pressureColor)
        self.pressureRing?.setText("\(Int((pressure * 100).rounded()))", unit: "%", caption: isL("Pressure", fr: "Pression"))
        
        self.swapInRow?.setPlain(NumberFormatter.localizedString(from: NSNumber(value: value.swapins), number: .decimal))
        self.swapOutRow?.setPlain(NumberFormatter.localizedString(from: NSNumber(value: value.swapouts), number: .decimal))
        
        if value.swap.total > 0 {
            self.swapCard?.valueField?.attributedStringValue = {
                let text = NSMutableAttributedString(attributedString: isValue(split: self.memory(value.swap.used)))
                text.append(isValue("/"))
                text.append(isValue(split: self.memory(value.swap.total)))
                return text
            }()
            self.swapBar?.set(value.swap.used / value.swap.total)
        } else {
            self.swapCard?.valueField?.attributedStringValue = isValue(split: self.memory(value.swap.used))
            self.swapBar?.set(0)
        }
    }
    
    public func processCallback(_ list: [TopProcess]) {
        self.apply(list, to: self.processesCache, render: self.renderProcesses)
    }
    
    private func renderProcesses(_ list: [TopProcess]) {
        guard let processes = self.processes else { return }
        let n = min(list.count, processes.count)
        for i in 0..<n {
            processes.set(i, list[i], [self.memory(list[i].usage)])
        }
        processes.clear(from: n)
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
