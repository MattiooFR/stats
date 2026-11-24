//
//  istatGPU.swift
//  Kit
//
//  iStat Menus shows the GPU inside the CPU menu. The GPU module publishes its readings here so
//  another popup can show them, and its popup readers keep running while that popup is open.
//

import Cocoa

public extension Notification.Name {
    // userInfo: "module" (name) and "state" (Bool): another popup starts or stops showing the readings of that module
    static let externalPopupConsumer = Notification.Name("externalPopupConsumer")
}

// one ring of the GPU card
public struct ISGPUGauge {
    public let caption: String
    public let toolTip: String
    public let arc: Double
    public let number: String
    public let unit: String
}

public struct ISGPUSnapshot {
    public var utilization: Double?
    // share of the memory the GPU may use (0...1), and the bytes in use
    public var memory: Double?
    public var memoryBytes: Double?
    // degrees Celsius
    public var temperature: Double?
    public var ane: Double?
    public var render: Double?
    public var tiler: Double?
    public var fps: Double?
    public var date: Date

    public init(
        utilization: Double? = nil,
        memory: Double? = nil,
        memoryBytes: Double? = nil,
        temperature: Double? = nil,
        ane: Double? = nil,
        render: Double? = nil,
        tiler: Double? = nil,
        fps: Double? = nil,
        date: Date = Date()
    ) {
        self.utilization = utilization
        self.memory = memory
        self.memoryBytes = memoryBytes
        self.temperature = temperature
        self.ane = ane
        self.render = render
        self.tiler = tiler
        self.fps = fps
        self.date = date
    }

    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))"
    }

    // the rings that have a value, the most useful first
    public var gauges: [ISGPUGauge] {
        var list: [ISGPUGauge] = []
        if let v = self.utilization {
            list.append(ISGPUGauge(caption: "GPU", toolTip: localizedString("GPU utilization"), arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.memory {
            list.append(ISGPUGauge(caption: "MEM", toolTip: localizedString("Memory usage"), arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.temperature {
            let local = Measurement(value: v, unit: UnitTemperature.celsius).converted(to: UnitTemperature.current).value
            // the degree sign stays at the size of the digits (as a small unit it is hardly readable)
            list.append(ISGPUGauge(caption: "TMP", toolTip: localizedString("Temperature"), arc: v / 100, number: "\(Int(local.rounded()))°", unit: ""))
        }
        if let v = self.ane {
            list.append(ISGPUGauge(caption: "ANE", toolTip: localizedString("ANE utilization"), arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.render {
            list.append(ISGPUGauge(caption: isL("RENDER", fr: "RENDU"), toolTip: localizedString("Renderer utilization"), arc: v, number: self.percent(v), unit: "%"))
        }
        if let v = self.tiler {
            list.append(ISGPUGauge(caption: "TILER", toolTip: localizedString("Tiler utilization"), arc: v, number: self.percent(v), unit: "%"))
        }
        return list
    }
}

public final class ISGPUShare {
    public static let shared = ISGPUShare()

    // posted on the main thread
    public static let updated = Notification.Name("ISGPUShareUpdated")
    public static let processesUpdated = Notification.Name("ISGPUShareProcessesUpdated")

    // [utilization, renderer, tiler, memory in bytes, frames per second] and the temperature, kept up to 30 days
    public let usageHistory: ISSeries = ISHistoryStore.shared.series("gpu.usage", dimensions: 5)
    public let temperatureHistory: ISSeries = ISHistoryStore.shared.series("gpu.temperature", dimensions: 1)

    private let lock = NSLock()
    private var _snapshot: ISGPUSnapshot?
    private var _processes: [TopProcess] = []
    private var processesDate: Date = .distantPast
    private var watchers: Set<String> = []

    private init() {}

    public var snapshot: ISGPUSnapshot? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._snapshot
    }

    // the GPU process reader only runs while a popup shows the GPU: a list left from an earlier opening
    // (it can be hours old) is not handed out as if it were current
    public var processes: [TopProcess] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Date().timeIntervalSince(self.processesDate) < 30 ? self._processes : []
    }

    // a popup other than the GPU one is showing the GPU right now
    public var watched: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return !self.watchers.isEmpty
    }

    // the GPU module is running: it published something in the last two minutes
    public var live: Bool {
        guard let snapshot = self.snapshot else { return false }
        return Date().timeIntervalSince(snapshot.date) < 120
    }

    public func publish(_ snapshot: ISGPUSnapshot) {
        self.lock.lock()
        self._snapshot = snapshot
        self.lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ISGPUShare.updated, object: nil)
        }
    }

    public func publish(processes: [TopProcess]) {
        self.lock.lock()
        self._processes = processes
        self.processesDate = Date()
        self.lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ISGPUShare.processesUpdated, object: nil)
        }
    }

    // called on the main thread by a popup that shows the GPU, when it opens and when it closes:
    // the popup readers of the GPU module (processes) run meanwhile
    public func watch(_ owner: String, _ state: Bool) {
        self.lock.lock()
        let before = !self.watchers.isEmpty
        if state {
            self.watchers.insert(owner)
        } else {
            self.watchers.remove(owner)
        }
        let after = !self.watchers.isEmpty
        self.lock.unlock()

        guard before != after else { return }
        NotificationCenter.default.post(name: .externalPopupConsumer, object: nil, userInfo: [
            "module": ModuleType.GPU.stringValue,
            "state": after
        ])
    }

    private func bytes(_ value: Double) -> String {
        Units(bytes: Int64(max(0, value))).getReadableMemory(style: .memory)
    }

    // the history side panel: utilization, renderer and tiler, memory and temperature over time
    public func historyDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()
        let current = self.snapshot

        let usage = ISHistoryCard(
            title: isL("GPU utilization", fr: "Utilisation du GPU"),
            series: self.usageHistory,
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

        if current?.render != nil || current?.tiler != nil {
            let stages = ISHistoryCard(
                title: isL("Renderer and tiler", fr: "Rendu et tiler"),
                series: self.usageHistory,
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

        if current?.memoryBytes != nil {
            // scaled to the highest value on screen: against the whole unified memory the bars would stay flat
            let memory = ISHistoryCard(
                title: localizedString("Memory"),
                series: self.usageHistory,
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

        if current?.temperature != nil {
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
}
