import Cocoa

/// Settings window: a slider plus text field per glass property, and a color well plus hex
/// field per color. Built when opened and released when closed, so it costs nothing in between.
/// Every change applies live to a preview of the real search panel shown above the window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let onChange: () -> Void
    private let showPreview: () -> NSRect?
    private let hidePreview: () -> Void
    private var window: NSWindow?
    private var grid: NSGridView!
    private var refreshers: [() -> Void] = []
    private var handlers: [ActionHandler] = []

    init(onChange: @escaping () -> Void, showPreview: @escaping () -> NSRect?, hidePreview: @escaping () -> Void) {
        self.onChange = onChange
        self.showPreview = showPreview
        self.hidePreview = hidePreview
    }

    var isOpen: Bool { window != nil }

    func show() {
        if let window {
            // Already open: just bring it forward, leave both windows where the user put them.
            bringToFront(window)
            return
        }
        let window = makeWindow()
        self.window = window
        let preview = showPreview()
        // Reuse the position the user last dragged it to; first time, sit just under the preview.
        if !window.setFrameUsingName(Self.frameName) {
            if let preview { position(window, below: preview) } else { window.center() }
        }
        window.setFrameAutosaveName(Self.frameName)
        bringToFront(window)
    }

    private static let frameName = "GlasslightSettings"

    /// Floating level keeps it above other apps' windows even when macOS declines to activate
    /// a background app like this one.
    private func bringToFront(_ window: NSWindow) {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        hidePreview()
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        window = nil
        grid = nil
        refreshers = []
        handlers = []
    }

    // MARK: Building

    private func makeWindow() -> NSWindow {
        grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        addHeader("Glass", first: true)
        addSlider("Variant", 0...23, ticks: 24, get: { Double(Appearance.variant) }, set: { Appearance.variant = Int($0) })
        addSlider("Distortion", 0...3, ticks: 4, get: { Double(Appearance.lensing) }, set: { Appearance.lensing = Int($0) })
        addSlider("Corner radius", 0...Appearance.maxCornerRadius, get: { Appearance.cornerRadius }, set: { Appearance.cornerRadius = $0 })
        addColor("Tint color", get: Appearance.effectiveTintColor, set: { Appearance.tintColor = $0 })
        addSlider("Tint opacity (%)", 0...100, get: { Appearance.tintOpacity * 100 }, set: { Appearance.tintOpacity = $0 / 100 })

        addHeader("Colors")
        addColor("Text color", get: Appearance.effectiveTextColor, set: { Appearance.textColor = $0 })
        addColor("Selection color", get: Appearance.effectiveSelectionColor, set: { Appearance.selectionColor = $0 })
        addSlider("Selection opacity (%)", 0...100, get: { Appearance.effectiveSelectionOpacity(in: NSApp.effectiveAppearance) * 100 },
                  set: { Appearance.selectionOpacity = $0 / 100 })

        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 2).width = 76

        let note = NSTextField(wrappingLabelWithString: "Variant and Distortion use private macOS glass settings; some variants ignore the tint. Changes apply instantly.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300

        let reset = NSButton(title: "Reset to Defaults", target: nil, action: nil)
        bind(reset) { [weak self] in
            Appearance.reset()
            self?.refreshers.forEach { $0() }
            self?.onChange()
        }
        let footer = NSStackView(views: [note, reset])
        footer.alignment = .centerY
        footer.distribution = .fill
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [grid, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        footer.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let window = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Glasslight Settings"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        return window
    }

    private func addHeader(_ title: String, first: Bool = false) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = grid.addRow(with: [label])
        row.mergeCells(in: NSRange(location: 0, length: 3))
        if !first { row.topPadding = 8 }
    }

    private func addSlider(_ title: String, _ range: ClosedRange<Double>, ticks: Int = 0,
                           get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        let slider = NSSlider(value: range.lowerBound, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        if ticks > 0 {
            slider.numberOfTickMarks = ticks
            slider.allowsTickMarkValuesOnly = true
        }
        slider.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let field = numberField()

        let refresh = {
            let value = get().rounded()
            slider.doubleValue = value
            field.stringValue = String(Int(value))
        }
        bind(slider) { [onChange] in
            let value = slider.doubleValue.rounded()
            set(value)
            field.stringValue = String(Int(value))
            onChange()
        }
        bind(field) { [onChange] in
            guard let typed = Double(field.stringValue.trimmingCharacters(in: .whitespaces)) else { return refresh() }
            let value = typed.rounded().clamped(range.lowerBound, range.upperBound)
            set(value)
            refresh()
            onChange()
        }
        refreshers.append(refresh)
        refresh()
        grid.addRow(with: [NSTextField(labelWithString: title), slider, field])
    }

    private func addColor(_ title: String, get: @escaping (NSAppearance) -> NSColor, set: @escaping (NSColor) -> Void) {
        let well = NSColorWell(style: .default)
        well.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let field = numberField()

        let refresh = {
            let color = get(NSApp.effectiveAppearance)
            well.color = color
            field.stringValue = Appearance.hex(color)
        }
        bind(well) { [onChange] in
            set(well.color)
            field.stringValue = Appearance.hex(well.color)
            onChange()
        }
        bind(field) { [onChange] in
            guard let color = Appearance.color(hex: field.stringValue) else { return refresh() }
            set(color)
            refresh()
            onChange()
        }
        refreshers.append(refresh)
        refresh()
        grid.addRow(with: [NSTextField(labelWithString: title), well, field])
        grid.cell(for: well)?.xPlacement = .leading
    }

    private func numberField() -> NSTextField {
        let field = NSTextField(string: "")
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.cell?.sendsActionOnEndEditing = true
        field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        return field
    }

    private func bind(_ control: NSControl, _ block: @escaping () -> Void) {
        let handler = ActionHandler(block)
        handlers.append(handler)
        control.target = handler
        control.action = #selector(ActionHandler.fire(_:))
    }

    /// Place the window just under the preview's glass (the preview frame includes a transparent margin).
    private func position(_ window: NSWindow, below preview: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(preview) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.origin.x = (preview.midX - frame.width / 2).clamped(visible.minX, visible.maxX - frame.width)
        frame.origin.y = max(visible.minY + 8, preview.minY + 8 - frame.height)
        window.setFrame(frame, display: false)
    }
}

private final class ActionHandler: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire(_ sender: Any?) { block() }
}

private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return sendStandardEditAction(for: event) || super.performKeyEquivalent(with: event)
    }
}
