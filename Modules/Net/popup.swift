//
//  popup.swift
//  Net
//
//  Created by Serhiy Mytrovtsiy on 24/05/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit
import SystemConfiguration

internal class Popup: PopupWrapper {
    // (upload, download) in bytes per second, one point per usage callback
    private let speedHistory = ISHistory<(Double, Double)>(capacity: 160)
    private var usageSamples: Int = 0
    // bytes sent and received, kept up to 30 days as a rate for the side panel
    private let longHistory = ISHistoryStore.shared.series("net.speed", dimensions: 2, kind: .amount)
    
    private var uploadValue: ISBigValue? = nil
    private var downloadValue: ISBigValue? = nil
    private var chart: ISMirrorChart? = nil
    private var peaks: NetPeakLine? = nil
    
    private var interfaceCard: ISCard? = nil
    private var interfaceRow: ISRow? = nil
    private var interfaceIconKey: String? = nil
    private var permissionRequired: Bool = false
    
    private var publicAddresses: NetAddressList? = nil
    private var localAddresses: NetAddressList? = nil
    
    private var processes: ISProcessList? = nil
    
    private var totalUploadRow: ISRow? = nil
    private var totalDownloadRow: ISRow? = nil
    private var locationRow: ISRow? = nil
    
    // VPN services known to macOS (Tailscale, WireGuard, IPSec…) and the network location: read while the popup is open
    private var vpnCard: ISCard? = nil
    private var vpnRows: [ISRow] = []
    private var vpnServices: [NetVPNService] = []
    private var networkLocation: String? = nil
    private var systemReadAt: Date? = nil
    private var systemReading: Bool = false
    
    private var pingCard: ISCard? = nil
    private var pingChart: ISBarChart? = nil
    // [latency in ms, lost (0 or 1), answered (0 or 1)], kept up to 30 days for the side panel
    private let pingHistory = ISHistoryStore.shared.series("net.ping", dimensions: 3)
    private var dnsRow: ISRow? = nil
    private var macRow: ISRow? = nil
    private var signalRow: ISRow? = nil
    private var channelRow: ISRow? = nil
    private var linkSpeedRow: ISRow? = nil
    
    private let processesCache = PopupCache<[Network_Process]>()
    private let usageCache = PopupCache<Network_Usage>()
    private let connectivityCache = PopupCache<Network_Connectivity?>()
    
    private var lastReset: Date = Date()
    private var latency: [Double] = []
    private var jitter: [Double] = []
    private var publicIPRefreshDeadline: Date = .distantPast
    
    private let processColumnWidth: CGFloat = 60
    private let resetFormatter: DateComponentsFormatter = {
        let form = DateComponentsFormatter()
        form.maximumUnitCount = 2
        form.unitsStyle = .full
        form.allowedUnits = [.day, .hour, .minute]
        return form
    }()
    
    public var locationPermissionAction: (() -> Void)?
    
    private var base: DataSizeBase {
        DataSizeBase(rawValue: Store.shared.string(key: "\(self.title)_base", defaultValue: "byte")) ?? .byte
    }
    private var speedUnit: String {
        networkSpeedUnit(from: Store.shared.string(key: "\(self.title)_speedUnit", defaultValue: NetworkSpeedUnitAuto)).key
    }
    private var numberOfProcesses: Int {
        Store.shared.int(key: "\(self.title)_processes", defaultValue: 8)
    }
    private var publicIPState: Bool {
        Store.shared.bool(key: "\(self.title)_publicIP", defaultValue: true)
    }
    private var emojiCCState: Bool {
        Store.shared.bool(key: "\(self.title)_emojiCC", defaultValue: true)
    }
    // the connectivity reader stays silent when its host is empty
    private var connectivityCheckDisabled: Bool {
        if Store.shared.string(key: "\(self.title)_connectivityMode", defaultValue: "icmp") == "http" {
            return Store.shared.string(key: "\(self.title)_HTTPHost", defaultValue: "https://google.com").isEmpty
        }
        return Store.shared.string(key: "\(self.title)_ICMPHost", defaultValue: "1.1.1.1").isEmpty
    }
    private var innerWidth: CGFloat {
        self.frame.width - (ISMetrics.padH * 2)
    }
    
