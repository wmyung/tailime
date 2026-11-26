import CoreFoundation
import Foundation
import TailIMECore

/// Local-only CFMessagePort IPC server enabling `tailime-ctl` CLI queries and automation
/// inside the current macOS user's GUI Mach bootstrap namespace.
final class LocalControlServer {
    static let portName = "com.tailime.app.cli.v1"

    private var port: CFMessagePort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: ([String: Any]) -> [String: Any]

    init(handler: @escaping ([String: Any]) -> [String: Any]) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        var context = CFMessagePortContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        var shouldFreeInfo: DarwinBoolean = false
        guard let created = CFMessagePortCreateLocal(
            kCFAllocatorDefault,
            Self.portName as CFString,
            { _, _, data, info -> Unmanaged<CFData>? in
                guard let info else { return nil }
                let server = Unmanaged<LocalControlServer>.fromOpaque(info).takeUnretainedValue()
                let reqDict = (data as Data?).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                } ?? [:]
                let respDict = server.handler(reqDict)
                let respData = (try? JSONSerialization.data(withJSONObject: respDict)) ?? Data()
                return Unmanaged.passRetained(respData as CFData)
            },
            &context,
            &shouldFreeInfo
        ) else {
            return false
        }

        let source = CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = created
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let p = port {
            CFMessagePortInvalidate(p)
        }
        runLoopSource = nil
        port = nil
    }
}
