//
//  popup.swift
//  Disk
//
//  Created by Serhiy Mytrovtsiy on 11/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class Popup: PopupWrapper {
    // (read, write) per tick, summed over all the disks, drawn as a mirror chart
    private let activityHistory = ISHistory<(Double, Double)>(capacity: 160)
    
    // cards that depend on the list of mounted volumes, always at the top of the popup
    private var volumeSections: [NSView] = []
    private var volumeSignature: [String] = []
    private var diskCards: [DiskCard] = []
    private var networkRows: [DiskVolumeRow] = []
    private var removableRows: [DiskVolumeRow] = []
    
    private var readValue: ISBigValue? = nil
    private var writeValue: ISBigValue? = nil
    private var chart: ISMirrorChart? = nil
    private var peaks: DiskPeakRow? = nil
    private var processes: ISProcessList? = nil
    
    private let processesCache = PopupCache<[Disk_process]>()
    private let activityCache = PopupCache<DiskActivity>()
    
    private var capacity: Disks?
    private var smartValues: [String: smart_t] = [:]
    // network volumes are not known by the readers (no BSD name, mounted outside of /Volumes)
    private var remoteVolumes: [DiskVolume] = []
    private var remoteRefreshing: Bool = false
    
    private var settingsLoaded: Bool = false
    private let settingsSection = PreferencesSection(title: localizedString("Drives"))
    private var lastList: [String] = []
    
    // not used by the popup anymore, still read by the widgets, the portal and the preview
    private var mainColorState: SColor = .secondBlue
    private var readColorState: SColor = .secondBlue
    private var writeColorState: SColor = .secondRed
    private var reverseOrderState: Bool = false
    
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.title)_base", defaultValue: DataSizeBase.byte.rawValue)) ?? .byte
    }
    private var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(self.title)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 5)
    }
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 285, height: 0))
        
        self.mainColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_mainColor", defaultValue: self.mainColorState.key))
        self.readColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_readColor", defaultValue: self.readColorState.key))
        self.writeColorState = SColor.fromString(Store.shared.string(key: "\(self.title)_writeColor", defaultValue: self.writeColorState.key))
        self.reverseOrderState = Store.shared.bool(key: "\(self.title)_reverseOrder", defaultValue: self.reverseOrderState)
        
        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func loadContent() {
        self.addSection(self.initActivity())
        if self.numberOfProcesses > 0 {
            self.addSection(self.initProcesses())
        }
        self.addSection(ISShortcutBar(module: .disk, extra: [ISShortcut.app("com.apple.DiskUtility")]))
        
        // the disk cards are inserted above, they follow what is mounted
        self.refreshRemoteVolumes()
        self.renderVolumes()
        
        self.resizeToFitContent()
    }
    
    public override func unloadContent() {
        self.volumeSections = []
        self.volumeSignature = []
        self.diskCards = []
        self.networkRows = []
        self.removableRows = []
        self.readValue = nil
        self.writeValue = nil
        self.chart = nil
        self.peaks = nil
        self.processes = nil
    }
    
    public override func appear() {
        guard self.contentLoaded else { return }
        self.renderVolumes()
        self.replay(self.activityCache, render: self.renderActivity)
        self.replay(self.processesCache, render: self.renderProcesses)
    }
    
    // MARK: - Views
    
    private func initActivity() -> NSView {
        let theme = ISTheme.current
        let card = ISCard()
        
        let read = ISBigValue(caption: localizedString("Read"), color: theme.pink)
        let write = ISBigValue(caption: localizedString("Write"), color: theme.blue)
        let values = NSView()
        values.translatesAutoresizingMaskIntoConstraints = false
        values.addSubview(read)
        values.addSubview(write)
        NSLayoutConstraint.activate([
            read.leadingAnchor.constraint(equalTo: values.leadingAnchor),
            read.topAnchor.constraint(equalTo: values.topAnchor),
            read.bottomAnchor.constraint(equalTo: values.bottomAnchor),
            read.widthAnchor.constraint(equalTo: values.widthAnchor, multiplier: 0.5),
            write.trailingAnchor.constraint(equalTo: values.trailingAnchor),
            write.topAnchor.constraint(equalTo: values.topAnchor),
            write.bottomAnchor.constraint(equalTo: values.bottomAnchor),
            write.widthAnchor.constraint(equalTo: read.widthAnchor)
        ])
        card.add(values, spacingAfter: 4)
        self.readValue = read
        self.writeValue = write
        
        let chart = ISMirrorChart(up: theme.pink, down: theme.blue, height: 60)
        card.add(chart, spacingAfter: 2)
        self.chart = chart
        
        let peaks = DiskPeakRow(read: localizedString("Read"), write: localizedString("Write"))
        card.add(peaks)
        self.peaks = peaks
        
        return card
    }
    
    private func initProcesses() -> NSView {
        let width: CGFloat = 60
        let card = ISCard(title: isL("Processes", fr: "Processus"))
        card.setHeaderColumns(["R", "W"], width: width)
        let list = ISProcessList(n: self.numberOfProcesses, columns: 2, columnWidth: width)
        card.add(list)
        self.processes = list
        return card
    }
    
    private func initVolumes(_ title: String, _ volumes: [DiskVolume]) -> (ISCard, [DiskVolumeRow]) {
        let card = ISCard(title: title)
        let rows = volumes.map { DiskVolumeRow($0) }
        rows.forEach { card.add($0) }
        return (card, rows)
    }
    
    // MARK: - Volumes
    
    private func volumeState(_ id: String) -> Bool {
        Store.shared.bool(key: "\(self.title)_\(id)_popup", defaultValue: true)
    }
    
    // main disks get a card with a ring, network and removable volumes a row with a bar
    private func volumeLayout() -> (disks: [drive], network: [DiskVolume], removable: [DiskVolume]) {
        var disks: [drive] = []
        var removable: [DiskVolume] = []
        let known = self.capacity?.array ?? []
        
        known.filter({ $0.popupState }).forEach { d in
            if !d.root && (d.removable || d.connectionType == "Disk Image") {
                removable.append(DiskVolume(d))
            } else {
                disks.append(d)
            }
        }
        let paths = Set(known.compactMap { $0.path?.path })
        let network = self.remoteVolumes.filter { v in
            self.volumeState(v.id) && !paths.contains(v.path?.path ?? "")
        }
        
        return (disks, network, removable)
    }
    
    private func renderVolumes() {
        guard self.contentLoaded else { return }
        let layout = self.volumeLayout()
        let signature = layout.disks.map({ "disk:\($0.uuid)" }) + layout.network.map({ "network:\($0.id)" }) + layout.removable.map({ "removable:\($0.id)" })
        
        var rebuilt = false
        if signature != self.volumeSignature {
            self.volumeSections.forEach { view in
                self.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            self.diskCards = layout.disks.map { DiskCard($0) }
            var sections: [NSView] = self.diskCards
            if layout.network.isEmpty {
                self.networkRows = []
            } else {
                let (card, rows) = self.initVolumes(isL("Network disks", fr: "Disque réseau"), layout.network)
                sections.append(card)
                self.networkRows = rows
            }
            if layout.removable.isEmpty {
                self.removableRows = []
            } else {
                let (card, rows) = self.initVolumes(isL("Removable volumes", fr: "Volumes amovibles"), layout.removable)
                sections.append(card)
                self.removableRows = rows
            }
            sections.enumerated().forEach { self.addSection($0.element, at: $0.offset) }
            self.volumeSections = sections
            self.volumeSignature = signature
            rebuilt = true
        }
        
        zip(self.diskCards, layout.disks).forEach { $0.update($1, toolTip: self.details($1)) }
        zip(self.networkRows, layout.network).forEach { $0.update($1) }
        zip(self.removableRows, layout.removable).forEach { $0.update($1) }
        if let activity = self.activityCache.value {
            self.renderDots(activity)
        }
        
        if rebuilt {
            self.resizeToFitContent()
        }
    }
    
    private func details(_ d: drive) -> String {
        let colon = isL(":", fr: " :")
        let unknown = localizedString("Unknown")
        var lines: [String] = [
            d.mediaName,
            localizedString("Free disk memory", diskSize(d.free), diskSize(d.size)),
            "\(localizedString("File system"))\(colon) \(d.fileSystem.isEmpty ? unknown : d.fileSystem.uppercased())",
            "\(localizedString("Connection type"))\(colon) \(d.connectionType.isEmpty ? unknown : d.connectionType)"
        ]
        
        if let activity = self.activityCache.value?.drives[d.uuid], activity.readBytes != 0 || activity.writeBytes != 0 {
            lines.append("\(localizedString("Total read"))\(colon) \(diskSize(activity.readBytes))")
            lines.append("\(localizedString("Total written"))\(colon) \(diskSize(activity.writeBytes))")
        }
        
        if let smart = self.smartValues[d.uuid] {
            lines.append("")
            lines.append("SMART")
            lines.append("\(localizedString("Temperature"))\(colon) \(temperature(Double(smart.temperature)))")
            lines.append("\(localizedString("Health"))\(colon) \(smart.life)%")
            lines.append("\(localizedString("Total read"))\(colon) \(diskSize(smart.totalRead))")
            lines.append("\(localizedString("Total written"))\(colon) \(diskSize(smart.totalWritten))")
            lines.append("\(localizedString("Power cycles"))\(colon) \(smart.powerCycles)")
            lines.append("\(localizedString("Power on hours"))\(colon) \(smart.powerOnHours)")
            if let warning = smart.criticalWarning {
                let list = smartCriticalWarnings(warning)
                lines.append("\(localizedString("Critical warning"))\(colon) \(list.isEmpty ? localizedString("None") : list.joined(separator: ", "))")
            }
            if let spare = smart.availableSpare {
                var line = "\(localizedString("Available spare"))\(colon) \(spare)%"
                if let threshold = smart.spareThreshold {
                    line += " (\(localizedString("Threshold"))\(colon) \(threshold)%)"
                }
                lines.append(line)
            }
        }
        
        return lines.joined(separator: "\n")
    }
    
    // lists the network volumes without waiting for them, then asks each one for fresh numbers in the background
    private func refreshRemoteVolumes() {
        // nothing shows them while the popup and its settings are closed: no listing at every tick
        guard self.contentLoaded || self.settingsLoaded else { return }
        self.remoteVolumes = DiskVolume.remote()
        guard self.contentLoaded, !self.remoteRefreshing, !self.remoteVolumes.isEmpty else { return }
        
        self.remoteRefreshing = true
        let paths = self.remoteVolumes.compactMap { $0.path?.path }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // the kernel keeps the answer and the next listing reads it; a server that does not answer only blocks this task
            paths.forEach { path in
                var stat = statfs()
                _ = statfs(path, &stat)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteRefreshing = false
                self.remoteVolumes = DiskVolume.remote()
                self.renderVolumes()
            }
        }
    }
    
    // MARK: - Callbacks
    
    internal func capacityCallback(_ value: Disks) {
        self.capacity = value
        self.refreshRemoteVolumes()
        if self.settingsLoaded { self.updateSettings() }
        self.renderVolumes()
    }
    
    internal func activityCallback(_ value: Disks) {
        var activity = DiskActivity()
        var counted: Set<String> = []
        value.array.forEach { d in
            activity.drives[d.uuid] = d.activity
            // the volumes of one physical disk report the same counters: count them once
            let counters = "\(d.activity.readBytes):\(d.activity.writeBytes)"
            if d.activity.readBytes != 0 || d.activity.writeBytes != 0, !counted.insert(counters).inserted { return }
            activity.read += Double(d.activity.read)
            activity.write += Double(d.activity.write)
        }
        
        DispatchQueue.main.async {
            self.activityHistory.append((activity.read, activity.write))
        }
        self.apply(activity, to: self.activityCache, render: self.renderActivity)
    }
    
    private func renderActivity(_ value: DiskActivity) {
        let read = self.speed(value.read)
        let write = self.speed(value.write)
        self.readValue?.set("\(read.0) \(read.1)")
        self.writeValue?.set("\(write.0) \(write.1)")
        
        let history = self.activityHistory.values
        if let chart = self.chart {
            chart.set(history)
            // peaks of what the chart shows
            let width = chart.bounds.width > 0 ? chart.bounds.width : self.frame.width - (ISMetrics.padH * 2)
            let visible = history.suffix(max(1, Int(width / (chart.barWidth + chart.gap))))
            self.peaks?.set(
                read: self.speed(visible.map({ $0.0 }).max() ?? 0),
                write: self.speed(visible.map({ $0.1 }).max() ?? 0)
            )
        }
        
        self.renderDots(value)
    }
    
    private func renderDots(_ value: DiskActivity) {
        self.diskCards.forEach { card in
            let activity = value.drives[card.uuid]
            card.setActivity(read: (activity?.read ?? 0) > 0, write: (activity?.write ?? 0) > 0)
        }
    }
    
    internal func smartCallback(_ value: Disks) {
        value.forEach { (d: drive) in
            if let smart = d.smart {
                self.smartValues[d.uuid] = smart
            }
        }
        // SMART values are shown in the tooltip of the disk cards
        self.renderVolumes()
    }
    
    internal func processCallback(_ list: [Disk_process]) {
        self.apply(list, to: self.processesCache, render: self.renderProcesses)
    }
    
    private func renderProcesses(_ list: [Disk_process]) {
        guard let processes = self.processes else { return }
        let multiplier: Double = self.base == .bit ? 8 : 1
        let n = min(list.count, processes.count)
        for i in 0..<n {
            processes.set(i, list[i], [
                diskCompact(Double(list[i].read) * multiplier),
                diskCompact(Double(list[i].write) * multiplier)
            ])
        }
        processes.clear(from: n)
    }
    
    internal func numberOfProcessesUpdated() {
        DispatchQueue.main.async {
            guard self.contentLoaded, self.processes?.count != self.numberOfProcesses else { return }
            self.releaseContent()
            self.processesCache.initialized = false
            self.activityCache.initialized = false
            self.prepareForDisplay()
        }
    }
    
    // "3,6" + "Mo/s"; the base and the unit chosen in the module settings are kept
    private func speed(_ bytes: Double) -> (String, String) {
        let base = self.base
        let unit = self.speedUnit
        if base == .byte && unit == NetworkSpeedUnitAuto {
            let value = diskUnits(bytes)
            return (value.0, "\(value.1)/s")
        }
        let value = Units(bytes: Int64(min(max(bytes, 0), 9e18))).getReadableTuple(base: base, unit: unit)
        return (value.0.replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? "."), value.1)
    }
    
    // MARK: - Settings
    
    public override func settings() -> NSView? {
        self.settingsLoaded = true
        self.remoteVolumes = DiskVolume.remote()
        if self.capacity != nil { self.updateSettings() }
        let view = SettingsContainerView()
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Keyboard shortcut"), component: KeyboardShartcutView(
                callback: self.setKeyboardShortcut,
                value: self.keyboardShortcut
            ))
        ]))
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Main color"), component: self.colorSelectView(
                action: #selector(self.toggleMainColor),
                items: SColor.allColors.filter({ $0 != .monochrome }),
                selected: self.mainColorState.key
            )),
            PreferencesRow(localizedString("Write color"), component: self.colorSelectView(
                action: #selector(self.toggleWriteColor),
                items: SColor.allColors,
                selected: self.writeColorState.key
            )),
            PreferencesRow(localizedString("Read color"), component: self.colorSelectView(
                action: #selector(self.toggleReadColor),
                items: SColor.allColors,
                selected: self.readColorState.key
            ))
        ]))
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Reverse order"), component: self.switchView(
                action: #selector(self.toggleReverseOrder),
                state: self.reverseOrderState
            ))
        ]))
        
        let empty = NSView()
        empty.identifier = NSUserInterfaceItemIdentifier("empty_view")
        self.settingsSection.add(empty)
        view.addArrangedSubview(self.settingsSection)
        
        return view
    }
    
    // one switch per volume the popup can show
    private func updateSettings() {
        if self.settingsSection.contains("empty_view") {
            self.settingsSection.delete("empty_view")
        }
        
        var entries: [(id: String, name: String, state: Bool)] = (self.capacity?.array ?? []).map { ($0.uuid, $0.mediaName, $0.popupState) }
        entries += self.remoteVolumes.map { ($0.id, $0.name, self.volumeState($0.id)) }
        
        self.lastList.filter { id in !entries.contains(where: { $0.id == id }) }.forEach { self.settingsSection.delete($0) }
        entries.forEach { entry in
            if !self.settingsSection.contains(entry.id) {
                let btn = self.switchView(
                    action: #selector(self.toggleDisk),
                    state: entry.state
                )
                btn.identifier = NSUserInterfaceItemIdentifier(entry.id)
                self.settingsSection.add(PreferencesRow(entry.name, id: entry.id, component: btn))
            }
        }
        
        self.lastList = entries.map { $0.id }
    }
    
    @objc private func toggleMainColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.mainColorState = SColor.fromString(key, defaultValue: self.mainColorState)
        Store.shared.set(key: "\(self.title)_mainColor", value: self.mainColorState.key)
    }
    @objc private func toggleWriteColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.writeColorState = SColor.fromString(key, defaultValue: self.writeColorState)
        Store.shared.set(key: "\(self.title)_writeColor", value: self.writeColorState.key)
    }
    @objc private func toggleReadColor(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        self.readColorState = SColor.fromString(key, defaultValue: self.readColorState)
        Store.shared.set(key: "\(self.title)_readColor", value: self.readColorState.key)
    }
    @objc private func toggleReverseOrder(_ sender: NSControl) {
        self.reverseOrderState = controlState(sender)
        Store.shared.set(key: "\(self.title)_reverseOrder", value: self.reverseOrderState)
    }
    @objc private func toggleDisk(_ sender: NSControl) {
        guard let id = sender.identifier else { return }
        Store.shared.set(key: "\(self.title)_\(id.rawValue)_popup", value: controlState(sender))
        self.renderVolumes()
    }
}

