#!/usr/bin/env swift
import Cocoa
import ApplicationServices

func getString(_ el: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref as? String
}
func getInt(_ el: AXUIElement, _ attr: String) -> Int? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return (ref as? NSNumber)?.intValue
}
func getChildren(_ el: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
    return ref as? [AXUIElement] ?? []
}
func getParent(_ el: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &ref) == .success else { return nil }
    return unsafeBitCast(ref, to: AXUIElement.self)
}
func info(_ el: AXUIElement) -> String {
    let role = getString(el, kAXRoleAttribute as String) ?? "?"
    let id = getString(el, "AXDOMIdentifier") ?? ""
    let title = getString(el, kAXTitleAttribute as String) ?? ""
    let value = getString(el, kAXValueAttribute as String) ?? ""
    let desc = getString(el, kAXDescriptionAttribute as String) ?? ""
    let maxLen = getInt(el, "AXMaxLength").map(String.init) ?? "nil"
    let cc = getChildren(el).count
    var p = [role]
    if id.count > 0 { p.append("id=\(id)") }
    if title.count > 0 { p.append("title=\"\(title.prefix(50))\"") }
    if value.count > 0 { p.append("val=\"\(value.prefix(50))\"") }
    if desc.count > 0 { p.append("desc=\"\(desc.prefix(50))\"") }
    if maxLen != "nil" { p.append("maxLen=\(maxLen)") }
    p.append("ch=\(cc)")
    return p.joined(separator: " | ")
}

// Find Chrome
let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == "Google Chrome" }
guard let chrome = apps.first else { print("Chrome not running"); exit(1) }
print("Chrome pid=\(chrome.processIdentifier)")

let axApp = AXUIElementCreateApplication(chrome.processIdentifier)
var focusedRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success else {
    print("ERROR: no focused element"); exit(1)
}
let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
print("FOCUSED: \(info(focused))")

var current = focused
for level in 0..<5 {
    guard let parent = getParent(current) else { print("Level \(level): no parent"); break }
    let children = getChildren(parent)
    let tfCount = children.filter { getString($0, kAXRoleAttribute as String) == "AXTextField" }.count
    print("\n--- Level \(level) parent: \(info(parent)) ---")
    print("    textFields=\(tfCount)")
    for (i, child) in children.enumerated() {
        print("  [\(i)] \(info(child))")
        for (j, gc) in getChildren(child).prefix(5).enumerated() {
            print("      [\(i).\(j)] \(info(gc))")
        }
        let gcCount = getChildren(child).count
        if gcCount > 5 { print("      ...+\(gcCount - 5) more") }
    }
    current = parent
}
