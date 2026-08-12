import AppKit
import CoreGraphics
import ServiceManagement

@_silgen_name("CGSConfigureDisplayEnabled")
private func CGSConfigureDisplayEnabled(
    _ config: CGDisplayConfigRef?,
    _ display: CGDirectDisplayID,
    _ enabled: Bool
) -> CGError

private struct DisplayModeInfo: Codable, Equatable, Hashable {
    let modeID: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        modeID = mode.ioDisplayModeID
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    var label: String {
        var details: [String] = []
        if pixelWidth > width || pixelHeight > height {
            details.append("HiDPI")
        }
        if refreshRate > 0 {
            let rounded = refreshRate.rounded()
            let rate = abs(refreshRate - rounded) < 0.01
                ? String(Int(rounded))
                : String(format: "%.2f", refreshRate)
            details.append("\(rate) Hz")
        }
        let suffix = details.isEmpty ? "" : " · " + details.joined(separator: " · ")
        return "\(width) × \(height)\(suffix)"
    }

    func describesSameMode(as other: DisplayModeInfo) -> Bool {
        let refreshMatches = refreshRate == 0
            || other.refreshRate == 0
            || abs(refreshRate - other.refreshRate) < 0.02
        return width == other.width
            && height == other.height
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && refreshMatches
    }
}

private struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let active: Bool
    let builtin: Bool
    let identity: String
    let currentMode: DisplayModeInfo?
    let availableModes: [DisplayModeInfo]
}

private struct StoredDisplay: Codable {
    let id: CGDirectDisplayID
    let name: String
    let builtin: Bool
    let identity: String

    init(_ display: DisplayInfo) {
        id = display.id
        name = display.name
        builtin = display.builtin
        identity = display.identity
    }

    var displayInfo: DisplayInfo {
        DisplayInfo(
            id: id,
            name: name,
            active: false,
            builtin: builtin,
            identity: identity,
            currentMode: nil,
            availableModes: []
        )
    }
}

private struct DisplayPresetEntry: Codable, Equatable {
    var identity: String
    var name: String
    var enabled: Bool
    var brightness: Double
    var contrast: Double
    var mode: DisplayModeInfo?
}

private struct DisplayPreset: Codable, Equatable {
    var name: String
    var displays: [DisplayPresetEntry]
}

private struct PresetCollection: Codable, Equatable {
    var presetA: DisplayPreset
    var presetB: DisplayPreset
}

private struct AppFailure: Error {
    let message: String
}

private final class DisplayController {
    private let storageKey = "knownDisplaysV1"

    func displays() -> [DisplayInfo] {
        var online: [DisplayInfo] = []
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = Array(repeating: CGDirectDisplayID(), count: Int(count))
            if CGGetOnlineDisplayList(count, &ids, &count) == .success {
                online = ids.prefix(Int(count)).map { id in
                    let builtin = CGDisplayIsBuiltin(id) != 0
                    return DisplayInfo(
                        id: id,
                        name: displayName(id),
                        active: CGDisplayIsActive(id) != 0,
                        builtin: builtin,
                        identity: displayIdentity(id, builtin: builtin),
                        currentMode: CGDisplayCopyDisplayMode(id).map(DisplayModeInfo.init),
                        availableModes: displayModes(id)
                    )
                }
            }
        }

        var stored = loadStoredDisplays()
        for display in online {
            if let index = stored.firstIndex(where: { $0.identity == display.identity || $0.id == display.id }) {
                stored[index] = StoredDisplay(display)
            } else {
                stored.append(StoredDisplay(display))
            }
        }
        saveStoredDisplays(stored)

