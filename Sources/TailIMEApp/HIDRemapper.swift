import CSystemBridge
import Foundation
import IOKit
import TailIMECore

/// Optional physical-keyboard-only HID remapper for users WITHOUT Karabiner-Elements.
/// Disabled by default. Automatically refuses to run if Karabiner-Elements is active,
/// explicitly excludes Karabiner virtual keyboards, persists undo records before touching hardware,
/// and restores cleanly on disable/quit/reboot recovery.
final class HIDRemapper {
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"
    private static let undoRecordsKey = "TailIME.HIDUndoRecords.v1"
    private static let bootSessionKey = "TailIME.HIDUndoBootSession.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        clearStaleUndoIfRebooted()
    }

    /// Returns true if Karabiner-Elements daemon is currently running on this Mac.
    static func isKarabinerRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 16)
        for needle in ["Karabiner-Core-Service", "karabiner_grabber", "Karabiner-VirtualHIDDevice-Daemon"] {
            let count = needle.withCString { cstr in
                tailime_find_pids_matching_path(cstr, &pids, Int32(pids.count))
            }
            if count > 0 { return true }
        }
        return false
    }

    struct ReconcileStatus: Equatable {
        let appliedCount: Int
        let skippedBecauseKarabiner: Bool
        let message: String
    }

    @discardableResult
    func reconcile(enabled: Bool, sourceUsage: UInt64, targetKeyCode: Int64) -> ReconcileStatus {
        guard enabled else {
            restoreAll()
            return ReconcileStatus(appliedCount: 0, skippedBecauseKarabiner: false, message: "비활성화됨")
        }
        if Self.isKarabinerRunning() {
            restoreAll()
            return ReconcileStatus(
                appliedCount: 0,
                skippedBecauseKarabiner: true,
                message: "Karabiner-Elements 실행 중이므로 충돌 방지를 위해 내장 HID 리매핑이 자동 비활성화되었습니다."
            )
        }
        guard let targetUsage = HIDKeyUsage.usage(forFKeyCode: targetKeyCode) else {
            return ReconcileStatus(appliedCount: 0, skippedBecauseKarabiner: false, message: "지원하지 않는 대상 F-key입니다.")
        }

        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return withExtendedLifetime(client) { () -> ReconcileStatus in
            guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
                return ReconcileStatus(appliedCount: 0, skippedBecauseKarabiner: false, message: "키보드 목록을 읽을 수 없습니다.")
            }

            var undoRecords = loadUndoRecords()
            var applied = 0

            for service in services {
                guard IOHIDServiceClientConformsTo(service, 1, 6) != 0 else { continue }
                let product = (IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String) ?? ""
                if product.localizedCaseInsensitiveContains("Karabiner")
                    || product.localizedCaseInsensitiveContains("VirtualHID") {
                    continue
                }

                let regID = String(describing: IOHIDServiceClientGetRegistryID(service))
                let current = (IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [[String: NSNumber]]) ?? []

                if undoRecords[regID] == nil {
                    let originalDst = current.first(where: { $0[Self.srcKey]?.uint64Value == sourceUsage })?[Self.dstKey]?.uint64Value
                    undoRecords[regID] = [
                        "src": String(sourceUsage),
                        "dst": String(targetUsage),
                        "orig": originalDst.map(String.init) ?? "none",
                    ]
                    saveUndoRecords(undoRecords)
                }

                var updated = current.filter { $0[Self.srcKey]?.uint64Value != sourceUsage }
                updated.append([
                    Self.srcKey: NSNumber(value: sourceUsage),
                    Self.dstKey: NSNumber(value: targetUsage),
                ])

                if IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, updated as CFArray) {
                    applied += 1
                }
            }

            return ReconcileStatus(
                appliedCount: applied,
                skippedBecauseKarabiner: false,
                message: applied > 0 ? "물리 키보드 \(applied)대에 적용됨" : "적용할 물리 키보드 없음"
            )
        }
    }

    func restoreAll() {
        let records = loadUndoRecords()
        guard !records.isEmpty else { return }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        withExtendedLifetime(client) {
            guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else {
                return
            }

            for service in services {
                let regID = String(describing: IOHIDServiceClientGetRegistryID(service))
                guard let rec = records[regID],
                      let src = UInt64(rec["src"] ?? ""),
                      let dst = UInt64(rec["dst"] ?? "") else { continue }

                let current = (IOHIDServiceClientCopyProperty(service, "UserKeyMapping" as CFString) as? [[String: NSNumber]]) ?? []
                var restored = current.filter {
                    !($0[Self.srcKey]?.uint64Value == src && $0[Self.dstKey]?.uint64Value == dst)
                }
                if let origStr = rec["orig"], origStr != "none", let origDst = UInt64(origStr) {
                    restored.append([Self.srcKey: NSNumber(value: src), Self.dstKey: NSNumber(value: origDst)])
                }
                _ = IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, restored as CFArray)
            }
        }
        defaults.removeObject(forKey: Self.undoRecordsKey)
    }

    private func loadUndoRecords() -> [String: [String: String]] {
        (defaults.dictionary(forKey: Self.undoRecordsKey) as? [String: [String: String]]) ?? [:]
    }

    private func saveUndoRecords(_ records: [String: [String: String]]) {
        defaults.set(records, forKey: Self.undoRecordsKey)
    }

    private func clearStaleUndoIfRebooted() {
        guard let boot = Self.currentBootSessionUUID() else { return }
        if defaults.string(forKey: Self.bootSessionKey) != boot {
            defaults.removeObject(forKey: Self.undoRecordsKey)
            defaults.set(boot, forKey: Self.bootSessionKey)
        }
    }

    static func currentBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
