import Cocoa

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Accessory apps have no Edit menu, so wire up the standard text shortcuts by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            let action: Selector? = switch event.charactersIgnoringModifiers {
            case "v": #selector(NSText.paste(_:))
            case "c": #selector(NSText.copy(_:))
            case "x": #selector(NSText.cut(_:))
            case "a": #selector(NSText.selectAll(_:))
            case "z": Selector(("undo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ResultRow: FlippedView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "↩")
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            hint.isHidden = !isSelected
            needsDisplay = true
        }
    }

    private static let highlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor.black.withAlphaComponent(0.07)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        hint.isHidden = true
        [icon, label, hint].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 10, y: (h - 30) / 2, width: 30, height: 30)
        hint.frame = NSRect(x: bounds.width - 40, y: (h - 17) / 2, width: 28, height: 17)
        label.frame = NSRect(x: 50, y: (h - 19) / 2, width: bounds.width - 100, height: 19)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Self.highlight.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // mouseMoved (not mouseEntered) so rows sliding under a resting cursor don't steal the selection.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { if !isSelected { onHover?() } }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
final class SearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private enum Metric {
        static let width: CGFloat = 620
        static let barHeight: CGFloat = 56
        static let rowHeight: CGFloat = 44
        static let gap: CGFloat = 8
        static let inset: CGFloat = 6
        static let margin: CGFloat = 24 // transparent room for the glass edge/shadow
        static let maxRows = 6
    }

    /// Clear glass refracts the most; a light smoke tint keeps it visible over white pages.
    /// Tweak without rebuilding: `defaults write local.glasslight GlassTint -float 0.3` (0–1)
    /// and `defaults write local.glasslight GlassLensing -int 2` (0–3).
    private static func styleGlass(_ glass: NSGlassEffectView) {
        let defaults = UserDefaults.standard
        let tint = defaults.object(forKey: "GlassTint") as? Double ?? 0.3
        let lensing = defaults.object(forKey: "GlassLensing") as? Int ?? 2
        glass.style = .clear
        glass.tintColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.black.withAlphaComponent(tint)
                : NSColor.white.withAlphaComponent(tint)
        }
        // Private AppKit knob: stronger lensing bends and mirrors what's behind the glass.
        // Guarded so a macOS without it simply falls back to standard clear glass.
        if glass.responds(to: NSSelectorFromString("set_contentLensing:")) {
            glass.setValue(lensing, forKey: "_contentLensing")
        }
    }

    private let index: AppIndex
    private let usage: Usage
    private let panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: Metric.width, height: Metric.barHeight),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let root = FlippedView()
    private let bar = NSGlassEffectView()
    private let list = NSGlassEffectView()
    private let leadingIcon = NSImageView()
    private let field = NSTextField()
    private var rows: [ResultRow] = []
    private let icons = NSCache<NSURL, NSImage>()
    private let searchSymbol = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 19, weight: .medium))

    private var results: [AppEntry] = []
    private var selected = 0
    /// What the user actually typed; the field may additionally hold a selected inline completion.
    private var typed = ""
    private var suppressCompletion = false
    private var anchorTop: CGFloat = 0
    private var anchorMidX: CGFloat = 0

    init(index: AppIndex, usage: Usage) {
        self.index = index
        self.usage = usage
        super.init()
        configurePanel()
        buildViews()
        warmUp()
    }

    // MARK: Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    private func buildViews() {
        let container = NSGlassEffectContainerView()
        container.contentView = root
        panel.contentView = container

        Self.styleGlass(bar)
        bar.cornerRadius = Metric.barHeight / 2
        let barContent = FlippedView()
        bar.contentView = barContent

        leadingIcon.imageScaling = .scaleProportionallyUpOrDown
        leadingIcon.contentTintColor = .secondaryLabelColor
        leadingIcon.image = searchSymbol

        let font = NSFont.systemFont(ofSize: 24, weight: .regular)
        field.font = font
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: "Open App", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        field.delegate = self
        let fieldHeight = ceil(field.cell?.cellSize.height ?? 30)
        barContent.frame = NSRect(x: 0, y: 0, width: Metric.width, height: Metric.barHeight)
        leadingIcon.frame = NSRect(x: 16, y: (Metric.barHeight - 28) / 2, width: 28, height: 28)
        field.frame = NSRect(x: 54, y: (Metric.barHeight - fieldHeight) / 2,
                             width: Metric.width - 54 - 22, height: fieldHeight)
        barContent.addSubview(leadingIcon)
        barContent.addSubview(field)

        Self.styleGlass(list)
        list.cornerRadius = 22
        let listContent = FlippedView()
        list.contentView = listContent
        rows = (0..<Metric.maxRows).map { i in
            let row = ResultRow()
            row.onHover = { [weak self] in self?.select(i, updateCompletion: false) }
            row.onClick = { [weak self] in self?.launch(at: i) }
            listContent.addSubview(row)
            return row
        }

        root.addSubview(bar)
        root.addSubview(list)
    }

    /// Have the window server build the backing store once so the first real show is instant.
    private func warmUp() {
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [panel] in
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        anchorMidX = frame.midX
        anchorTop = frame.maxY - frame.height * 0.2

        typed = ""
        field.stringValue = ""
        results = []
        selected = 0
        updateRows()
        layoutPanel()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor.labelColor.withAlphaComponent(0.10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            editor.insertionPointColor = .controlAccentColor
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func indexDidChange() {
        if panel.isVisible { refresh(complete: false) }
    }

    // MARK: Layout

    private func layoutPanel() {
        let m = Metric.margin, w = Metric.width
        let count = results.count
        let listHeight = count == 0 ? 0 : CGFloat(count) * Metric.rowHeight + 2 * Metric.inset
        let contentHeight = Metric.barHeight + (count == 0 ? 0 : Metric.gap + listHeight)
        let frame = NSRect(x: anchorMidX - w / 2 - m, y: anchorTop - contentHeight - m,
                           width: w + 2 * m, height: contentHeight + 2 * m)
        panel.setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)
        bar.frame = NSRect(x: m, y: m, width: w, height: Metric.barHeight)
        list.isHidden = count == 0
        list.frame = NSRect(x: m, y: m + Metric.barHeight + Metric.gap, width: w, height: listHeight)
        list.contentView?.frame = list.bounds
        for (i, row) in rows.enumerated() {
            row.isHidden = i >= count
            row.frame = NSRect(x: Metric.inset, y: Metric.inset + CGFloat(i) * Metric.rowHeight,
                               width: w - 2 * Metric.inset, height: Metric.rowHeight)
        }
    }

    private func updateRows() {
        for (i, row) in rows.enumerated() where i < results.count {
            row.label.stringValue = results[i].name
            row.icon.image = icon(for: results[i])
            row.isSelected = i == selected
        }
        leadingIcon.image = results.indices.contains(selected) ? icon(for: results[selected]) : searchSymbol
    }

    private func icon(for app: AppEntry) -> NSImage {
        if let cached = icons.object(forKey: app.url as NSURL) { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        icons.setObject(image, forKey: app.url as NSURL)
        return image
    }

    // MARK: Searching & inline prediction

    func controlTextDidChange(_ obj: Notification) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        typed = editor.string
        let complete = !suppressCompletion && !editor.hasMarkedText()
        suppressCompletion = false
        refresh(complete: complete)
    }

    private func refresh(complete: Bool) {
        results = Ranker.search(typed, in: index.apps, usage: usage, limit: Metric.maxRows)
        selected = 0
        updateRows()
        layoutPanel()
        if complete, let top = results.first { applyCompletion(top) }
    }

    /// Spotlight-style prediction: "bl" -> "bl[ender]" with the rest selected, so typing on simply overwrites it.
    private func applyCompletion(_ app: AppEntry) {
        guard !typed.isEmpty, let editor = field.currentEditor() as? NSTextView else { return }
        for key in app.keys {
            guard let r = key.raw.range(of: typed, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else { continue }
            let rest = String(key.raw[r.upperBound...])
            guard !rest.isEmpty else { return }
            editor.string = typed + rest
            editor.setSelectedRange(NSRange(location: typed.utf16.count, length: rest.utf16.count))
            return
        }
    }

    private func setFieldToTyped() {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.string = typed
        editor.setSelectedRange(NSRange(location: typed.utf16.count, length: 0))
    }

    private func acceptCompletion(_ editor: NSTextView) -> Bool {
        let sel = editor.selectedRange()
        guard sel.length > 0, NSMaxRange(sel) == editor.string.utf16.count else { return false }
        typed = editor.string
        editor.setSelectedRange(NSRange(location: typed.utf16.count, length: 0))
        refresh(complete: false)
        return true
    }

    private func select(_ i: Int, updateCompletion: Bool) {
        guard results.indices.contains(i) else { return }
        selected = i
        for (j, row) in rows.enumerated() { row.isSelected = j == i }
        leadingIcon.image = icon(for: results[i])
        if updateCompletion {
            setFieldToTyped()
            applyCompletion(results[i])
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if !results.isEmpty { select((selected + 1) % results.count, updateCompletion: true) }
        case #selector(NSResponder.moveUp(_:)):
            if !results.isEmpty { select((selected - 1 + results.count) % results.count, updateCompletion: true) }
        case #selector(NSResponder.insertNewline(_:)):
            launch(at: selected)
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            hide()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            _ = acceptCompletion(textView)
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToRightEndOfLine(_:)), #selector(NSResponder.moveToEndOfDocument(_:)):
            return acceptCompletion(textView)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteToBeginningOfLine(_:)),
             #selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)):
            suppressCompletion = true // deleting must not immediately re-predict
            return false
        default:
            return false
        }
        return true
    }

    // MARK: Launching

    private func launch(at i: Int) {
        guard results.indices.contains(i) else { return }
        let app = results[i]
        usage.record(query: Ranker.normalize(typed), id: app.id)
        hide()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { NSLog("Glasslight: could not open \(app.url.path): \(error.localizedDescription)") }
        }
    }
}