        let onlineIdentities = Set(online.map(\.identity))
        let remembered = stored.filter { !onlineIdentities.contains($0.identity) }.map(\.displayInfo)
        return (online + remembered).sorted {
            if $0.active != $1.active { return $0.active }
            if $0.builtin != $1.builtin { return $0.builtin }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Result<Void, AppFailure> {
        let current = displays()
        if !enabled && current.filter(\.active).count <= 1 {
            return .failure(AppFailure(message: "为避免黑屏，不能断开最后一块正在使用的屏幕。"))
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            return .failure(AppFailure(message: "无法开始修改显示器配置（错误 \(begin.rawValue)）。"))
        }

        let change = CGSConfigureDisplayEnabled(config, displayID, enabled)
        guard change == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(AppFailure(message: "macOS 拒绝了这次切换（错误 \(change.rawValue)）。如果屏幕已拔线，请重新插线后再试。"))
        }

        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            return .failure(AppFailure(message: "显示器配置未能保存（错误 \(complete.rawValue)）。"))
        }
        return .success(())
    }

    func setMode(_ requested: DisplayModeInfo, displayID: CGDirectDisplayID) -> Result<Void, AppFailure> {
        guard CGDisplayIsActive(displayID) != 0 else {
            return .failure(AppFailure(message: "显示器尚未连接，无法设置分辨率。"))
        }

        let modes = rawDisplayModes(displayID).filter { $0.isUsableForDesktopGUI() }
        let logicalMatches = modes.filter {
            let candidate = DisplayModeInfo($0)
            return candidate.width == requested.width && candidate.height == requested.height
        }
        guard let mode = logicalMatches.first(where: { DisplayModeInfo($0).describesSameMode(as: requested) })
                ?? logicalMatches.min(by: {
                    modeDistance(DisplayModeInfo($0), from: requested)
                        < modeDistance(DisplayModeInfo($1), from: requested)
                }) else {
            return .failure(AppFailure(message: "找不到已保存的分辨率 \(requested.label)。"))
        }

        if let current = CGDisplayCopyDisplayMode(displayID),
           DisplayModeInfo(current).describesSameMode(as: DisplayModeInfo(mode)) {
            return .success(())
        }

        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            return .failure(AppFailure(message: "无法开始修改分辨率（错误 \(begin.rawValue)）。"))
        }

        let change = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        guard change == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(AppFailure(message: "macOS 拒绝了分辨率 \(requested.label)（错误 \(change.rawValue)）。"))
        }

        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else {
            return .failure(AppFailure(message: "分辨率配置未能保存（错误 \(complete.rawValue)）。"))
        }
        return .success(())
    }

    private func modeDistance(_ candidate: DisplayModeInfo, from requested: DisplayModeInfo) -> Double {
        let pixelDifference = abs(candidate.pixelWidth - requested.pixelWidth)
            + abs(candidate.pixelHeight - requested.pixelHeight)
        let refreshDifference: Double
        if candidate.refreshRate == 0 || requested.refreshRate == 0 {
            refreshDifference = 0
        } else {
            refreshDifference = abs(candidate.refreshRate - requested.refreshRate)
        }
        return Double(pixelDifference) * 1_000 + refreshDifference
    }

    private func displayModes(_ id: CGDirectDisplayID) -> [DisplayModeInfo] {
        var seen = Set<String>()
        return rawDisplayModes(id)
            .filter { $0.isUsableForDesktopGUI() }
            .map(DisplayModeInfo.init)
            .filter { mode in
                let refreshKey = Int((mode.refreshRate * 100).rounded())
                let key = "\(mode.width)x\(mode.height)-\(mode.pixelWidth)x\(mode.pixelHeight)-\(refreshKey)"
                return seen.insert(key).inserted
            }
            .sorted {
                if $0.width != $1.width { return $0.width < $1.width }
                if $0.height != $1.height { return $0.height < $1.height }
                if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth < $1.pixelWidth }
                return $0.refreshRate < $1.refreshRate
            }
    }

    private func rawDisplayModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    private func displayIdentity(_ id: CGDirectDisplayID, builtin: Bool) -> String {
        [
            builtin ? "builtin" : "external",
            String(CGDisplayVendorNumber(id)),
            String(CGDisplayModelNumber(id)),
            String(CGDisplaySerialNumber(id)),
            String(CGDisplayUnitNumber(id))
        ].joined(separator: "-")
    }

    private func loadStoredDisplays() -> [StoredDisplay] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([StoredDisplay].self, from: data) else { return [] }
        return value
    }

    private func saveStoredDisplays(_ displays: [StoredDisplay]) {
        guard let data = try? JSONEncoder().encode(displays) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func displayName(_ id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            return screen.localizedName
        }
        return CGDisplayIsBuiltin(id) != 0 ? "内置显示器" : "外接显示器 \(id)"
    }
}

private final class PresetStore {
    private let storageKey = "displayPresetsV2"

    func load(displays: [DisplayInfo]) -> PresetCollection {
        let decoded: PresetCollection?
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            decoded = try? JSONDecoder().decode(PresetCollection.self, from: data)
        } else {
            decoded = nil
        }

