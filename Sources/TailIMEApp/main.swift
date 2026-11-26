import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Menu bar agent (LSUIElement)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