// MARK: - Data

private struct DiskActivity {
    var read: Double = 0
    var write: Double = 0
    // by uuid
    var drives: [String: stats] = [:]
}

// a volume shown as a row with a usage bar
private struct DiskVolume {
    let id: String
    let name: String
    let path: URL?
    let size: Int64
    let free: Int64
    
    var used: Double {
        self.size > 0 ? Double(max(0, self.size - self.free)) / Double(self.size) : 0
    }
    var toolTip: String {
        localizedString("Free disk memory", diskSize(self.free), diskSize(self.size))
    }
    
    init(_ d: drive) {
        self.id = d.uuid
        self.name = d.mediaName
        self.path = d.path
        self.size = d.size
        self.free = d.free
    }
    
    init(id: String, name: String, path: URL?, size: Int64, free: Int64) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.free = free
    }
    
    // mounted network file systems, the ones the Finder shows. Reads what the kernel already knows: never waits for a server.
    static func remote() -> [DiskVolume] {
        let mounted = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard mounted >= 1 else { return [] }
        let template = statfs()
        var buffer = Array(repeating: template, count: mounted + 4)
        let n = Int(getfsstat(&buffer, Int32(MemoryLayout.stride(ofValue: template) * buffer.count), MNT_NOWAIT))
        guard n >= 1 else { return [] }
        
        var list: [DiskVolume] = []
        for var stat in buffer.prefix(n) {
            let flags = Int32(bitPattern: stat.f_flags)
            guard flags & MNT_LOCAL == 0, flags & MNT_DONTBROWSE == 0, stat.f_blocks > 0 else { continue }
            
            let path = withUnsafePointer(to: &stat.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, name != "/" else { continue }
            
            let blockSize = Int64(stat.f_bsize)
            let (size, sizeOverflow) = Int64(clamping: stat.f_blocks).multipliedReportingOverflow(by: blockSize)
            let (free, freeOverflow) = Int64(clamping: stat.f_bavail).multipliedReportingOverflow(by: blockSize)
            guard !sizeOverflow, !freeOverflow, size > 0 else { continue }
            
            list.append(DiskVolume(
                id: "network:\(path)",
                name: name,
                path: URL(fileURLWithPath: path, isDirectory: true),
                size: size,
                free: min(free, size)
            ))
        }
        
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Formatting

// "616,2" + "Go": three to four digits, decimal units like the Finder
private func diskUnits(_ bytes: Double) -> (String, String) {
    let value = max(0, bytes)
    if value < 999_500 {
        return ("\(Int((value / 1_000).rounded()))", isL("KB", fr: "Ko"))
    } else if value < 999_950_000 {
        let v = value / 1_000_000
        return (isNumber(v, digits: v < 99.95 ? 1 : 0), isL("MB", fr: "Mo"))
    } else if value < 999_950_000_000 {
        let v = value / 1_000_000_000
        return (isNumber(v, digits: v < 9.995 ? 2 : 1), isL("GB", fr: "Go"))
    }
    return (isNumber(value / 1_000_000_000_000, digits: 2), isL("TB", fr: "To"))
}

private func diskSize(_ bytes: Int64) -> String {
    let value = diskUnits(Double(bytes))
    return "\(value.0) \(value.1)"
}

// process columns: "2K", "8,8M", "-" when there is nothing to show
private func diskCompact(_ bytes: Double) -> String {
    if bytes < 500 {
        return "-"
    } else if bytes < 999_500 {
        return "\(Int((bytes / 1_000).rounded()))K"
    } else if bytes < 999_950_000 {
        let v = bytes / 1_000_000
        return "\(isNumber(v, digits: v < 99.95 ? 1 : 0))M"
    }
    let v = bytes / 1_000_000_000
    return "\(isNumber(v, digits: v < 99.95 ? 1 : 0))G"
}

private func diskOpen(_ url: URL?, from view: NSView) {
    guard let url, let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Finder") else { return }
    (view.window as? PopupWindow)?.dismissIfUnlocked()
    NSWorkspace.shared.open([url], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
}

// MARK: - Views

// ring with the used share, name and free space, read and write activity dots. Opens the volume on click.
private final class DiskCard: ISCard {
    let uuid: String
    
    private let ring: ISRing = ISRing(diameter: 30, lineWidth: 3)
    private let percentField: ISText
    private let nameField: ISText
    private let freeField: ISText
    private let readDot: ISDot
    private let writeDot: ISDot
    private let readColor: NSColor
    private let writeColor: NSColor
    
    private var path: URL?
    private var activity: (read: Bool, write: Bool) = (false, false)
    
    init(_ d: drive) {
        let theme = ISTheme.current
        self.uuid = d.uuid
        self.path = d.path
        self.readColor = theme.pink
        self.writeColor = theme.blue
        self.percentField = ISText("", font: ISFont.value(11), color: theme.value, alignment: .center)
        self.nameField = ISText(d.mediaName, font: ISFont.label(13), color: theme.label)
        self.freeField = ISText("", font: ISFont.value(13, weight: .regular), color: theme.value)
        self.readDot = ISDot(theme.pink.withAlphaComponent(0.3), size: 8)
        self.writeDot = ISDot(theme.blue.withAlphaComponent(0.3), size: 8)
        
        super.init()
        self.edgeInsets = NSEdgeInsets(top: 4, left: ISMetrics.padH, bottom: 4, right: ISMetrics.padH)
        
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: ISMetrics.row * 2).isActive = true
        
        self.nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.freeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [self.ring, self.percentField, self.nameField, self.freeField, self.readDot, self.writeDot].forEach { body.addSubview($0) }
        
        NSLayoutConstraint.activate([
            self.ring.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            self.ring.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            self.percentField.centerXAnchor.constraint(equalTo: self.ring.centerXAnchor),
            self.percentField.centerYAnchor.constraint(equalTo: self.ring.centerYAnchor),
            
            self.nameField.leadingAnchor.constraint(equalTo: self.ring.trailingAnchor, constant: 6),
            self.nameField.centerYAnchor.constraint(equalTo: body.topAnchor, constant: ISMetrics.row / 2),
            self.freeField.leadingAnchor.constraint(equalTo: self.nameField.leadingAnchor),
            self.freeField.centerYAnchor.constraint(equalTo: body.bottomAnchor, constant: -(ISMetrics.row / 2)),
            
            self.readDot.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            self.readDot.centerYAnchor.constraint(equalTo: self.nameField.centerYAnchor),
            self.writeDot.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            self.writeDot.centerYAnchor.constraint(equalTo: self.freeField.centerYAnchor),
            
            self.nameField.trailingAnchor.constraint(lessThanOrEqualTo: self.readDot.leadingAnchor, constant: -6),
            self.freeField.trailingAnchor.constraint(lessThanOrEqualTo: self.writeDot.leadingAnchor, constant: -6)
        ])
        self.add(body)
        
        self.onClick = { [weak self] in
            guard let self else { return }
            diskOpen(self.path, from: self)
        }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func update(_ d: drive, toolTip: String) {
        self.path = d.path
        self.nameField.stringValue = d.mediaName
        self.ring.set(value: d.percentage)
        self.percentField.stringValue = "\(Int((d.percentage * 100).rounded()))"
        self.freeField.stringValue = "\(diskSize(d.free)) \(isL("available", fr: "disponibles"))"
        self.toolTip = toolTip
    }
    
    // bright when the disk was read / written during the last sample
    func setActivity(read: Bool, write: Bool) {
        guard self.activity != (read, write) else { return }
        self.activity = (read, write)
        self.readDot.color = read ? self.readColor : self.readColor.withAlphaComponent(0.3)
        self.writeDot.color = write ? self.writeColor : self.writeColor.withAlphaComponent(0.3)
    }
}

// name on the left, usage bar on the right. Opens the volume on click.
private final class DiskVolumeRow: NSView {
    private let nameField: ISText
    private let bar: ISProgressBar = ISProgressBar()
    private var path: URL?
    
    init(_ volume: DiskVolume) {
        self.nameField = ISText(volume.name, font: ISFont.label(13), color: ISTheme.current.value)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true
        
        self.nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.addSubview(self.nameField)
        self.addSubview(self.bar)
        NSLayoutConstraint.activate([
            self.nameField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.nameField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.bar.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.bar.widthAnchor.constraint(equalToConstant: 80),
            self.nameField.trailingAnchor.constraint(lessThanOrEqualTo: self.bar.leadingAnchor, constant: -8)
        ])
        
        self.update(volume)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func update(_ volume: DiskVolume) {
        self.path = volume.path
        self.nameField.stringValue = volume.name
        self.bar.set(volume.used)
        self.toolTip = volume.toolTip
    }
    
    override func mouseUp(with event: NSEvent) {
        if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
            diskOpen(self.path, from: self)
        } else {
            super.mouseUp(with: event)
        }
    }
}

// peaks of the visible history: "Lecture 24,0 Mo/s" on the left, "Écriture 19,4 Mo/s" on the right
private final class DiskPeakRow: NSView {
    private let readField: ISText = ISText()
    private let writeField: ISText = ISText(alignment: .right)
    private let readLabel: String
    private let writeLabel: String
    
    init(read: String, write: String) {
        self.readLabel = read
        self.writeLabel = write
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true
        
        self.readField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.writeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.writeField.setContentHuggingPriority(.required, for: .horizontal)
        self.addSubview(self.readField)
        self.addSubview(self.writeField)
        NSLayoutConstraint.activate([
            self.readField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.readField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.writeField.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.writeField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.readField.trailingAnchor.constraint(lessThanOrEqualTo: self.writeField.leadingAnchor, constant: -6)
        ])
        
        self.set(read: ("—", ""), write: ("—", ""))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(read: (String, String), write: (String, String)) {
        self.readField.attributedStringValue = self.text(self.readLabel, read, alignment: .left)
        self.writeField.attributedStringValue = self.text(self.writeLabel, write, alignment: .right)
    }
    
    // label in light gray, number in white, unit smaller
    private func text(_ label: String, _ value: (String, String), alignment: NSTextAlignment) -> NSAttributedString {
        let theme = ISTheme.current
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        
        let result = NSMutableAttributedString(string: "\(label) ", attributes: [
            .font: ISFont.label(13),
            .foregroundColor: theme.label,
            .paragraphStyle: paragraph
        ])
        result.append(NSAttributedString(string: value.0, attributes: [
            .font: ISFont.value(13),
            .foregroundColor: theme.value,
            .paragraphStyle: paragraph
        ]))
        if !value.1.isEmpty {
            result.append(NSAttributedString(string: " \(value.1)", attributes: [
                .font: ISFont.value(10),
                .foregroundColor: theme.value,
                .paragraphStyle: paragraph
            ]))
        }
        return result
    }
}