        var collection = decoded ?? PresetCollection(
            presetA: DisplayPreset(name: "预设 A", displays: []),
            presetB: DisplayPreset(name: "预设 B", displays: [])
        )
        let original = collection
        synchronize(&collection.presetA, with: displays, defaultBrightness: legacyBrightness("presetA", fallback: 0.35))
        synchronize(&collection.presetB, with: displays, defaultBrightness: legacyBrightness("presetB", fallback: 0.80))
        if collection != original || decoded == nil {
            save(collection)
        }
        return collection
    }

    func save(_ collection: PresetCollection) {
        guard let data = try? JSONEncoder().encode(collection) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func synchronize(_ preset: inout DisplayPreset, with displays: [DisplayInfo], defaultBrightness: Double) {
        for display in displays {
            if let index = preset.displays.firstIndex(where: { $0.identity == display.identity }) {
                preset.displays[index].name = display.name
                if preset.displays[index].mode == nil {
                    preset.displays[index].mode = display.currentMode
                }
            } else {
                preset.displays.append(DisplayPresetEntry(
                    identity: display.identity,
                    name: display.name,
                    enabled: display.active,
                    brightness: defaultBrightness,
                    contrast: 0,
                    mode: display.currentMode
                ))
            }
        }
        preset.displays.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func legacyBrightness(_ key: String, fallback: Double) -> Double {
        guard let number = UserDefaults.standard.object(forKey: key) as? NSNumber else { return fallback }
        return min(max(number.doubleValue, 0), 1)
    }
}

private final class BetterDisplayBridge {
    private let requestName = Notification.Name("pro.betterdisplay.BetterDisplay.request")

    func setVisualSettings(
        brightness: Double,
        contrast: Double,
        displayID: CGDirectDisplayID
    ) -> Result<Void, AppFailure> {
        let payload: [String: Any] = [
            "uuid": UUID().uuidString,
            "commands": ["set"],
            "parameters": [
                "displayID": String(displayID),
                "brightness": String(format: "%.3f", brightness),
                "contrast": String(format: "%.3f", contrast)
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(AppFailure(message: "无法生成 BetterDisplay 指令。"))
        }
        DistributedNotificationCenter.default().postNotificationName(
            requestName,
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
        return .success(())
    }

    func openApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/BetterDisplay.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private final class DisplayPresetRowView: NSBox {
    private var entry: DisplayPresetEntry
    private var modes: [DisplayModeInfo]
    private let enabledButton: NSButton
    private let brightnessSlider: NSSlider
    private let contrastSlider: NSSlider
    private let brightnessValue = NSTextField(labelWithString: "")
    private let contrastValue = NSTextField(labelWithString: "")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var onChange: ((DisplayPresetEntry) -> Void)?

    init(display: DisplayInfo, entry: DisplayPresetEntry) {
        self.entry = entry
        modes = display.availableModes
        if let savedMode = entry.mode,
           !modes.contains(where: { $0.describesSameMode(as: savedMode) }) {
            modes.append(savedMode)
        }

        enabledButton = NSButton(checkboxWithTitle: display.name, target: nil, action: nil)
        brightnessSlider = NSSlider(value: entry.brightness * 100, minValue: 0, maxValue: 100, target: nil, action: nil)
        contrastSlider = NSSlider(value: entry.contrast * 100, minValue: -90, maxValue: 90, target: nil, action: nil)
        super.init(frame: .zero)

        boxType = .custom
        borderColor = .separatorColor
        borderWidth = 1
        cornerRadius = 9
        contentViewMargins = NSSize(width: 14, height: 12)
        titlePosition = .noTitle
        buildUI(display: display)
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildUI(display: DisplayInfo) {
        guard let contentView else { return }
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        enabledButton.font = .systemFont(ofSize: 14, weight: .semibold)

        let status = NSTextField(labelWithString: display.active ? "当前已开启" : "当前已关闭")
        status.textColor = .secondaryLabelColor
        status.alignment = .right

        let header = NSStackView(views: [enabledButton, status])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        contrastSlider.target = self
        contrastSlider.action = #selector(contrastChanged)
        for value in [brightnessValue, contrastValue] {
            value.alignment = .right
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.removeAllItems()
        if modes.isEmpty {
            modePopup.addItem(withTitle: "未记录（连接显示器后可选择）")
        } else {
            for mode in modes {
                let isUnavailable = !display.availableModes.contains(where: { $0.describesSameMode(as: mode) })
                modePopup.addItem(withTitle: mode.label + (isUnavailable ? " · 当前不可用" : ""))
            }
            if let selected = entry.mode,
               let index = modes.firstIndex(where: { $0.describesSameMode(as: selected) }) {
                modePopup.selectItem(at: index)
            } else if let current = display.currentMode,
                      let index = modes.firstIndex(where: { $0.describesSameMode(as: current) }) {
                modePopup.selectItem(at: index)
                entry.mode = modes[index]
            }
        }

        let grid = NSGridView(views: [
            [fieldLabel("亮度"), brightnessSlider, brightnessValue],
            [fieldLabel("对比度调整"), contrastSlider, contrastValue],
            [fieldLabel("分辨率"), modePopup, NSView()]
        ])
        grid.column(at: 0).width = 88
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).width = 54
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let hint = NSTextField(wrappingLabelWithString: "对比度 0% 为默认；负值更柔和，正值更强烈。")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [header, grid, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        return label
    }

    private func updateControls() {
        enabledButton.state = entry.enabled ? .on : .off
        brightnessSlider.doubleValue = entry.brightness * 100
        contrastSlider.doubleValue = entry.contrast * 100
        brightnessValue.stringValue = "\(Int(brightnessSlider.doubleValue.rounded()))%"
        let contrast = Int(contrastSlider.doubleValue.rounded())
        contrastValue.stringValue = contrast > 0 ? "+\(contrast)%" : "\(contrast)%"
        brightnessSlider.isEnabled = entry.enabled
        contrastSlider.isEnabled = entry.enabled
        modePopup.isEnabled = entry.enabled && !modes.isEmpty
    }

    private func publishChange() {
        updateControls()
        onChange?(entry)
    }

    @objc private func enabledChanged() {
        entry.enabled = enabledButton.state == .on
        publishChange()
    }

    @objc private func brightnessChanged() {
        entry.brightness = brightnessSlider.doubleValue / 100
        publishChange()
    }

    @objc private func contrastChanged() {
        entry.contrast = contrastSlider.doubleValue / 100
        publishChange()
    }

    @objc private func modeChanged() {
        let index = modePopup.indexOfSelectedItem
        if modes.indices.contains(index) {
            entry.mode = modes[index]
            publishChange()
        }
    }
}

private final class PresetWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: PresetStore
    private let displayProvider: () -> [DisplayInfo]
    private let segmented = NSSegmentedControl(labels: ["预设 A", "预设 B"], trackingMode: .selectOne, target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    private let listStack = NSStackView()
    private var displays: [DisplayInfo] = []
    private var draft = PresetCollection(
        presetA: DisplayPreset(name: "预设 A", displays: []),
        presetB: DisplayPreset(name: "预设 B", displays: [])
    )
    var onSave: (() -> Void)?

    init(store: PresetStore, displayProvider: @escaping () -> [DisplayInfo]) {
        self.store = store
        self.displayProvider = displayProvider
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 690, height: 590),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "编辑显示器预设"
        window.minSize = NSSize(width: 620, height: 440)
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        displays = displayProvider()
        draft = store.load(displays: displays)
        if segmented.selectedSegment < 0 { segmented.selectedSegment = 0 }
        updateSegmentLabels()
        rebuildRows()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged)

        let nameLabel = NSTextField(labelWithString: "名称")
        nameField.placeholderString = "输入预设名称"
        nameField.delegate = self
        let header = NSStackView(views: [segmented, nameLabel, nameField])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        let description = NSTextField(wrappingLabelWithString: "为每块显示器分别保存开关状态、亮度、对比度调整和分辨率。菜单栏中可用 ⌘1 / ⌘2 一键切换。")
        description.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 2),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -10),
            listStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document

        let save = NSButton(title: "保存", target: self, action: #selector(savePressed))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelPressed))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [header, description, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            segmented.widthAnchor.constraint(equalToConstant: 250),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),

            description.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            description.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            description.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
    }

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let preset = selectedPreset
        nameField.stringValue = preset.name
        if displays.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "未检测到显示器。连接显示器后重新打开此窗口。")
            empty.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        for display in displays {
            guard let entry = preset.displays.first(where: { $0.identity == display.identity }) else { continue }
            let row = DisplayPresetRowView(display: display, entry: entry)
            row.onChange = { [weak self] updated in
                self?.updateSelectedPresetEntry(updated)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private var selectedPreset: DisplayPreset {
        segmented.selectedSegment == 1 ? draft.presetB : draft.presetA
    }

    private func updateSelectedPresetEntry(_ entry: DisplayPresetEntry) {
        if segmented.selectedSegment == 1 {
            guard let index = draft.presetB.displays.firstIndex(where: { $0.identity == entry.identity }) else { return }
            draft.presetB.displays[index] = entry
        } else {
            guard let index = draft.presetA.displays.firstIndex(where: { $0.identity == entry.identity }) else { return }
            draft.presetA.displays[index] = entry
        }
    }

    @objc private func segmentChanged() { rebuildRows() }

    func controlTextDidChange(_ notification: Notification) {
        if segmented.selectedSegment == 1 {
            draft.presetB.name = nameField.stringValue
        } else {
            draft.presetA.name = nameField.stringValue
        }
        updateSegmentLabels()
    }

    private func updateSegmentLabels() {
        let nameA = draft.presetA.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameB = draft.presetB.name.trimmingCharacters(in: .whitespacesAndNewlines)
        segmented.setLabel(nameA.isEmpty ? "预设 A" : nameA, forSegment: 0)
        segmented.setLabel(nameB.isEmpty ? "预设 B" : nameB, forSegment: 1)
    }

    @objc private func savePressed() {
        draft.presetA.name = draft.presetA.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.presetB.name = draft.presetB.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.presetA.name.isEmpty { draft.presetA.name = "预设 A" }
        if draft.presetB.name.isEmpty { draft.presetB.name = "预设 B" }
        guard draft.presetA.displays.contains(where: \.enabled),
              draft.presetB.displays.contains(where: \.enabled) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "每个预设至少要开启一块显示器"
            alert.informativeText = "这样可以避免应用预设后出现黑屏。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        store.save(draft)
        UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
        window?.close()
        onSave?()
    }

    @objc private func cancelPressed() { window?.close() }
}

private final class PresetApplicationContext {
    let preset: DisplayPreset
    let slot: String
    var errors: [String] = []
    var enableFailures: [String: String] = [:]
    var modeFailures: [String: String] = [:]
    var disableFailures: [String: String] = [:]

    init(preset: DisplayPreset, slot: String) {
        self.preset = preset
        self.slot = slot
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let displayController = DisplayController()
    private let presetStore = PresetStore()
    private let betterDisplay = BetterDisplayBridge()
    private var statusItem: NSStatusItem!
    private var presetWindow: PresetWindowController!
    private var applyingPreset = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["presetA": 0.35, "presetB": 0.80])
        presetWindow = PresetWindowController(store: presetStore) { [weak self] in
            self?.displayController.displays() ?? []
        }
        presetWindow.onSave = { [weak self] in self?.rebuildMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Pilot")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "显示器连接", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let displays = displayController.displays()
        if displays.isEmpty {
            let empty = NSMenuItem(title: "未检测到显示器", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in displays {
                let state = display.active ? "已连接" : "已断开"
                let item = NSMenuItem(title: "\(display.name) · \(state)", action: #selector(toggleDisplay(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: display.id)
                item.state = display.active ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let presets = presetStore.load(displays: displays)
        let lastApplied = UserDefaults.standard.string(forKey: "lastAppliedPreset")
        let a = actionItem(presetMenuTitle(presets.presetA), #selector(applyPresetA), key: "1")
        let b = actionItem(presetMenuTitle(presets.presetB), #selector(applyPresetB), key: "2")
        a.state = lastApplied == "A" ? .on : .off
        b.state = lastApplied == "B" ? .on : .off
        a.isEnabled = !applyingPreset
        b.isEnabled = !applyingPreset
        menu.addItem(a)
        menu.addItem(b)
        if applyingPreset {
            let progress = NSMenuItem(title: "正在应用预设…", action: nil, keyEquivalent: "")
            progress.isEnabled = false
            menu.addItem(progress)
        }
        menu.addItem(actionItem("编辑预设…", #selector(openPresetSettings)))

        menu.addItem(.separator())
        menu.addItem(actionItem("刷新显示器", #selector(refresh), key: "r"))
        menu.addItem(actionItem("打开 BetterDisplay", #selector(openBetterDisplay)))
        menu.addItem(launchAtLoginMenuItem())
        menu.addItem(.separator())
        menu.addItem(actionItem("退出 Display Pilot", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func presetMenuTitle(_ preset: DisplayPreset) -> String {
        preset.name
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let display = displayController.displays().first(where: { $0.id == id }) else { return }
        switch displayController.setEnabled(!display.active, displayID: id) {
        case .success:
            UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rebuildMenu() }
        case .failure(let error):
            showError(error.message)
        }
    }

    @objc private func applyPresetA() { applyPreset(slot: "A") }
    @objc private func applyPresetB() { applyPreset(slot: "B") }

    private func applyPreset(slot: String) {
        guard !applyingPreset else { return }
        let displays = displayController.displays()
        let collection = presetStore.load(displays: displays)
        let preset = slot == "B" ? collection.presetB : collection.presetA
        guard preset.displays.contains(where: \.enabled) else {
            showError("\(preset.name) 没有设置要开启的显示器，请先编辑预设。")
            return
        }

        applyingPreset = true
        rebuildMenu()
        let context = PresetApplicationContext(preset: preset, slot: slot)
        requestTargetConnections(context)
        waitForTargetDisplays(context, attempt: 0, stableSignature: nil, stableCount: 0)
    }

    private func requestTargetConnections(_ context: PresetApplicationContext) {
        for entry in context.preset.displays where entry.enabled {
            let displays = displayController.displays()
            guard let display = displays.first(where: { $0.identity == entry.identity }) else {
                context.enableFailures[entry.identity] = "没有找到这块显示器"
                continue
            }
            guard !display.active else { continue }
            if case .failure(let error) = displayController.setEnabled(true, displayID: display.id) {
                context.enableFailures[entry.identity] = error.message
            }
        }
    }

    private func waitForTargetDisplays(
        _ context: PresetApplicationContext,
        attempt: Int,
        stableSignature: String?,
        stableCount: Int
    ) {
        let displays = displayController.displays()
        let targets = context.preset.displays.filter(\.enabled)
        let resolved = targets.compactMap { entry in
            displays.first(where: { $0.identity == entry.identity && $0.active })
        }
        let allReady = resolved.count == targets.count && resolved.allSatisfy { !$0.availableModes.isEmpty }
        let signature = resolved
            .sorted { $0.identity < $1.identity }
            .map { "\($0.identity):\($0.id):\($0.currentMode?.modeID ?? -1)" }
            .joined(separator: "|")
        let nextStableCount = allReady && signature == stableSignature ? stableCount + 1 : (allReady ? 1 : 0)

        if allReady && nextStableCount >= 2 {
            applyModePass(context, attempt: 1)
            return
        }

        if attempt < 12 {
            if attempt > 0 && attempt.isMultiple(of: 2) {
                requestTargetConnections(context)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                self?.waitForTargetDisplays(
                    context,
                    attempt: attempt + 1,
                    stableSignature: allReady ? signature : nil,
                    stableCount: nextStableCount
                )
            }
            return
        }

        for entry in targets where !resolved.contains(where: { $0.identity == entry.identity }) {
            let reason = context.enableFailures[entry.identity] ?? "等待显示器响应超时"
            context.errors.append("\(entry.name)：\(reason)")
        }
        guard !resolved.isEmpty else {
            context.errors.append("没有任何预设中要开启的显示器成功连接；为避免黑屏，未关闭当前屏幕")
            completePresetApplication(context)
            return
        }
        applyModePass(context, attempt: 1)
    }

    private func applyModePass(_ context: PresetApplicationContext, attempt: Int) {
        requestTargetConnections(context)
        for entry in context.preset.displays where entry.enabled && entry.mode != nil {
            let displays = displayController.displays()
            guard let display = displays.first(where: { $0.identity == entry.identity && $0.active }),
                  let requestedMode = entry.mode else { continue }
            if display.currentMode?.describesSameMode(as: requestedMode) == true { continue }
            if case .failure(let error) = displayController.setMode(requestedMode, displayID: display.id) {
                context.modeFailures[entry.identity] = error.message
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.verifyModes(context, attempt: attempt)
        }
    }

    private func verifyModes(_ context: PresetApplicationContext, attempt: Int) {
        let displays = displayController.displays()
        let pending = context.preset.displays.filter { entry in
            guard entry.enabled, let mode = entry.mode else { return false }
            guard let display = displays.first(where: { $0.identity == entry.identity && $0.active }) else { return true }
            return display.currentMode?.describesSameMode(as: mode) != true
        }

        if pending.isEmpty {
            applyVisualSettings(context, pass: 1)
        } else if attempt < 5 {
            applyModePass(context, attempt: attempt + 1)
        } else {
            for entry in pending {
                let isActive = displays.contains(where: { $0.identity == entry.identity && $0.active })
                let reason = context.modeFailures[entry.identity]
                    ?? (isActive
                        ? "设置后仍未切换到保存的分辨率 \(entry.mode?.label ?? "")"
                        : "应用过程中显示器失去连接")
                context.errors.append("\(entry.name)：\(reason)")
            }
            applyVisualSettings(context, pass: 1)
        }
    }

    private func applyVisualSettings(_ context: PresetApplicationContext, pass: Int) {
        let displays = displayController.displays()
        for entry in context.preset.displays where entry.enabled {
            guard let display = displays.first(where: { $0.identity == entry.identity && $0.active }) else { continue }
            if case .failure(let error) = betterDisplay.setVisualSettings(
                brightness: entry.brightness,
                contrast: entry.contrast,
                displayID: display.id
            ), pass == 2 {
                context.errors.append("\(entry.name)：\(error.message)")
            }
        }

        if pass == 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.applyVisualSettings(context, pass: 2)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.disableUnwantedDisplays(context, attempt: 1)
            }
        }
    }

    private func disableUnwantedDisplays(_ context: PresetApplicationContext, attempt: Int) {
        let currentDisplays = displayController.displays()
        let hasActiveTarget = context.preset.displays.contains { entry in
            entry.enabled && currentDisplays.contains(where: { $0.identity == entry.identity && $0.active })
        }
        guard hasActiveTarget else {
            context.errors.append("预设中的目标显示器已失去连接；为避免黑屏，未关闭当前屏幕")
            completePresetApplication(context)
            return
        }

        let unwanted = context.preset.displays.filter { !$0.enabled }
        for entry in unwanted {
            let displays = displayController.displays()
            guard let display = displays.first(where: { $0.identity == entry.identity && $0.active }) else { continue }
            if case .failure(let error) = displayController.setEnabled(false, displayID: display.id) {
                context.disableFailures[entry.identity] = error.message
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let displays = self.displayController.displays()
            let remaining = unwanted.filter { entry in
                displays.contains(where: { $0.identity == entry.identity && $0.active })
            }
            if !remaining.isEmpty && attempt < 3 {
                self.disableUnwantedDisplays(context, attempt: attempt + 1)
                return
            }
            for entry in remaining {
                let reason = context.disableFailures[entry.identity] ?? "显示器没有按预设断开"
                context.errors.append("\(entry.name)：\(reason)")
            }
            self.completePresetApplication(context)
        }
    }

    private func completePresetApplication(_ context: PresetApplicationContext) {
        applyingPreset = false
        if context.errors.isEmpty {
            UserDefaults.standard.set(context.slot, forKey: "lastAppliedPreset")
        } else {
            UserDefaults.standard.removeObject(forKey: "lastAppliedPreset")
            showError(context.errors.joined(separator: "\n"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.rebuildMenu() }
    }

    private func launchAtLoginMenuItem() -> NSMenuItem {
        let service = SMAppService.mainApp
        let title: String
        switch service.status {
        case .requiresApproval:
            title = "开机自启动（需在系统设置中允许）"
        default:
            title = "开机自启动"
        }
        let item = actionItem(title, #selector(toggleLaunchAtLogin))
        item.state = service.status == .enabled ? .on : (service.status == .requiresApproval ? .mixed : .off)
        return item
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            @unknown default:
                try service.register()
            }
            rebuildMenu()
        } catch {
            showError("无法修改开机自启动设置：\(error.localizedDescription)")
        }
    }

    @objc private func openPresetSettings() { presetWindow.present() }
    @objc private func refresh() { rebuildMenu() }
    @objc private func openBetterDisplay() { betterDisplay.openApp() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作没有完成"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private let application = NSApplication.shared
private let applicationDelegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
