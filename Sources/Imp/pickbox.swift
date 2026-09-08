import AppKit

struct PickboxItem: Decodable {
    let name: String
    let text: String

    init(name: String, text: String = "") { self.name = name; self.text = text }
    enum CodingKeys: String, CodingKey { case name, text }
    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.init(name: name)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }
}

func pickboxMatches(_ items: [PickboxItem], query: String) -> [Int] {
    let words = query.split(whereSeparator: { $0.isWhitespace })
    return items.indices.filter { i in
        let content = items[i].name + "\n" + items[i].text
        return words.allSatisfy { content.localizedStandardContains(String($0)) }
    }
}

func pickboxShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
    guard modifiers.intersection([.command, .control, .option, .shift]) == [.shift] else { return nil }
    // Physical digit keys avoid treating shifted punctuation as search text.
    return [18, 19, 20, 21, 23, 22, 26, 28, 25, 29].firstIndex(of: keyCode)
}

@MainActor final class PickboxView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let items: [PickboxItem]
    var matches: [Int]
    let search = NSSearchField()
    let table = NSTableView()
    let count = NSTextField(labelWithString: "")
    var chosen: Int?

    init(_ items: [PickboxItem]) {
        self.items = items
        matches = Array(items.indices)
        super.init(frame: .zero)
        search.placeholderString = "Search names or contents"
        search.font = .systemFont(ofSize: 17)
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.setAccessibilityIdentifier("pickbox-search")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityIdentifier("pickbox-results")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "↑ ↓ navigate    Return insert    ⇧1–9 / ⇧0 select    Esc cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [search, scroll, count, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() { window?.initialFirstResponder = search }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[matches[row]]
        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        let preview = NSTextField(labelWithString: item.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "))
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        for label in [name, preview] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [name, preview])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let shortcut = NSTextField(labelWithString: row < 10 ? "⇧\((row + 1) % 10)" : "")
        shortcut.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        let cell = NSTableCellView()
        let stack = NSStackView(views: [labels, shortcut])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor),
            preview.widthAnchor.constraint(lessThanOrEqualTo: labels.widthAnchor)])
        return cell
    }

    func refresh() {
        matches = pickboxMatches(items, query: search.stringValue)
        table.reloadData()
        if !matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        count.stringValue = matches.isEmpty ? "No matches" : "\(matches.count) of \(items.count) items"
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func choose(_ row: Int) {
        guard matches.indices.contains(row) else { return }
        chosen = matches[row]
        NSApplication.shared.stopModal(withCode: .OK)
    }
    @objc func clicked() { choose(table.clickedRow) }
    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
    func handle(_ e: NSEvent) -> Bool {
        if let row = pickboxShortcut(keyCode: e.keyCode, modifiers: e.modifierFlags) { choose(row); return true }
        guard e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch e.keyCode {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76: choose(table.selectedRow)
        default: return false
        }
        return true
    }
}

@MainActor func pickbox(_ title: String, _ items: [PickboxItem], frame: FrameSpec? = nil) -> Int32 {
    let view = PickboxView(items)
    let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in view.handle(e) ? nil : e }
    _ = runPanel(title, view, w: 620, h: 440, frame: frame)
    if let mon { NSEvent.removeMonitor(mon) }
    guard let chosen = view.chosen else { return 1 }
    print(chosen)
    return 0
}
