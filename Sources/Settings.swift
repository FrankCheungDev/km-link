import AppKit

/// Settings panel for switching, clipboard and file behavior.
final class SettingsWindowController: NSWindowController {
    private let model: AppModel

    private let edgeCheck = NSButton(checkboxWithTitle: "Switch when the pointer leaves the screen edge", target: nil, action: nil)
    private let middleCheck = NSButton(checkboxWithTitle: "Switch with the middle mouse button", target: nil, action: nil)
    private let cornerCheck = NSButton(checkboxWithTitle: "Switch from the top-left hot corner", target: nil, action: nil)
    private let toleranceSlider = NSSlider(value: 1, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let sensitivitySlider = NSSlider(value: 1, minValue: 0.25, maxValue: 2.5, target: nil, action: nil)
    private let toleranceLabel = NSTextField(labelWithString: "1 px")
    private let sensitivityLabel = NSTextField(labelWithString: "1.00×")

    private let clipboardSendCheck = NSButton(checkboxWithTitle: "Send this Mac's clipboard", target: nil, action: nil)
    private let clipboardReceiveCheck = NSButton(checkboxWithTitle: "Receive the other PC's clipboard", target: nil, action: nil)
    private let blockSendCheck = NSButton(checkboxWithTitle: "Block outgoing file transfers", target: nil, action: nil)

    private let hostModeCheck = NSButton(checkboxWithTitle: "Host mode: forward this Mac's mouse to the other PC", target: nil, action: nil)
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "Launch KMLink when I log in", target: nil, action: nil)
    private let autoConnectCheck = NSButton(checkboxWithTitle: "Connect automatically when the bridge is attached", target: nil, action: nil)

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "KMLink Settings"
        super.init(window: window)
        build()
        loadValues()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        root.addArrangedSubview(section("STARTUP"))
        for control in [launchAtLoginCheck, autoConnectCheck] {
            control.target = self
            control.action = #selector(changed)
            root.addArrangedSubview(control)
        }

        root.addArrangedSubview(hostModeCheck)
        let hostHint = NSTextField(wrappingLabelWithString:
            "On (default): when the pointer leaves this screen, KMLink reads the local mouse and sends it over "
            + "the bridge — needed for the Mac's own trackpad or mouse to drive the other PC. "
            + "Off: only announce that control moved and stay passive, e.g. when the physical mouse is attached "
            + "to the other PC or behind a hardware switch.")
        hostHint.font = .systemFont(ofSize: 11)
        hostHint.textColor = .secondaryLabelColor
        hostHint.preferredMaxLayoutWidth = 440
        root.addArrangedSubview(hostHint)

        root.addArrangedSubview(section("SWITCHING"))

        for control in [edgeCheck, middleCheck, cornerCheck] {
            control.target = self
            control.action = #selector(changed)
            root.addArrangedSubview(control)
        }

        root.addArrangedSubview(sliderRow(title: "Edge tolerance", slider: toleranceSlider, value: toleranceLabel))
        root.addArrangedSubview(sliderRow(title: "Pointer speed", slider: sensitivitySlider, value: sensitivityLabel))
        let speedHint = NSTextField(wrappingLabelWithString:
            "1.00× keeps the macOS default. Below 1.00× slows the pointer of the bridge's "
            + "virtual mouse (the one that moves while the other PC is controlling this Mac); "
            + "above 1.00× speeds it up.")
        speedHint.font = .systemFont(ofSize: 11)
        speedHint.textColor = .secondaryLabelColor
        speedHint.preferredMaxLayoutWidth = 440
        root.addArrangedSubview(speedHint)

        root.addArrangedSubview(section("CLIPBOARD"))
        for control in [clipboardSendCheck, clipboardReceiveCheck] {
            control.target = self
            control.action = #selector(changed)
            root.addArrangedSubview(control)
        }

        root.addArrangedSubview(section("FILES"))
        blockSendCheck.target = self
        blockSendCheck.action = #selector(changed)
        root.addArrangedSubview(blockSendCheck)

        let hint = NSTextField(wrappingLabelWithString:
            "Edge switching uses the screen side chosen in the main window. The hot corner is the top-left 24×24 px of the virtual desktop.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        root.addArrangedSubview(hint)

        let close = NSButton(title: "Done", target: self, action: #selector(closePanel))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        root.addArrangedSubview(close)

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 540))
        container.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])
        window?.contentView = container
        window?.setContentSize(NSSize(width: 500, height: 540))
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func sliderRow(title: String, slider: NSSlider, value: NSTextField) -> NSView {
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func loadValues() {
        let settings = AppSettings.shared
        hostModeCheck.state = settings.forwardLocalInput ? .on : .off
        hostModeCheck.target = self
        hostModeCheck.action = #selector(changed)
        launchAtLoginCheck.state = settings.launchAtLogin ? .on : .off
        autoConnectCheck.state = settings.autoConnectUSB ? .on : .off
        edgeCheck.state = settings.edgeSwitchingEnabled ? .on : .off
        middleCheck.state = settings.middleButtonSwitch ? .on : .off
        cornerCheck.state = settings.hotCornerSwitch ? .on : .off
        toleranceSlider.doubleValue = settings.edgeTolerance
        sensitivitySlider.doubleValue = settings.mouseSensitivity
        clipboardSendCheck.state = settings.clipboardSendEnabled ? .on : .off
        clipboardReceiveCheck.state = settings.clipboardReceiveEnabled ? .on : .off
        blockSendCheck.state = settings.blockFileSending ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        toleranceLabel.stringValue = "\(Int(toleranceSlider.doubleValue.rounded())) px"
        sensitivityLabel.stringValue = String(format: "%.2f×", sensitivitySlider.doubleValue)
    }

    @objc private func changed() {
        let settings = AppSettings.shared
        settings.edgeSwitchingEnabled = edgeCheck.state == .on
        settings.middleButtonSwitch = middleCheck.state == .on
        settings.hotCornerSwitch = cornerCheck.state == .on
        settings.edgeTolerance = toleranceSlider.doubleValue.rounded()
        settings.mouseSensitivity = sensitivitySlider.doubleValue
        settings.clipboardSendEnabled = clipboardSendCheck.state == .on
        settings.clipboardReceiveEnabled = clipboardReceiveCheck.state == .on
        settings.blockFileSending = blockSendCheck.state == .on
        let wantLaunch = launchAtLoginCheck.state == .on
        if wantLaunch != settings.launchAtLogin {
            settings.launchAtLogin = wantLaunch
            let mechanism = LaunchAtLogin.setEnabled(wantLaunch)
            model.appendLog("Launch at login: \(mechanism)")
        }
        settings.forwardLocalInput = hostModeCheck.state == .on
        settings.autoConnectUSB = autoConnectCheck.state == .on
        updateLabels()
        model.applySettings()
    }

    @objc private func closePanel() {
        window?.orderOut(nil)
    }
}