    public init(_ module: ModuleType) {
        super.init(module, frame: NSRect(x: 0, y: 0, width: 285, height: 0))
        
        self.spacing = ISMetrics.spacing
        self.orientation = .vertical
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.resetTotalNetworkUsageCallback), name: .resetTotalNetworkUsage, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .resetTotalNetworkUsage, object: nil)
    }
    
    public override func loadContent() {
        self.addSection(self.initSpeed())
        self.addSection(self.initInterface())
        self.addSection(self.initVPN())
        self.addSection(self.initPing())
        if self.publicIPState {
            self.addSection(self.initPublicAddresses())
        }
        self.addSection(self.initLocalAddresses())
        if self.numberOfProcesses > 0 {
            self.addSection(self.initProcesses())
        }
        self.addSection(self.initDetails())
        self.addSection(ISShortcutBar(module: .network, extra: [
            ISShortcut.link(
                "x-apple.systempreferences:com.apple.Network-Settings.extension",
                symbol: "network",
                toolTip: isL("Network settings", fr: "Réglages Réseau")
            )
        ]))
        
        self.resizeToFitContent()
    }
    
    public override func unloadContent() {
        self.uploadValue = nil
        self.downloadValue = nil
        self.chart = nil
        self.peaks = nil
        self.interfaceCard = nil
        self.interfaceRow = nil
        self.interfaceIconKey = nil
        self.permissionRequired = false
        self.publicAddresses = nil
        self.localAddresses = nil
        self.processes = nil
        self.totalUploadRow = nil
        self.totalDownloadRow = nil
        self.locationRow = nil
        self.vpnCard = nil
        self.vpnRows = []
        self.pingCard = nil
        self.pingChart = nil
        self.dnsRow = nil
        self.macRow = nil
        self.signalRow = nil
        self.channelRow = nil
        self.linkSpeedRow = nil
    }
    
    public override func appear() {
        self.replay(self.usageCache, render: self.renderUsage)
        self.replay(self.connectivityCache, render: self.renderConnectivity)
        self.replay(self.processesCache, render: self.renderProcesses)
        self.renderVPN()
        self.refreshSystem(force: true)
    }
    
    // MARK: - Views
    
    private func initSpeed() -> NSView {
        let theme = ISTheme.current
        let card = ISCard()
        card.edgeInsets.top = ISMetrics.padV + 2
        
        let upload = ISBigValue(caption: isL("Sent", fr: "Envoyé"), color: theme.pink)
        let download = ISBigValue(caption: isL("Received", fr: "Reçu"), color: theme.blue)
        let values = NSView()
        values.translatesAutoresizingMaskIntoConstraints = false
        values.heightAnchor.constraint(equalToConstant: 38).isActive = true
        values.addSubview(upload)
        values.addSubview(download)
        NSLayoutConstraint.activate([
            upload.topAnchor.constraint(equalTo: values.topAnchor),
            upload.leadingAnchor.constraint(equalTo: values.leadingAnchor),
            upload.widthAnchor.constraint(equalTo: values.widthAnchor, multiplier: 0.5),
            download.topAnchor.constraint(equalTo: values.topAnchor),
            download.trailingAnchor.constraint(equalTo: values.trailingAnchor),
            download.widthAnchor.constraint(equalTo: values.widthAnchor, multiplier: 0.5)
        ])
        card.add(values, spacingAfter: 4)
        
        let chart = ISMirrorChart(up: theme.pink, down: theme.blue, height: 72)
        card.add(chart, spacingAfter: 4)
        
        // highest value of the bars on screen, the scale of each half of the chart
        let peaks = NetPeakLine(isL("Sent", fr: "Envoyé"), isL("Received", fr: "Reçu"))
        peaks.set(self.speedParts(0), self.speedParts(0))
        card.add(peaks)
        
        self.uploadValue = upload
        self.downloadValue = download
        self.chart = chart
        self.peaks = peaks
        card.detailID = "history"
        card.detail = { [weak self] in
            self?.historyDetail() ?? NSView()
        }
        
        return card
    }
    
    private func initInterface() -> NSView {
        let card = ISCard()
        let row = ISRow(localizedString("Network"), icon: self.interfaceIcon(nil))
        row.labelField.textColor = ISTheme.current.value
        // a long network name is cut, not the name of the interface
        row.labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        row.valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.add(row)
        
        self.interfaceCard = card
        self.interfaceRow = row
        
        return card
    }
    
    // one line per VPN service: a lock, its name, and how long it has been connected
    private func initVPN() -> NSView {
        let card = ISCard()
        card.isHidden = self.vpnServices.isEmpty
        self.vpnCard = card
        self.vpnRows = []
        return card
    }
    
    // latency of the connectivity check, with its last minute and a half as bars
    private func initPing() -> NSView {
        let card = ISCard(title: "Ping", value: "—")
        let chart = ISBarChart(colors: [ISTheme.current.blue], height: 26)
        chart.maxValue = nil
        card.add(chart)
        if let header = card.header {
            card.setCustomSpacing(3, after: header)
        }
        card.edgeInsets.bottom = ISMetrics.padV + 2
        card.isHidden = self.connectivityCheckDisabled
        card.detailID = "ping"
        card.detail = { [weak self] in
            self?.pingDetail() ?? NSView()
        }
        self.pingCard = card
        self.pingChart = chart
        return card
    }
    
    private func initPublicAddresses() -> NSView {
        let list = NetAddressList(title: isL("Public IP addresses", fr: "Adresses IP publiques"), width: self.innerWidth)
        if let title = list.card.titleField {
            title.toolTip = localizedString("Refresh")
            title.addGestureRecognizer(NetClick { [weak self] _ in
                self?.refreshPublicIP()
            })
        }
        self.publicAddresses = list
        return list.card
    }
    
    private func initLocalAddresses() -> NSView {
        let list = NetAddressList(title: isL("IP addresses", fr: "Adresses IP"), width: self.innerWidth)
        self.localAddresses = list
        return list.card
    }
    
    private func initProcesses() -> NSView {
        let card = ISCard(title: isL("Processes", fr: "Processus"))
        card.setHeaderColumns(["↑", "↓"], width: self.processColumnWidth)
        let list = ISProcessList(n: self.numberOfProcesses, columns: 2, columnWidth: self.processColumnWidth)
        card.add(list)
        self.processes = list
        return card
    }
    
    // what Stats knows and the reference does not show
    private func initDetails() -> NSView {
        let theme = ISTheme.current
        let card = ISCard(title: localizedString("Details"))
        
        if let header = card.header {
            let button = NetGlyphButton(symbol: "arrow.counterclockwise", toolTip: localizedString("Reset data usage")) { [weak self] in
                self?.resetTotalNetworkUsage()
            }
            card.valueField?.isHidden = true
            header.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: header.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: header.centerYAnchor)
            ])
        }
        
        let totalUpload = ISRow(isL("Total sent", fr: "Total envoyé"), value: self.memory(0), color: theme.pink)
        let totalDownload = ISRow(isL("Total received", fr: "Total reçu"), value: self.memory(0), color: theme.blue)
        let location = ISRow(isL("Location", fr: "Lieu"))
        location.setPlain(self.locationName)
        let dns = ISRow(localizedString("DNS Server"))
        dns.setPlain("—")
        // an IPv6 server is cut in the middle, the label stays whole
        dns.labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        dns.valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dns.valueField.lineBreakMode = .byTruncatingMiddle
        let mac = ISRow(isL("MAC address", fr: "Adresse MAC"))
        mac.setPlain("—")
        let signal = ISRow(localizedString("Signal"))
        let channel = ISRow(localizedString("Channel"))
        let linkSpeed = ISRow(isL("Link speed", fr: "Débit de liaison"))
        [signal, channel, linkSpeed].forEach { $0.isHidden = true }
        
        let copyTip = isL("Click to copy", fr: "Cliquer pour copier")
        mac.toolTip = copyTip
        mac.addGestureRecognizer(NetClick { [weak self] view in
            netCopy(self?.usageCache.value?.interface?.address, flash: view)
        })
        dns.addGestureRecognizer(NetClick { [weak self] view in
            netCopy(self?.usageCache.value?.dns.joined(separator: ", "), flash: view)
        })
        
        [totalUpload, totalDownload, location, dns, mac, signal, channel, linkSpeed].forEach { card.add($0) }
        
        self.totalUploadRow = totalUpload
        self.totalDownloadRow = totalDownload
        self.locationRow = location
        self.dnsRow = dns
        self.macRow = mac
        self.signalRow = signal
        self.channelRow = channel
        self.linkSpeedRow = linkSpeed
        
        return card
    }
    
    // MARK: - History panel

    // side panel of the speed card: the speed over time, its peaks and the amount of data of the period
    private func historyDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()

        let speed = ISHistoryCard(
            title: isL("Speed", fr: "Débit"),
            series: self.longHistory,
            style: .mirror,
            colors: [theme.pink, theme.blue],
            dims: [0, 1],
            height: 84
        )
        let uploadPeak = ISRow(isL("Sent, peak", fr: "Envoyé, pic"), color: theme.pink)
        let downloadPeak = ISRow(isL("Received, peak", fr: "Reçu, pic"), color: theme.blue)
        speed.add(uploadPeak)
        speed.add(downloadPeak)

        let data = ISCard(title: isL("Data", fr: "Données"), value: "")
        let sent = ISRow(isL("Sent", fr: "Envoyé"), color: theme.pink)
        let received = ISRow(isL("Received", fr: "Reçu"), color: theme.blue)
        data.add(sent)
        data.add(received)

        speed.summary = { [weak self] _, points in
            guard let self else { return }
            uploadPeak.set(points.isMaximum(0).map({ self.speed(Int64($0)) }) ?? "—")
            downloadPeak.set(points.isMaximum(1).map({ self.speed(Int64($0)) }) ?? "—")
            sent.set(points.isTotal(0).map({ self.memory(Int64($0)) }) ?? "—")
            received.set(points.isTotal(1).map({ self.memory(Int64($0)) }) ?? "—")
            data.valueField?.stringValue = ISRange.current.title
        }
        stack.add(speed)
        stack.add(data)

        stack.refresh()
        return stack
    }

    // side panel of the ping card: latency over time, losses, and the host that is checked
    private func pingDetail() -> NSView {
        let theme = ISTheme.current
        let stack = ISDetailStack()
        
        let ping = ISHistoryCard(
            title: "Ping",
            series: self.pingHistory,
            style: .lines,
            colors: [theme.blue],
            dims: [0],
            height: 64
        )
        let average = ISRow(isL("Average", fr: "Moyenne"))
        let peak = ISRow(isL("Peak", fr: "Pic"))
        let lost = ISRow(isL("Lost", fr: "Pertes"))
        let host = ISRow(isL("Host", fr: "Hôte"))
        [average, peak, lost, host].forEach { ping.add($0) }
        if Store.shared.string(key: "\(self.title)_connectivityMode", defaultValue: "icmp") == "http" {
            host.setPlain(Store.shared.string(key: "\(self.title)_HTTPHost", defaultValue: "https://google.com"))
        } else {
            host.setPlain(Store.shared.string(key: "\(self.title)_ICMPHost", defaultValue: "1.1.1.1"))
        }
        host.labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        host.valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ping.summary = { _, points in
            // the average only counts the checks that got an answer
            let answered = points.isTotal(2) ?? 0
            if answered > 0, let total = points.isTotal(0) {
                let value = total / answered
                average.set("\(isNumber(value, digits: value < 10 ? 1 : 0)) ms")
            } else {
                average.set("—")
            }
            peak.set(points.isMaximum(0).map({ "\(isNumber($0, digits: 0)) ms" }) ?? "—")
            lost.set(points.isAverage(1).map({ "\(isNumber($0 * 100, digits: $0 > 0 && $0 < 0.1 ? 1 : 0))%" }) ?? "—")
        }
        stack.add(ping)
        
        stack.refresh()
        return stack
    }
    
    // MARK: - System state (VPN, location)
    
    private var locationName: String {
        guard let name = self.networkLocation, !name.isEmpty else { return "—" }
        return name == "Automatic" ? isL("Automatic", fr: "Automatique") : name
    }
    
    private func lockIcon(_ connected: Bool) -> NSImage {
        NSImage(systemSymbolName: connected ? "lock.fill" : "lock.open.fill", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: ISMetrics.icon, height: ISMetrics.icon))
    }
    
    // "23h, 57m" as iStat Menus writes it
    private func elapsed(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 {
            return isL("\(days)d, \(hours)h", fr: "\(days)j, \(hours)h")
        }
        if hours > 0 {
            return "\(hours)h, \(minutes)m"
        }
        return "\(minutes)m"
    }
    
    // SystemConfiguration is asked on a background queue, at most every five seconds while the popup is open
    private func refreshSystem(force: Bool = false) {
        guard !self.systemReading else { return }
        if !force, let at = self.systemReadAt, Date().timeIntervalSince(at) < 5 { return }
        
        self.systemReading = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let state = NetSystem.read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.systemReading = false
                self.systemReadAt = Date()
                self.vpnServices = state.vpn
                self.networkLocation = state.location
                self.renderVPN()
            }
        }
    }
    
    private func renderVPN() {
        self.locationRow?.setPlain(self.locationName)
        guard let card = self.vpnCard else { return }
        let theme = ISTheme.current
        var resized = false
        
        if self.vpnRows.count != self.vpnServices.count {
            card.removeAll(keepHeader: false)
            self.vpnRows = self.vpnServices.map { _ in
                let row = ISRow("", icon: self.lockIcon(true))
                // a long name is kept whole, the duration gives way
                row.labelField.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
                row.valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                card.add(row)
                return row
            }
            resized = true
        }
        
        for (row, service) in zip(self.vpnRows, self.vpnServices) {
            row.labelField.stringValue = service.name
            row.iconView?.image = self.lockIcon(service.connected)
            row.iconView?.contentTintColor = service.connected ? theme.blue : theme.dim
            row.labelField.textColor = service.connected ? theme.value : theme.dim
            row.valueField.textColor = service.connected ? theme.value : theme.dim
            if service.connected {
                row.setPlain(service.since.map { self.elapsed(since: $0) } ?? isL("Connected", fr: "Connecté"))
            } else {
                row.setPlain(isL("Not connected", fr: "Non connecté"))
            }
            self.setToolTip(row, service.interface)
        }
        
        if self.setHidden(card, self.vpnServices.isEmpty) {
            resized = true
        }
        if resized {
            self.resizeToFitContent()
        }
    }
    
    // MARK: - Formatting
    
    // same unit settings as the widgets (bits or bytes, fixed unit), with the local wording
    private func speedParts(_ bytes: Int64) -> (String, String) {
        let parts = Units(bytes: max(0, bytes)).getReadableTuple(base: self.base, unit: self.speedUnit)
        let separator = Locale.current.decimalSeparator ?? "."
        let number = separator == "." ? parts.0 : parts.0.replacingOccurrences(of: ".", with: separator)
        var unit = parts.1
        if unit.hasSuffix("B/s") {
            unit = String(unit.dropLast(3)) + isL("B/s", fr: "o/s")
        }
        return (number, unit)
    }
    
    private func speed(_ bytes: Int64) -> String {
        let parts = self.speedParts(bytes)
        return "\(parts.0) \(parts.1)"
    }
    
    // short form for the two columns of the process list: "8,8 M"
    private func compactSpeed(_ bytes: Int) -> String {
        let parts = self.speedParts(Int64(bytes))
        var unit = parts.1.replacingOccurrences(of: "/s", with: "")
        if self.base == .byte && unit.count > 1 {
            unit.removeLast()
        }
        return "\(parts.0) \(unit)"
    }
    
    private func memory(_ bytes: Int64) -> String {
        bytes <= 0 ? isL("0 KB", fr: "0 ko") : Units(bytes: bytes).getReadableMemory()
    }
    
    private func linkSpeed(_ rate: Double) -> String {
        if rate >= 1000 {
            let value = rate / 1000
            return "\(isNumber(value, digits: value == value.rounded() ? 0 : 1)) \(isL("Gbps", fr: "Gbit/s"))"
        }
        return "\(Int(rate.rounded())) \(isL("Mbps", fr: "Mbit/s"))"
    }
    
    private func pair(_ label: String, _ value: String) -> String {
        isL("\(label): \(value)", fr: "\(label) : \(value)")
    }
    
    private func countrySuffix(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "" }
        if self.emojiCCState, let flag = countryFlag(code) {
            return " \(flag)"
        }
        return " (\(code))"
    }
    
    private func interfaceIcon(_ type: Network_t?) -> NSImage {
        var names: [String] = ["network"]
        if let type {
            switch type {
            case .wifi: names = ["wifi"]
            case .ethernet: names = ["cable.connector", "network"]
            case .bluetooth: names = ["dot.radiowaves.left.and.right", "network"]
            case .other: names = ["network"]
            }
        }
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return image
            }
        }
        return NSImage(size: NSSize(width: ISMetrics.icon, height: ISMetrics.icon))
    }
    
    // a tooltip that is set again every second never has the time to show up
    private func setToolTip(_ view: NSView?, _ value: String?) {
        guard let view, view.toolTip != value else { return }
        view.toolTip = value
    }
    
    private func setHidden(_ view: NSView, _ hidden: Bool) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }
    
    // a long value (IPv6) gets a smaller font instead of squeezing its label
    private func setFitted(_ row: ISRow, _ text: String) {
        let label = netTextWidth(row.labelField.stringValue, ISFont.label(13)) + 4
        let available = self.innerWidth - label - 6 - 4
        var size: CGFloat = 13
        while size > 10 && netTextWidth(text, ISFont.value(size)) > available {
            size -= 1
        }
        row.valueField.font = ISFont.value(size)
        row.setPlain(text)
    }
    
    // MARK: - Updates
    
    public func usageCallback(_ value: Network_Usage) {
        DispatchQueue.main.async {
            // the first sample after launch carries the counters since boot, not a speed: keep it out of the chart
            guard self.usageSamples > 0 else {
                self.usageSamples += 1
                return
            }
            self.speedHistory.append((Double(value.bandwidth.upload), Double(value.bandwidth.download)))
            self.longHistory.record([Double(value.bandwidth.upload), Double(value.bandwidth.download)])
        }
        self.apply(value, to: self.usageCache, render: self.renderUsage)
    }
    
    private func renderUsage(_ value: Network_Usage) {
        self.uploadValue?.set(self.speed(value.bandwidth.upload))
        self.downloadValue?.set(self.speed(value.bandwidth.download))
        
        if let chart = self.chart {
            let history = self.speedHistory.values
            chart.set(history)
            
            let width = chart.bounds.width > 0 ? chart.bounds.width : self.innerWidth
            let visible = history.suffix(max(1, Int(width / (chart.barWidth + chart.gap))))
            self.peaks?.set(
                self.speedParts(Int64(visible.map({ $0.0 }).max() ?? 0)),
                self.speedParts(Int64(visible.map({ $0.1 }).max() ?? 0))
            )
        }
        
        self.renderInterface(value)
        self.refreshSystem()
        let addresses = self.renderAddresses(value)
        let details = self.renderDetails(value)
        
        if addresses || details {
            self.resizeToFitContent()
        }
    }
    
    private func renderInterface(_ value: Network_Usage) {
        guard let row = self.interfaceRow, let card = self.interfaceCard else { return }
        let theme = ISTheme.current
        
        let iconKey = value.connectionType?.rawValue ?? ""
        if iconKey != self.interfaceIconKey {
            self.interfaceIconKey = iconKey
            row.iconView?.image = self.interfaceIcon(value.connectionType)
        }
        
        let name = value.interface?.displayName ?? ""
        row.labelField.stringValue = name.isEmpty ? localizedString("Network") : name
        
        var text = ""
        var toolTip: String? = nil
        var permission = false
        
        if !value.status {
            text = isL("Not connected", fr: "Non connecté")
        } else if value.connectionType == .wifi {
            // the name of the network is only readable with the location permission
            if value.wifiLocationAuthorization == .notDetermined || value.wifiLocationAuthorization == .denied {
                permission = true
                text = "…"
                toolTip = localizedString(value.wifiLocationAuthorization == .notDetermined ? "Allow access to Wi-Fi details" : "Open Location Settings")
            } else {
                text = value.wifiDetails.ssid ?? "—"
            }
        } else {
            text = value.interface?.BSDName ?? ""
        }
        
        if toolTip == nil, let interface = value.interface {
            var parts: [String] = [interface.BSDName]
            if let v = value.wifiDetails.standard, v != "none", v != "unknown" { parts.append(v) }
            if let v = value.wifiDetails.security, v != "none", v != "unknown" { parts.append(v) }
            if let v = value.wifiDetails.countryCode { parts.append(v) }
            toolTip = parts.filter({ !$0.isEmpty }).joined(separator: " · ")
        }
        self.setToolTip(card, toolTip)
        
        row.labelField.textColor = value.status ? theme.value : theme.dim
        row.valueField.textColor = value.status ? theme.value : theme.dim
        row.iconView?.contentTintColor = value.status ? theme.blue : theme.dim
        row.setPlain(text)
        
        if permission != self.permissionRequired {
            self.permissionRequired = permission
            if permission {
                card.onClick = { [weak self] in
                    self?.requestLocationPermission()
                }
            } else {
                card.onClick = nil
            }
        }
    }
    
    // true when a card changed its number of lines
    private func renderAddresses(_ value: Network_Usage) -> Bool {
        var resized = false
        
        if let list = self.publicAddresses {
            let suffix = self.countrySuffix(value.raddr.countryCode)
            var items: [NetAddress] = []
            if let v4 = value.raddr.v4, !v4.isEmpty {
                items.append(NetAddress(text: v4 + suffix, value: v4))
            }
            if let v6 = value.raddr.v6, !v6.isEmpty {
                items.append(NetAddress(text: items.isEmpty ? v6 + suffix : v6, value: v6))
            }
            let updating = items.isEmpty && Date() < self.publicIPRefreshDeadline
            if list.set(items, placeholder: updating ? localizedString("Updating...") : "—") {
                resized = true
            }
        }
        
        if let list = self.localAddresses {
            var items: [NetAddress] = []
            if let v4 = value.laddr.v4, !v4.isEmpty {
                items.append(NetAddress(text: v4, value: v4))
            }
            if let v6 = value.laddr.v6, !v6.isEmpty {
                items.append(NetAddress(text: v6, value: v6))
            }
            if list.set(items, placeholder: "—") {
                resized = true
            }
        }
        
        return resized
    }
    
    // true when a row appeared or disappeared
    private func renderDetails(_ value: Network_Usage) -> Bool {
        var resized = false
        
        self.totalUploadRow?.set(self.memory(value.total.upload))
        self.totalDownloadRow?.set(self.memory(value.total.download))
        let reset = self.resetFormatter.string(from: self.lastReset, to: Date()).map { localizedString("Last reset", $0) }
        self.setToolTip(self.totalUploadRow, reset)
        self.setToolTip(self.totalDownloadRow, reset)
        
        if let row = self.dnsRow {
            if let first = value.dns.first {
                self.setFitted(row, value.dns.count > 1 ? "\(first) +\(value.dns.count - 1)" : first)
                self.setToolTip(row, value.dns.joined(separator: "\n"))
            } else {
                self.setFitted(row, "—")
                self.setToolTip(row, nil)
            }
        }
        
        if let row = self.macRow {
            let address = value.interface?.address ?? ""
            row.setPlain(address.isEmpty ? "—" : address)
        }
        
        let wifi = value.connectionType == .wifi
        if let row = self.signalRow {
            let rssi = value.wifiDetails.RSSI ?? 0
            let visible = wifi && rssi != 0
            if visible {
                row.set("\(rssi) dBm")
                self.setToolTip(row, value.wifiDetails.noise.map { self.pair(isL("Noise", fr: "Bruit"), "\($0) dBm") })
            }
            if self.setHidden(row, !visible) {
                resized = true
            }
        }
        if let row = self.channelRow {
            let channel = value.wifiDetails.channel ?? ""
            let visible = wifi && !channel.isEmpty
            if visible {
                row.setPlain(channel)
                self.setToolTip(row, value.wifiDetails.bssid.map { self.pair("BSSID", $0) })
            }
            if self.setHidden(row, !visible) {
                resized = true
            }
        }
        if let row = self.linkSpeedRow {
            let rate = value.interface?.transmitRate ?? 0
            if rate > 0 {
                row.set(self.linkSpeed(rate))
            }
            if self.setHidden(row, rate <= 0) {
                resized = true
            }
        }
        
        return resized
    }
    
    public func connectivityCallback(_ value: Network_Connectivity?) {
        if let value, !self.connectivityCheckDisabled {
            self.pingHistory.record(value.status ? [value.latency, 0, 1] : [0, 1, 0])
        }
        DispatchQueue.main.async {
            if self.latency.count >= 90 {
                self.latency.removeFirst()
            }
            self.latency.append(value?.latency ?? 0)
            
            if self.jitter.count >= 90 {
                self.jitter.removeFirst()
            }
            self.jitter.append(value?.jitter ?? 0)
        }
        self.apply(value, to: self.connectivityCache, render: self.renderConnectivity)
    }
    
    private func renderConnectivity(_ value: Network_Connectivity?) {
        guard let card = self.pingCard else { return }
        let theme = ISTheme.current
        
        if self.setHidden(card, self.connectivityCheckDisabled) {
            self.resizeToFitContent()
        }
        guard let value, !self.connectivityCheckDisabled else {
            card.valueField?.textColor = theme.value
            card.valueField?.stringValue = "—"
            self.setToolTip(card, nil)
            return
        }
        
        self.pingChart?.set(self.latency.map { [$0] })
        guard value.status else {
            card.valueField?.textColor = theme.red
            card.valueField?.stringValue = isL("Offline", fr: "Hors ligne")
            self.setToolTip(card, nil)
            return
        }
        
        card.valueField?.textColor = theme.value
        card.valueField?.attributedStringValue = isValue(isNumber(value.latency, digits: value.latency < 10 ? 1 : 0), "ms")
        
        // average and jitter of the last checks
        var parts: [String] = []
        if !self.latency.isEmpty {
            let average = self.latency.reduce(0, +) / Double(self.latency.count)
            parts.append(self.pair(isL("Average", fr: "Moyenne"), "\(isNumber(average, digits: 1)) ms"))
        }
        if !self.jitter.isEmpty {
            let average = self.jitter.reduce(0, +) / Double(self.jitter.count)
            parts.append(self.pair(isL("Jitter", fr: "Gigue"), "\(isNumber(average, digits: 1)) ms"))
        }
        self.setToolTip(card, parts.isEmpty ? nil : parts.joined(separator: "\n"))
    }
    
    public func resetConnectivityView() {
        self.latency.removeAll()
        self.jitter.removeAll()
        self.pingChart?.set([])
        self.pingCard?.valueField?.textColor = ISTheme.current.value
        self.pingCard?.valueField?.stringValue = "—"
        self.setToolTip(self.pingCard, nil)
    }
    
    public func processCallback(_ list: [Network_Process]) {
        self.apply(list, to: self.processesCache, render: self.renderProcesses)
    }
    
    private func renderProcesses(_ list: [Network_Process]) {
        guard let processes = self.processes else { return }
        let n = min(list.count, processes.count)
        for i in 0..<n {
            processes.set(i, list[i], [self.compactSpeed(list[i].upload), self.compactSpeed(list[i].download)])
        }
        processes.clear(from: n)
    }
    
    public func numberOfProcessesUpdated() {
        DispatchQueue.main.async {
            guard self.contentLoaded, (self.processes?.count ?? 0) != self.numberOfProcesses else { return }
            self.rebuild()
        }
    }
    
    // MARK: - Actions
    
    private func rebuild() {
        guard self.contentLoaded else { return }
        self.releaseContent()
        self.processesCache.initialized = false
        self.prepareForDisplay()
    }
    
    private func requestLocationPermission() {
        guard let action = self.locationPermissionAction else { return }
        if self.usageCache.value?.wifiLocationAuthorization == .denied {
            (self.window as? PopupWindow)?.dismissIfUnlocked()
        }
        action()
    }
    
    private func refreshPublicIP() {
        NotificationCenter.default.post(name: .refreshPublicIP, object: nil, userInfo: nil)
        self.publicIPRefreshDeadline = Date().addingTimeInterval(15)
        if self.publicAddresses?.set([], placeholder: localizedString("Updating...")) == true {
            self.resizeToFitContent()
        }
    }
    
    private func resetTotalNetworkUsage() {
        NotificationCenter.default.post(name: .resetTotalNetworkUsage, object: nil, userInfo: nil)
        self.totalUploadRow?.set(self.memory(0))
        self.totalDownloadRow?.set(self.memory(0))
        self.lastReset = Date()
    }
    
    @objc private func resetTotalNetworkUsageCallback() {
        self.lastReset = Date()
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
        
        view.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Public IP"), component: self.switchView(
                action: #selector(self.togglePublicIP),
                state: self.publicIPState
            )),
            PreferencesRow(localizedString("Show country code instead of emoji"), component: self.switchView(
                action: #selector(self.toggleEmojiCC),
                state: !self.emojiCCState
            ))
        ]))
        
        return view
    }
    
    @objc private func togglePublicIP(_ sender: NSControl) {
        Store.shared.set(key: "\(self.title)_publicIP", value: controlState(sender))
        DispatchQueue.main.async {
            self.rebuild()
        }
    }
    
    @objc private func toggleEmojiCC(_ sender: NSControl) {
        Store.shared.set(key: "\(self.title)_emojiCC", value: !controlState(sender))
    }
}

