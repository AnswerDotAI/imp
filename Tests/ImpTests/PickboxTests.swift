import Testing
import AppKit
@testable import Imp

@Test func pickboxSearchPreservesIndices() throws {
    let items = [PickboxItem(name: "Company", text: "Wrocław\n1234567890"),
                 PickboxItem(name: "Personal", text: "Kraków"),
                 PickboxItem(name: "Other company", text: "London")]
    #expect(pickboxMatches(items, query: "") == [0, 1, 2])
    #expect(pickboxMatches(items, query: "COMP") == [0, 2])
    #expect(pickboxMatches(items, query: "45678") == [0])
    #expect(pickboxMatches(items, query: "comp wroc") == [0])
    #expect(pickboxMatches(items, query: "missing") == [])
    let decoded = try JSONDecoder().decode([PickboxItem].self, from: Data(#"[{"name":"VAT","text":"00123"},"Address"]"#.utf8))
    #expect(decoded[0].text == "00123")
    #expect(decoded[1].name == "Address")
}

@Test func pickboxShortcutsUseShiftDigits() {
    #expect(pickboxShortcut(keyCode: 18, modifiers: [.shift]) == 0)
    #expect(pickboxShortcut(keyCode: 25, modifiers: [.shift]) == 8)
    #expect(pickboxShortcut(keyCode: 29, modifiers: [.shift]) == 9)
    #expect(pickboxShortcut(keyCode: 18, modifiers: []) == nil)
    #expect(pickboxShortcut(keyCode: 18, modifiers: [.shift, .command]) == nil)
    #expect(pickboxShortcut(keyCode: 0, modifiers: [.shift]) == nil)
}

@Test @MainActor func pickboxNativeSearchAndNavigation() {
    _ = NSApplication.shared
    let view = PickboxView([PickboxItem(name: "Company", text: "00123"),
                            PickboxItem(name: "Address", text: "Warsaw"),
                            PickboxItem(name: "Other address", text: "London")])
    let panel = makePanel("Picker test", view, w: 620, h: 440, frame: nil)
    #expect(panel.initialFirstResponder === view.search)
    #expect(view.table.numberOfRows == 3)
    view.search.stringValue = "address"
    view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.search))
    #expect(view.matches == [1, 2])
    #expect(view.table.numberOfRows == 2)
    view.move(1)
    #expect(view.table.selectedRow == 1)
    view.move(1)
    #expect(view.table.selectedRow == 1)
    view.search.stringValue = "no match"
    view.refresh()
    #expect(view.table.numberOfRows == 0)
    #expect(view.table.selectedRow == -1)
    panel.close()
}