// MARK: - Parts that only this popup needs

private func netTextWidth(_ string: String, _ font: NSFont) -> CGFloat {
    ceil(NSAttributedString(string: string, attributes: [.font: font]).size().width)
}

private func netCopy(_ string: String?, flash view: NSView?) {
    guard let string, !string.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
    
    guard let view else { return }
    view.alphaValue = 0.3
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.4
        view.animator().alphaValue = 1
    }
}

// a click on any view, without subclassing the parts of the kit
private final class NetClick: NSClickGestureRecognizer {
    private let handler: (NSView?) -> Void
    
    init(_ handler: @escaping (NSView?) -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        self.target = self
        self.action = #selector(self.fire)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func fire() {
        self.handler(self.view)
    }
}

// small symbol on the right of a card title
private final class NetGlyphButton: NSButton {
    private let handler: () -> Void
    
    init(symbol: String, toolTip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.isBordered = false
        self.bezelStyle = .regularSquare
        self.imagePosition = .imageOnly
        self.imageScaling = .scaleProportionallyUpOrDown
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        self.contentTintColor = ISTheme.current.dim
        self.toolTip = toolTip
        self.focusRingType = .none
        self.target = self
        self.action = #selector(self.fire)
        self.widthAnchor.constraint(equalToConstant: 13).isActive = true
        self.heightAnchor.constraint(equalToConstant: 13).isActive = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func fire() {
        self.handler()
    }
}

// "Sent 195 KB/s" on the left, "Received 63 KB/s" on the right
private final class NetPeakLine: NSView {
    private let leftField = ISText("", alignment: .left)
    private let rightField = ISText("", alignment: .right)
    private let labels: (String, String)
    
    init(_ left: String, _ right: String) {
        self.labels = (left, right)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true
        
        self.rightField.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.addSubview(self.leftField)
        self.addSubview(self.rightField)
        NSLayoutConstraint.activate([
            self.leftField.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.leftField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.rightField.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.rightField.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.leftField.trailingAnchor.constraint(lessThanOrEqualTo: self.rightField.leadingAnchor, constant: -6)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(_ left: (String, String), _ right: (String, String)) {
        self.leftField.attributedStringValue = self.text(self.labels.0, left, .left)
        self.rightField.attributedStringValue = self.text(self.labels.1, right, .right)
    }
    
    private func text(_ label: String, _ value: (String, String), _ alignment: NSTextAlignment) -> NSAttributedString {
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

// one address on a full line, the font shrinks until the address fits
private final class NetTextLine: NSView {
    private let field = ISText("", font: ISFont.value(13, weight: .regular), color: ISTheme.current.value)
    
    init() {
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.heightAnchor.constraint(equalToConstant: ISMetrics.row).isActive = true
        
        self.field.lineBreakMode = .byTruncatingMiddle
        self.field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.addSubview(self.field)
        NSLayoutConstraint.activate([
            self.field.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.field.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor),
            self.field.centerYAnchor.constraint(equalTo: self.centerYAnchor)
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(_ text: String, maxWidth: CGFloat) {
        var size: CGFloat = 13
        while size > 9 && netTextWidth(text, ISFont.value(size, weight: .regular)) + 4 > maxWidth {
            size -= 1
        }
        self.field.font = ISFont.value(size, weight: .regular)
        self.field.stringValue = text
    }
}

private struct NetAddress: Equatable {
    let text: String // what is shown (the address, with the country for a public one)
    let value: String // what a click copies
}

// card of addresses: a single short one sits next to the title, otherwise one full line each
private final class NetAddressList {
    let card: ISCard
    
    private let width: CGFloat
    private let copyTip: String = isL("Click to copy", fr: "Cliquer pour copier")
    private var items: [NetAddress] = []
    private var placeholder: String = ""
    private var lines: [NetTextLine] = []
    private var applied: Bool = false
    
    init(title: String, width: CGFloat) {
        self.card = ISCard(title: title, value: "—")
        self.width = width
        self.card.valueField?.textColor = ISTheme.current.dim
        self.card.valueField?.addGestureRecognizer(NetClick { [weak self] view in
            guard let self, self.lines.isEmpty else { return }
            netCopy(self.items.first?.value, flash: view)
        })
    }
    
    // true when the number of lines, so the height of the card, changed
    func set(_ items: [NetAddress], placeholder: String) -> Bool {
        if self.applied && items == self.items && placeholder == self.placeholder { return false }
        self.applied = true
        self.items = items
        self.placeholder = placeholder
        
        let theme = ISTheme.current
        let inHeader = items.count == 1 && self.fitsInHeader(items[0].text)
        let rows: [NetAddress] = inHeader ? [] : items
        
        if let field = self.card.valueField {
            field.textColor = items.isEmpty ? theme.dim : theme.value
            field.stringValue = items.isEmpty ? placeholder : (inHeader ? items[0].text : "")
            field.toolTip = inHeader ? self.copyTip : nil
        }
        
        let changed = rows.count != self.lines.count
        while self.lines.count > rows.count {
            let line = self.lines.removeLast()
            self.card.removeArrangedSubview(line)
            line.removeFromSuperview()
        }
        while self.lines.count < rows.count {
            let idx = self.lines.count
            let line = NetTextLine()
            line.toolTip = self.copyTip
            line.addGestureRecognizer(NetClick { [weak self] view in
                guard let self, self.items.indices.contains(idx) else { return }
                netCopy(self.items[idx].value, flash: view)
            })
            self.card.add(line)
            self.lines.append(line)
        }
        for (i, row) in rows.enumerated() {
            self.lines[i].set(row.text, maxWidth: self.width)
        }
        
        return changed
    }
    
    private func fitsInHeader(_ text: String) -> Bool {
        let title = netTextWidth(self.card.titleField?.stringValue ?? "", ISFont.label(13)) + 4
        let value = netTextWidth(text, ISFont.value(13)) + 4
        return title + 6 + value <= self.width
    }
}

// MARK: - System state

private struct NetVPNService {
    let name: String
    let connected: Bool
    let since: Date?
    let interface: String?
}

// what SystemConfiguration knows and the usage reader does not carry: the VPN services and the network location
private enum NetSystem {
    static func read() -> (vpn: [NetVPNService], location: String?) {
        guard let prefs = SCPreferencesCreate(nil, "Stats" as CFString, nil) else { return ([], nil) }
        
        var location: String? = nil
        if let set = SCNetworkSetCopyCurrent(prefs) {
            location = SCNetworkSetGetName(set) as String?
        }
        
        var list: [NetVPNService] = []
        for service in (SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]) ?? [] {
            guard SCNetworkServiceGetEnabled(service),
                  let interface = SCNetworkServiceGetInterface(service),
                  let kind = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            
            // "VPN" covers the apps built on Network Extension (Tailscale, WireGuard…); a PPP service is one only over L2TP or PPTP
            var isVPN = kind == "VPN" || kind == "IPSec"
            if kind == "PPP", let child = SCNetworkInterfaceGetInterface(interface),
               let childKind = SCNetworkInterfaceGetInterfaceType(child) as String?, childKind == "L2TP" || childKind == "PPTP" {
                isVPN = true
            }
            guard isVPN, let id = SCNetworkServiceGetServiceID(service),
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil) else { continue }
            
            let connected = SCNetworkConnectionGetStatus(connection) == .connected
            var since: Date? = nil
            var device: String? = nil
            if connected, let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] {
                since = status["LastStatusChangeTime"] as? Date
                if since == nil, let vpn = status["VPN"] as? [String: Any], let uptime = (vpn["ConnectTime"] as? NSNumber)?.doubleValue {
                    // seconds of system uptime at the time of the connection
                    since = Date().addingTimeInterval(-max(0, ProcessInfo.processInfo.systemUptime - uptime))
                }
                device = (status["IPv4"] as? [String: Any])?["InterfaceName"] as? String
            }
            
            list.append(NetVPNService(
                name: (SCNetworkServiceGetName(service) as String?) ?? "VPN",
                connected: connected,
                since: since,
                interface: device
            ))
        }
        
        return (list, location)
    }
}
