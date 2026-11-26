import CoreGraphics
import CryptoKit
import CSystemBridge
import Darwin
import Foundation
import Security
import TailIMECore

// MARK: - Minimal Zero-Dependency Test Harness (works with Command Line Tools without Xcode.app)

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

var passedCount = 0
var failedCount = 0

func runTest(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        passedCount += 1
        print("  ✓ \(name)")
    } catch {
        failedCount += 1
        fputs("  ✗ \(name): \(error)\n", stderr)
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion failed", file: String = #fileID, line: Int = #line) throws {
    if !condition() {
        throw TestFailure(description: "\(file):\(line) — \(message)")
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if lhs != rhs {
        throw TestFailure(description: "\(file):\(line) — expected \(rhs), got \(lhs) \(message)")
    }
}

func unwrap<T>(_ value: T?, _ message: String = "Unexpected nil", file: String = #fileID, line: Int = #line) throws -> T {
    guard let value else {
        throw TestFailure(description: "\(file):\(line) — \(message)")
    }
    return value
}

func expectThrows<E: Error & Equatable>(_ expected: E, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) throws {
    do {
        try body()
        throw TestFailure(description: "\(file):\(line) — expected error \(expected) but succeeded")
    } catch let err as E {
        if err != expected {
            throw TestFailure(description: "\(file):\(line) — expected error \(expected), got \(err)")
        }
    } catch {
        throw TestFailure(description: "\(file):\(line) — expected error \(expected), got \(error)")
    }
}

// MARK: - 1. WireProtocol & CryptoIdentity Tests

print("Suite 1: WireProtocol & CryptoIdentity")

runTest("Curve25519 ECDH derives identical per-peer HMAC keys and 6-digit SAS") {
    let macA = CryptoIdentity.generateEphemeral()
    let macB = CryptoIdentity.generateEphemeral()
    let macC = CryptoIdentity.generateEphemeral()

    let keyAB = try unwrap(macA.derivePeerHMACKey(peerPublicKeyBase64: macB.publicKeyBase64))
    let keyBA = try unwrap(macB.derivePeerHMACKey(peerPublicKeyBase64: macA.publicKeyBase64))
    try expectEqual(keyAB, keyBA)

    let sasAB = try unwrap(macA.confirmationCode(peerPublicKeyBase64: macB.publicKeyBase64))
    let sasBA = try unwrap(macB.confirmationCode(peerPublicKeyBase64: macA.publicKeyBase64))
    try expectEqual(sasAB, sasBA)
    try expectEqual(sasAB.count, 7) // "123-456"

    let keyAC = try unwrap(macA.derivePeerHMACKey(peerPublicKeyBase64: macC.publicKeyBase64))
    try expect(keyAB != keyAC, "Different peer must have distinct HMAC key")
}

runTest("Pairing token round-trip succeeds and rejects tampered tokens") {
    let macA = CryptoIdentity.generateEphemeral()
    let token = try unwrap(macA.exportPairingToken(hostName: "mac-desk", tailscaleIP: "100.64.0.10", port: 39418))
    try expect(token.hasPrefix("TKP1:"))

    let decoded = try unwrap(CryptoIdentity.decodePairingToken(token))
    try expectEqual(decoded.deviceID, macA.deviceID)
    try expectEqual(decoded.name, "mac-desk")
    try expectEqual(decoded.tailscaleIP, "100.64.0.10")
    try expectEqual(decoded.port, 39418)
    try expect(CryptoIdentity.decodePairingToken(token + "x") == nil)
}

runTest("CryptoIdentity Keychain loader NEVER overwrites existing key on ACL denial or cancel") {
    let originalKey = Curve25519.KeyAgreement.PrivateKey()
    let expectedID = CryptoIdentity(privateKey: originalKey).deviceID

    // 1. Valid existing item -> loads without adding or updating
    var addCount = 0
    var updateCount = 0
    let loaded = CryptoIdentity.loadOrCreateWithStore(
        read: { .found(originalKey.rawRepresentation) },
        add: { _ in addCount += 1; return errSecSuccess },
        update: { _ in updateCount += 1; return errSecSuccess }
    )
    try expectEqual(loaded.identity?.deviceID, expectedID)
    try expectEqual(loaded.isPersistent, true)
    try expect(loaded.errorStatus == nil)
    try expectEqual(addCount, 0)
    try expectEqual(updateCount, 0)

    // 2. ACL denial / user cancel -> returns .keychainLocked and calls NEITHER add NOR update!
    for deniedStatus in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
        var deniedAdds = 0
        var deniedUpdates = 0
        let res = CryptoIdentity.loadOrCreateWithStore(
            read: { .accessDenied(deniedStatus) },
            add: { _ in deniedAdds += 1; return errSecSuccess },
            update: { _ in deniedUpdates += 1; return errSecSuccess }
        )
        try expect(res.identity == nil, "Must not silently mint a new identity on \(deniedStatus)")
        try expectEqual(res.isPersistent, false)
        try expectEqual(res.errorStatus, deniedStatus)
        try expectEqual(deniedAdds, 0)
        try expectEqual(deniedUpdates, 0)
    }

    // 3. Explicit .notFound -> calls add() once and never update()
    var savedBytes: Data?
    var notFoundUpdates = 0
    let created = CryptoIdentity.loadOrCreateWithStore(
        read: { .notFound },
        add: { savedBytes = $0; return errSecSuccess },
        update: { _ in notFoundUpdates += 1; return errSecSuccess }
    )
    try expectEqual(created.isPersistent, true)
    try expectEqual(notFoundUpdates, 0)
    try expectEqual(savedBytes?.count, 32)
    let reloaded = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: unwrap(savedBytes))
    try expectEqual(CryptoIdentity(privateKey: reloaded).deviceID, created.identity?.deviceID)

    // 4. .notFound with add() failing (e.g. errSecDuplicateItem) -> returns .saveFailed
    let saveFail = CryptoIdentity.loadOrCreateWithStore(
        read: { .notFound },
        add: { _ in errSecDuplicateItem },
        update: { _ in errSecSuccess }
    )
    try expectEqual(saveFail.isPersistent, false)
    try expectEqual(saveFail.errorStatus, errSecDuplicateItem)

    // 5. Corrupt payload -> calls update() once (never add()) to repair
    var corruptAdds = 0
    var repairedBytes: Data?
    let repaired = CryptoIdentity.loadOrCreateWithStore(
        read: { .found(Data([0x01, 0x02])) },
        add: { _ in corruptAdds += 1; return errSecSuccess },
        update: { repairedBytes = $0; return errSecSuccess }
    )
    try expectEqual(repaired.isPersistent, true)
    try expectEqual(corruptAdds, 0)
    try expectEqual(repairedBytes?.count, 32)
}

runTest("Authenticated TIV1 packet round-trip, tamper rejection, and clock skew") {
    let macA = CryptoIdentity.generateEphemeral()
    let macB = CryptoIdentity.generateEphemeral()
    let key = try unwrap(macA.derivePeerHMACKey(peerPublicKeyBase64: macB.publicKeyBase64))
    let nowMs: UInt64 = 1_760_000_000_000

    let msg = WireMessage(
        cmd: .set,
        senderDeviceID: macA.deviceID,
        senderName: "mac-laptop",
        bootSessionID: "boot-1",
        seq: 42,
        targetLanguage: .korean
    )

    let packet = try WirePacketCodec.encode(message: msg, key: key, timestampMs: nowMs, nonce: 999)
    let decoded = try WirePacketCodec.decode(data: packet, nowMs: nowMs + 100) { sender in
        sender == macA.deviceID ? key : nil
    }
    try expectEqual(decoded.authenticated, true)
    try expectEqual(decoded.nonce, 999)
    try expectEqual(decoded.message, msg)

    // Tamper MAC
    var tamperedMAC = packet
    tamperedMAC[tamperedMAC.count - 1] ^= 0x01
    try expectThrows(WirePacketError.invalidHMAC) {
        _ = try WirePacketCodec.decode(data: tamperedMAC, nowMs: nowMs) { _ in key }
    }

    // Tamper header timestamp (breaks MAC)
    var tamperedHdr = packet
    tamperedHdr[12] ^= 0x01
    try expectThrows(WirePacketError.invalidHMAC) {
        _ = try WirePacketCodec.decode(data: tamperedHdr, nowMs: nowMs) { _ in key }
    }

    // Outside ±5 min window
    try expectThrows(WirePacketError.timestampOutOfWindow) {
        _ = try WirePacketCodec.decode(data: packet, nowMs: nowMs + 400_000) { _ in key }
    }
}

runTest("Unauthenticated commands rejected except valid pairHello") {
    let macA = CryptoIdentity.generateEphemeral()
    let nowMs: UInt64 = 1_760_000_000_000

    let setMsg = WireMessage(cmd: .set, senderDeviceID: macA.deviceID, bootSessionID: "b1", seq: 1, targetLanguage: .english)
    try expectThrows(WirePacketError.unauthenticatedCommandNotAllowed) {
        _ = try WirePacketCodec.encode(message: setMsg, key: nil, timestampMs: nowMs)
    }

    let hello = WireMessage(
        cmd: .pairHello,
        senderDeviceID: macA.deviceID,
        senderName: "mac-desk",
        bootSessionID: "b1",
        seq: 1,
        publicKeyBase64: macA.publicKeyBase64
    )
    let packet = try WirePacketCodec.encode(message: hello, key: nil, timestampMs: nowMs)
    let decoded = try WirePacketCodec.decode(data: packet, nowMs: nowMs) { _ in nil }
    try expectEqual(decoded.authenticated, false)
    try expectEqual(decoded.message.cmd, .pairHello)
}

runTest("Sliding-window replay guard enforces latest-order for mutating commands and caches ACK") {
    var guardState = SlidingWindowReplayGuard()

    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 1, now: 10, isStateMutating: true), .accept)
    let ack1 = WireMessage(cmd: .ack, senderDeviceID: "self", bootSessionID: "b0", seq: 10, replyToSeq: 1, currentLanguage: .korean, ok: true, via: "udp")
    guardState.cacheReply(ack1, senderDeviceID: "peer1", bootSessionID: "b1", seq: 1)

    try expectEqual(
        guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 1, now: 10.04, isStateMutating: true),
        .duplicate(cachedReply: ack1)
    )
    // Newer mutating seq 5 accepted
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 5, now: 11, isStateMutating: true), .accept)
    // Delayed older mutating seq 3 MUST be rejected as stale order so it cannot overwrite seq 5!
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 3, now: 11.1, isStateMutating: true), .rejectStaleOrder)
    // Non-mutating out-of-order seq 4 within window is still accepted once
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 4, now: 11.15, isStateMutating: false), .accept)
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 4, now: 11.2, isStateMutating: false), .duplicate(cachedReply: nil))
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 80, now: 12, isStateMutating: true), .accept)
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b1", seq: 2, now: 12.1, isStateMutating: true), .rejectTooOld)
    try expectEqual(guardState.checkAndRecord(senderDeviceID: "peer1", bootSessionID: "b2", seq: 1, now: 13, isStateMutating: true), .accept)
}

// MARK: - 2. Trigger Engine & Parsers

print("\nSuite 2: Trigger Engine & Config Parsers")

runTest("Karabiner multi-device config parses selected profile, devices, and complex to_if_alone") {
    let json = """
    {
      "profiles": [
        {
          "name": "Unused",
          "selected": false,
          "simple_modifications": [
            { "from": { "key_code": "right_command" }, "to": [{ "key_code": "f13" }] }
          ]
        },
        {
          "name": "Default profile",
          "selected": true,
          "simple_modifications": [
            { "from": { "key_code": "right_command" }, "to": [{ "key_code": "f18" }] }
          ],
          "devices": [
            {
              "identifiers": { "is_keyboard": true, "vendor_id": 1452, "product_id": 641 },
              "simple_modifications": [
                { "from": { "key_code": "right_command" }, "to": [{ "key_code": "f19" }] }
              ]
            },
            {
              "identifiers": { "is_keyboard": true, "vendor_id": 1204, "product_id": 1296 },
              "ignore": true,
              "simple_modifications": [
                { "from": { "key_code": "right_option" }, "to": [{ "key_code": "f15" }] }
              ]
            }
          ],
          "complex_modifications": {
            "rules": [
              {
                "description": "Caps Lock alone -> Ctrl+Space",
                "manipulators": [
                  {
                    "type": "basic",
                    "from": { "key_code": "caps_lock" },
                    "to_if_alone": [{ "key_code": "spacebar", "modifiers": ["left_control"] }]
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """
    let result = KarabinerConfigParser.parse(data: Data(json.utf8))
    try expectEqual(result.profileName, "Default profile")
    let codes = Set(result.detectedTriggers.map(\.keyCode))
    try expect(codes.contains(VirtualKeyCode.f18))
    try expect(codes.contains(VirtualKeyCode.f19))
    try expect(codes.contains(VirtualKeyCode.space))
    try expect(!codes.contains(VirtualKeyCode.f13))
    try expect(!codes.contains(VirtualKeyCode.f15))
}

runTest("SymbolicHotkeysParser normalizes SecondaryFn on F-keys") {
    let dict: [String: Any] = [
        "60": ["enabled": 1, "value": ["type": "standard", "parameters": [65535, 79, 8388608]]],
        "61": ["enabled": 0, "value": ["type": "standard", "parameters": [32, 49, 262144]]],
    ]
    let snapshot = SymbolicHotkeysParser.parse(hotkeysDict: dict)
    try expectEqual(snapshot.previousSource?.enabled, true)
    try expectEqual(snapshot.previousSource?.keyCode, VirtualKeyCode.f18)
    try expectEqual(snapshot.previousSource?.modifiers, [])
    try expect(snapshot.previousSource?.syntheticPulseFlags.contains(.maskSecondaryFn) == true)
}

runTest("Safe carrier pair avoids conflicts with user and system triggers") {
    let triggers = [TriggerSpec(keyCode: VirtualKeyCode.f18), TriggerSpec(keyCode: VirtualKeyCode.f19), TriggerSpec(keyCode: VirtualKeyCode.f16)]
    let hotkeys = InputSourceHotkeysSnapshot(
        previousSource: SymbolicHotkeySpec(id: "60", enabled: true, keyCode: VirtualKeyCode.f18, rawModifiers: 0),
        nextSource: nil,
        capsLockSwitchesToABC: false,
        fnKeyChangesInputSource: false
    )
    let pair = TriggerResolver.safeCarrierPair(preferred: CarrierPair(), avoidingTriggers: triggers, systemHotkeys: hotkeys)
    let used: Set<Int64> = [VirtualKeyCode.f18, VirtualKeyCode.f19, VirtualKeyCode.f16]
    try expect(!used.contains(pair.koreanKeyCode))
    try expect(!used.contains(pair.englishKeyCode))
    try expect(!used.contains(pair.probeKeyCode))
    try expectEqual(Set([pair.koreanKeyCode, pair.englishKeyCode, pair.probeKeyCode]).count, 3)
}

runTest("Owned trigger swallows down, repeat, and matching up even if triggers update mid-hold") {
    let f18 = TriggerSpec(keyCode: VirtualKeyCode.f18, modifiers: [], kind: .ownedKey)
    var matcher = TriggerMatcher(triggers: [f18])

    try expectEqual(matcher.process(KeyEventSample(kind: .keyDown, keyCode: VirtualKeyCode.f18, timestamp: 1.0)), .fireOwned(f18))
    try expectEqual(matcher.process(KeyEventSample(kind: .keyDown, keyCode: VirtualKeyCode.f18, isAutoRepeat: true, timestamp: 1.2)), .swallowOnly)
    matcher.updateTriggers([])
    try expectEqual(matcher.process(KeyEventSample(kind: .keyUp, keyCode: VirtualKeyCode.f18, timestamp: 1.3)), .swallowOnly)
    try expectEqual(matcher.process(KeyEventSample(kind: .keyDown, keyCode: VirtualKeyCode.f18, timestamp: 2.0)), .passThrough)
}

runTest("Shift+Space guard blocks accidental switch while typing capitals") {
    let shiftSpace = TriggerSpec(keyCode: VirtualKeyCode.space, modifiers: [.shift], kind: .ownedKey)
    var matcher = TriggerMatcher(triggers: [shiftSpace])

    _ = matcher.process(KeyEventSample(kind: .keyDown, keyCode: 0, modifiers: [.shift], timestamp: 1.0))
    try expectEqual(matcher.process(KeyEventSample(kind: .keyDown, keyCode: VirtualKeyCode.space, modifiers: [.shift], timestamp: 1.05)), .passThrough)

    _ = matcher.process(KeyEventSample(kind: .flagsChanged, keyCode: VirtualKeyCode.leftShift, modifiers: [], timestamp: 1.2))
    try expectEqual(matcher.process(KeyEventSample(kind: .keyDown, keyCode: VirtualKeyCode.space, modifiers: [.shift], timestamp: 1.3)), .fireOwned(shiftSpace))
}

runTest("Standalone modifier tap fires only on clean short press") {
    let rightCmd = TriggerSpec(keyCode: VirtualKeyCode.rightCommand, modifiers: [], kind: .modifierTap)
    var matcher = TriggerMatcher(triggers: [rightCmd])

    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [.command], rawFlags: CGEventFlags.maskCommand.rawValue | 0x10, timestamp: 10.0
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [], rawFlags: 0, timestamp: 10.12
    )), .fireObserved(rightCmd))

    // RightCmd + C cancelled
    _ = matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [.command], rawFlags: CGEventFlags.maskCommand.rawValue | 0x10, timestamp: 11.0
    ))
    _ = matcher.process(KeyEventSample(kind: .keyDown, keyCode: 8, modifiers: [.command], timestamp: 11.05))
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [], rawFlags: 0, timestamp: 11.15
    )), .passThrough)

    // Long hold (>320ms) cancelled
    _ = matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [.command], rawFlags: CGEventFlags.maskCommand.rawValue | 0x10, timestamp: 12.0
    ))
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightCommand,
        modifiers: [], rawFlags: 0, timestamp: 12.5
    )), .passThrough)
}

runTest("TriggerResolver preserves macOS Hotkey 61 untouched when Hotkey 60 is enabled") {
    let hotkeys = InputSourceHotkeysSnapshot(
        previousSource: SymbolicHotkeySpec(id: "60", enabled: true, keyCode: VirtualKeyCode.f18, rawModifiers: 0),
        nextSource: SymbolicHotkeySpec(id: "61", enabled: true, keyCode: VirtualKeyCode.space, rawModifiers: UInt64(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)),
        capsLockSwitchesToABC: false,
        fnKeyChangesInputSource: false
    )
    let resolved = TriggerResolver.resolveActiveTriggers(
        settings: AppSettings(),
        systemHotkeys: hotkeys,
        karabiner: KarabinerDiscoveryResult(profileName: nil, detectedTriggers: [])
    )
    try expect(resolved.contains { $0.keyCode == VirtualKeyCode.f18 })
    try expect(!resolved.contains { $0.keyCode == VirtualKeyCode.space }, "Hotkey 61 must stay untouched when Hotkey 60 is enabled")
}

runTest("Caps Lock observed trigger tracks physical down/up, supports rapid double-taps, and ignores long-press or chords") {
    let capsSpec = TriggerSpec(keyCode: VirtualKeyCode.capsLock, modifiers: [], kind: .systemObserved, origin: .systemHotkey)
    var matcher = TriggerMatcher(triggers: [capsSpec])

    // 1. Clean short tap (down -> up within 400ms, alphaShift unchanged): fires ONCE on release
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: true, timestamp: 10.00
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: false, timestamp: 10.07
    )), .fireObserved(capsSpec))

    // 2. Rapid second tap 110ms later STILL fires cleanly (not dropped by fixed cooldown!)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: true, timestamp: 10.18
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: false, timestamp: 10.25
    )), .fireObserved(capsSpec))

    // 3. Slower 260ms short tap fires ONCE (never double-fires!)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: true, timestamp: 11.00
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: false, timestamp: 11.26
    )), .fireObserved(capsSpec))

    // 4. Long press toggles actual Caps Lock LED mid-hold (maskAlphaShift flips false -> true): must NOT fire!
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: 0, isKeyPhysicallyDown: true, timestamp: 12.00
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: true, timestamp: 12.45
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: false, timestamp: 12.60
    )), .passThrough)

    // 5. Chord (Caps Lock held + another key pressed): cancelled, must NOT fire on release
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: true, timestamp: 13.00
    )), .passThrough)
    _ = matcher.process(KeyEventSample(kind: .keyDown, keyCode: 0, modifiers: [], timestamp: 13.05))
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: false, timestamp: 13.12
    )), .passThrough)

    // 6. Caps Lock already ON at launch (fresh matcher): first short tap still fires!
    let fnSpec = TriggerSpec(keyCode: VirtualKeyCode.functionKey, modifiers: [], kind: .systemObserved, origin: .systemHotkey)
    var freshMatcher = TriggerMatcher(triggers: [capsSpec, fnSpec])
    try expectEqual(freshMatcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: true, timestamp: 14.00
    )), .passThrough)
    try expectEqual(freshMatcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: false, timestamp: 14.08
    )), .fireObserved(capsSpec))

    // 7. Caps Lock + Fn/Globe chord: Fn cancels pending Caps tap so releasing Caps does NOT fire a second time
    try expectEqual(freshMatcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: true, timestamp: 15.00
    )), .passThrough)
    _ = freshMatcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.functionKey,
        modifiers: [], rawFlags: CGEventFlags.maskSecondaryFn.rawValue, timestamp: 15.04
    ))
    try expectEqual(freshMatcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.capsLock,
        modifiers: [], rawFlags: CGEventFlags.maskAlphaShift.rawValue, isKeyPhysicallyDown: false, timestamp: 15.10
    )), .passThrough)
}

runTest("All left/right control & modifier keys work for standalone tap, Karabiner parsing, and Shift rollover") {
    // 1. Standalone Left Control & Right Shift taps
    let lCtrlSpec = TriggerSpec(keyCode: VirtualKeyCode.leftControl, modifiers: [], kind: .modifierTap, origin: .userPreset)
    let rShiftSpec = TriggerSpec(keyCode: VirtualKeyCode.rightShift, modifiers: [], kind: .modifierTap, origin: .userPreset)
    let f18Spec = TriggerSpec(keyCode: VirtualKeyCode.f18, modifiers: [], kind: .ownedKey, origin: .karabiner)
    var matcher = TriggerMatcher(triggers: [lCtrlSpec, rShiftSpec, f18Spec])

    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.leftControl,
        modifiers: [.control], rawFlags: CGEventFlags.maskControl.rawValue | 0x01, timestamp: 20.0
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.leftControl,
        modifiers: [], rawFlags: 0, timestamp: 20.12
    )), .fireObserved(lCtrlSpec))

    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightShift,
        modifiers: [.shift], rawFlags: CGEventFlags.maskShift.rawValue | 0x04, timestamp: 21.0
    )), .passThrough)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .flagsChanged, keyCode: VirtualKeyCode.rightShift,
        modifiers: [], rawFlags: 0, timestamp: 21.10
    )), .fireObserved(rShiftSpec))

    // 2. Intentional fresh Shift+F18 stays passThrough; Shift rollover right after typing Shift+A triggers F18; Cmd+F18 stays untouched
    try expectEqual(matcher.process(KeyEventSample(
        kind: .keyDown, keyCode: VirtualKeyCode.f18, modifiers: [.shift], timestamp: 21.8
    )), .passThrough)
    _ = matcher.process(KeyEventSample(kind: .keyDown, keyCode: 0, modifiers: [.shift], timestamp: 21.95)) // typing 'A'
    try expectEqual(matcher.process(KeyEventSample(
        kind: .keyDown, keyCode: VirtualKeyCode.f18, modifiers: [.shift], timestamp: 22.0
    )), .fireOwned(f18Spec))
    try expectEqual(matcher.process(KeyEventSample(
        kind: .keyUp, keyCode: VirtualKeyCode.f18, modifiers: [], timestamp: 22.05
    )), .swallowOnly)
    try expectEqual(matcher.process(KeyEventSample(
        kind: .keyDown, keyCode: VirtualKeyCode.f18, modifiers: [.command], timestamp: 22.2
    )), .passThrough)

    // 3. Karabiner parser detects left_control -> f18 and right_shift -> lang1
    let karJSON = """
    {
      "profiles": [{
        "name": "Dev",
        "selected": true,
        "simple_modifications": [
          { "from": { "key_code": "left_control" }, "to": [{ "key_code": "f18" }] },
          { "from": { "key_code": "right_shift" }, "to": [{ "key_code": "lang1" }] }
        ]
      }]
    }
    """
    let parsed = KarabinerConfigParser.parse(data: Data(karJSON.utf8))
    try expect(parsed.detectedTriggers.contains { $0.keyCode == VirtualKeyCode.f18 })
    try expect(parsed.detectedTriggers.contains { $0.keyCode == VirtualKeyCode.lang1Hangul })
}

// MARK: - 3. HoldGate FIFO Invariants

print("\nSuite 3: HoldGate FIFO Invariants")

runTest("Preserves strict FIFO order across modifiers and down/up pairs") {
    var gate = HoldGate<String>(maxBufferedEvents: 64)
    let gen = gate.arm(now: 100.0, maxDuration: 0.04)
    try expect(gate.enqueueIfArmed("shiftDown", kind: .flagsChanged, keyCode: 56, now: 100.005).buffered)
    try expect(gate.enqueueIfArmed("hDown", kind: .keyDown, keyCode: 4, now: 100.010).buffered)
    try expect(gate.enqueueIfArmed("hUp", kind: .keyUp, keyCode: 4, now: 100.015).buffered)
    try expect(gate.enqueueIfArmed("shiftUp", kind: .flagsChanged, keyCode: 56, now: 100.020).buffered)
    try expectEqual(gate.flushIfGeneration(gen, reason: .completed), ["shiftDown", "hDown", "hUp", "shiftUp"])
    try expectEqual(gate.isArmed, false)
}

runTest("Discard on focus change drops buffered typing while preserving orphan keyUps and flagsChanged (zero stuck keys)") {
    var gate = HoldGate<String>(maxBufferedEvents: 64)
    _ = gate.arm(now: 50.0, maxDuration: 0.05)
    // keyCode 11's keyDown was ALREADY delivered BEFORE arming -> its keyUp MUST be preserved!
    _ = gate.enqueueIfArmed("priorKeyUp", kind: .keyUp, keyCode: 11, now: 50.005)
    // keyCode 0's keyDown & keyUp were both buffered inside gate -> both dropped!
    _ = gate.enqueueIfArmed("aDown", kind: .keyDown, keyCode: 0, now: 50.010)
    _ = gate.enqueueIfArmed("aRepeat", kind: .autoRepeat, keyCode: 0, now: 50.015)
    _ = gate.enqueueIfArmed("aUp", kind: .keyUp, keyCode: 0, now: 50.020)
    // Modifier release MUST be preserved!
    _ = gate.enqueueIfArmed("shiftUp", kind: .flagsChanged, keyCode: 56, now: 50.025)

    let safeReleases = gate.flush(reason: .focusChanged, discard: true)
    try expectEqual(safeReleases, ["priorKeyUp", "shiftUp"])
    try expectEqual(gate.count, 0)
}

runTest("Stale generation ignored; capacity and deadline auto-flush safely") {
    var gate = HoldGate<Int>(maxBufferedEvents: 3)
    let gen1 = gate.arm(now: 1.0, maxDuration: 0.05)
    _ = gate.enqueueIfArmed(1, kind: .keyDown, keyCode: 1, now: 1.01)
    let gen2 = gate.arm(now: 1.02, maxDuration: 0.05)
    _ = gate.enqueueIfArmed(2, kind: .keyUp, keyCode: 1, now: 1.03)
    try expect(gate.flushIfGeneration(gen1, reason: .timeout) == nil)
    try expectEqual(gate.flushIfGeneration(gen2, reason: .completed), [1, 2])

    _ = gate.arm(now: 10.0, maxDuration: 0.05)
    try expect(gate.enqueueIfArmed(1, kind: .keyDown, keyCode: 1, now: 10.01).overflowFlush == nil)
    try expect(gate.enqueueIfArmed(2, kind: .keyUp, keyCode: 1, now: 10.02).overflowFlush == nil)
    try expectEqual(gate.enqueueIfArmed(3, kind: .keyDown, keyCode: 2, now: 10.03).overflowFlush, [1, 2, 3])

    _ = gate.arm(now: 20.0, maxDuration: 0.03)
    _ = gate.enqueueIfArmed(10, kind: .keyDown, keyCode: 3, now: 20.01)
    try expectEqual(gate.enqueueIfArmed(11, kind: .keyUp, keyCode: 3, now: 20.04).overflowFlush, [10, 11])
}

runTest("SwitchGenerationTracker prevents stale async IPC from inverting latest switch (EN -> in-flight KO -> EN)") {
    let tracker = SwitchGenerationTracker()
    let ipcQueue = DispatchQueue(label: "com.tailime.test.switch-tracker")
    let stateLock = NSLock()
    var simulatedLang: InputLanguage = .english
    var pid2SentForGen1 = false
    var completedGens: [UInt64] = []

    // No in-flight direct switch -> short-circuit allowed when already at target
    try expectEqual(tracker.canShortCircuitAlreadyAtTarget(true), true)
    try expectEqual(tracker.canShortCircuitAlreadyAtTarget(false), false)

    // 1. Start gen 1 (KO) on serial IPC queue, pause mid-flight after PID 1 starts
    let pid1Started = DispatchSemaphore(value: 0)
    let allowPID1Finish = DispatchSemaphore(value: 0)
    let allDone = DispatchSemaphore(value: 0)

    let gen1 = tracker.advance()
    tracker.beginInFlightDirectSwitch()
    ipcQueue.async {
        if tracker.isCurrent(gen1) {
            pid1Started.signal()
            _ = allowPID1Finish.wait(timeout: .now() + 2.0)
            // PID 1 completes late and mutates OS state to Korean
            stateLock.lock()
            simulatedLang = .korean
            stateLock.unlock()
        }
        // Before PID 2, gen1 MUST re-check isCurrent and abort!
        if tracker.isCurrent(gen1) {
            stateLock.lock()
            pid2SentForGen1 = true
            stateLock.unlock()
        }
        if tracker.isCurrent(gen1) {
            stateLock.lock()
            completedGens.append(gen1)
            stateLock.unlock()
        }
        tracker.endInFlightDirectSwitch()
    }

    try expectEqual(pid1Started.wait(timeout: .now() + 2.0), .success)

    // 2. While gen1 (KO) is mid-flight, OS still reports EN, and user requests EN (gen2)!
    try expectEqual(tracker.hasInFlightDirectSwitch, true)
    // MUST NOT short-circuit even though current language is still EN!
    try expectEqual(tracker.canShortCircuitAlreadyAtTarget(true), false)

    let gen2 = tracker.advance()
    try expectEqual(tracker.isCurrent(gen1), false)
    try expectEqual(tracker.isCurrent(gen2), true)

    tracker.beginInFlightDirectSwitch()
    ipcQueue.async {
        if tracker.isCurrent(gen2) {
            stateLock.lock()
            simulatedLang = .english
            completedGens.append(gen2)
            stateLock.unlock()
        }
        tracker.endInFlightDirectSwitch()
        allDone.signal()
    }

    // Release stalled PID 1 of gen1 and wait for serial queue to drain
    allowPID1Finish.signal()
    try expectEqual(allDone.wait(timeout: .now() + 2.0), .success)

    stateLock.lock()
    let finalLang = simulatedLang
    let pid2Ran = pid2SentForGen1
    let gens = completedGens
    stateLock.unlock()

    try expectEqual(finalLang, .english, "Latest request (EN) must win over stale in-flight KO IPC")
    try expectEqual(pid2Ran, false, "Stale gen1 must abort before sending to second PID")
    try expectEqual(gens, [gen2], "Only latest generation should complete")
    try expectEqual(tracker.hasInFlightDirectSwitch, false)
    try expectEqual(tracker.canShortCircuitAlreadyAtTarget(true), true)
}

// MARK: - 4. Remote Resolver, Tailscale, SocketInspector & CSystemBridge

print("\nSuite 4: Remote Resolver, Tailscale, Sockets & Live CSystemBridge")

runTest("Tailscale JSON parsing and IPv4/IPv6/interface validation") {
    let json = """
    {
      "Self": {
        "HostName": "mac-laptop",
        "DNSName": "mac-laptop.example.ts.net.",
        "OS": "macOS",
        "TailscaleIPs": ["100.64.0.20", "fd7a:115c:a1e0::20"],
        "Online": true
      },
      "Peer": {
        "node1": {
          "HostName": "mac-desk",
          "DNSName": "mac-desk.example.ts.net.",
          "OS": "macOS",
          "TailscaleIPs": ["100.64.0.10", "fd7a:115c:a1e0::10"],
          "Online": true,
          "Active": true,
          "CurAddr": "192.0.2.10:41641",
          "Relay": "tok"
        },
        "node2": {
          "HostName": "WIN-DESKTOP",
          "DNSName": "win-desktop.example.ts.net.",
          "OS": "windows",
          "TailscaleIPs": ["100.64.0.30"],
          "Online": true,
          "Active": false,
          "CurAddr": "",
          "Relay": "tok"
        }
      }
    }
    """
    let snapshot = try unwrap(TailscaleDiscovery.parseStatusJSON(Data(json.utf8)))
    try expectEqual(snapshot.selfNode?.ipv4, "100.64.0.20")
    try expectEqual(snapshot.peers.first?.hostName, "mac-desk")
    try expectEqual(snapshot.peers.first?.isDirectPath, true)

    try expect(TailscaleIPValidator.isTailscaleIPv4("100.64.0.10"))
    try expect(TailscaleIPValidator.isTailscaleIPv4("100.64.0.1"))
    try expect(TailscaleIPValidator.isTailscaleIPv4("100.127.255.254"))
    try expect(!TailscaleIPValidator.isTailscaleIPv4("100.63.255.255"))
    try expect(!TailscaleIPValidator.isTailscaleIPv4("100.128.0.1"))
    try expect(!TailscaleIPValidator.isTailscaleIPv4("192.168.1.10"))
    try expect(TailscaleIPValidator.isTailscaleIPv6("fd7a:115c:a1e0::10"))
    try expect(!TailscaleIPValidator.isTailscaleIPv6("fe80::1"))
    try expect(TailscaleIPValidator.isAllowedInterfaceName("utun4", sourceIP: "100.64.0.10"))
    try expect(!TailscaleIPValidator.isAllowedInterfaceName("en0", sourceIP: "100.64.0.10"))
    try expect(TailscaleIPValidator.isAllowedInterfaceName("lo0", sourceIP: "127.0.0.1"))
}

runTest("SocketInspector excludes RustDesk server daemons and listening sockets, normalizes dual-stack IPv6/IPv4 clients") {
    try expectEqual(SocketInspector.normalizeIP("::100.64.0.10"), "100.64.0.10")
    try expectEqual(SocketInspector.normalizeIP("::ffff:100.64.0.10"), "100.64.0.10")
    try expectEqual(SocketInspector.normalizeIP("::FFFF:100.64.0.20"), "100.64.0.20")
    try expectEqual(SocketInspector.normalizeIP("fd7a:115c:a1e0::30"), "fd7a:115c:a1e0::30")
    try expectEqual(SocketInspector.normalizeIP("::1"), "::1")

    let sockets: [ActiveSocketEntry] = [
        ActiveSocketEntry(pid: 1075, isTCP: true, isEstablished: false, isListen: true,
                          localIP: "0.0.0.0", localPort: 21118, remoteIP: "0.0.0.0", remotePort: 0,
                          processCommandLine: "/Applications/RustDesk.app/Contents/MacOS/RustDesk --server"),
        ActiveSocketEntry(pid: 1075, isTCP: true, isEstablished: true, isListen: false,
                          localIP: "::100.64.0.10", localPort: 21118, remoteIP: "::100.64.0.20", remotePort: 59417,
                          processCommandLine: "/Applications/RustDesk.app/Contents/MacOS/RustDesk --server"),
        ActiveSocketEntry(pid: 2048, isTCP: true, isEstablished: true, isListen: false,
                          localIP: "::100.64.0.20", localPort: 59417, remoteIP: "::100.64.0.10", remotePort: 21118,
                          processCommandLine: "/Applications/RustDesk.app/Contents/MacOS/RustDesk"),
        ActiveSocketEntry(pid: 2049, isTCP: true, isEstablished: true, isListen: false,
                          localIP: "::ffff:100.64.0.20", localPort: 59419, remoteIP: "::ffff:100.64.0.15", remotePort: 21118,
                          processCommandLine: "/Applications/RustDesk.app/Contents/MacOS/RustDesk"),
        ActiveSocketEntry(pid: 2048, isTCP: true, isEstablished: true, isListen: false,
                          localIP: "fd7a:115c:a1e0::20", localPort: 59418,
                          remoteIP: "fd7a:115c:a1e0::30", remotePort: 5900,
                          processCommandLine: "/System/Library/CoreServices/Applications/Screen Sharing.app/Contents/MacOS/Screen Sharing"),
    ]
    let filtered = SocketInspector.filterClientTailscalePeerIPs(
        sockets: sockets,
        selfIPs: ["100.64.0.20", "fd7a:115c:a1e0::20"]
    )
    try expectEqual(filtered, ["100.64.0.10", "100.64.0.15", "fd7a:115c:a1e0::30"])
}

runTest("Four-tier remote target resolver and safe fallback policy") {
    let macDesk = TailscalePeer(
        hostName: "mac-desk", dnsName: "mac-desk.example.ts.net.", os: "macOS",
        ipv4: "100.64.0.10", ipv6: nil, online: true, active: true,
        directAddr: "192.0.2.10:41641", relay: "tok"
    )
    let winPC = TailscalePeer(
        hostName: "WIN-DESKTOP", dnsName: "win-desktop.example.ts.net.", os: "windows",
        ipv4: "100.64.0.30", ipv6: nil, online: true, active: false,
        directAddr: "", relay: "tok"
    )
    let snapshot = TailscaleStatusSnapshot(selfNode: nil, peers: [macDesk, winPC])
    var settings = AppSettings()

    let lobbyCtx = RemoteTargetResolver.resolve(
        bundleID: "com.carriez.rustdesk", frontmostPID: 100, windowTitle: "RustDesk",
        activeClientSocketIPs: [], snapshot: snapshot, settings: settings
    )
    try expectEqual(lobbyCtx.isLobbyWindow, true)
    try expectEqual(lobbyCtx.hasActiveRemoteSession, false)

    let socketCtx = RemoteTargetResolver.resolve(
        bundleID: "com.carriez.rustdesk", frontmostPID: 100, windowTitle: "123456789",
        activeClientSocketIPs: ["100.64.0.10"], snapshot: snapshot, settings: settings
    )
    try expectEqual(socketCtx.resolvedPeer?.hostName, "mac-desk")
    try expectEqual(socketCtx.resolutionSource, "socket")

    settings.learnedWindowTitles["123456789"] = "100.64.0.10"
    let learnedCtx = RemoteTargetResolver.resolve(
        bundleID: "com.carriez.rustdesk", frontmostPID: 100, windowTitle: "123456789",
        activeClientSocketIPs: ["100.64.0.10", "100.64.0.30"], snapshot: snapshot, settings: settings
    )
    try expectEqual(learnedCtx.resolvedPeer?.hostName, "mac-desk")
    try expectEqual(learnedCtx.resolutionSource, "learned-title")

    try expectEqual(RemoteTargetResolver.resolveFallbackAction(mode: .autoByOS, peer: winPC), .sendModifierTap(keyCode: VirtualKeyCode.rightOption))
    try expectEqual(RemoteTargetResolver.resolveFallbackAction(mode: .autoByOS, peer: macDesk), .passthrough)
}

runTest("CSystemBridge live helpers, proc_listallpids lookup & real loopback UDP authenticated round-trip") {
    var pathBuf = [CChar](repeating: 0, count: 1024)
    try expect(tailime_pid_path(getpid(), &pathBuf, Int32(pathBuf.count)))
    let myPath = String(cString: pathBuf)
    try expect(!myPath.isEmpty)

    // Verify proc_listallpids finds our own running binary (verifies PID-count return unit fix!)
    var foundPids = [pid_t](repeating: 0, count: 16)
    let foundCount = "tailime-test".withCString { cstr in
        tailime_find_pids_matching_path(cstr, &foundPids, Int32(foundPids.count))
    }
    try expect(foundCount >= 1, "tailime_find_pids_matching_path must find running tailime-test process")
    try expect(foundPids.prefix(Int(foundCount)).contains(getpid()), "Own PID must appear in proc_listallpids search")

    var ifBuf = [CChar](repeating: 0, count: 64)
    try expect(tailime_interface_name_for_ip("127.0.0.1", &ifBuf, Int32(ifBuf.count)))
    try expect(String(cString: ifBuf).hasPrefix("lo"))
    try expect(tailime_ipv6_pktinfo_cmsg_type() > 0)

    // Live loopback UDP socket round-trip with IP_RECVIF + TIV1 HMAC verification
    let rxFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    try expect(rxFD >= 0, "Failed to open rx UDP socket")
    defer { close(rxFD) }

    var one: Int32 = 1
    _ = setsockopt(rxFD, IPPROTO_IP, IP_RECVIF, &one, socklen_t(MemoryLayout<Int32>.size))

    var bindAddr = sockaddr_in()
    bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    bindAddr.sin_family = sa_family_t(AF_INET)
    bindAddr.sin_port = 0 // ephemeral loopback port
    _ = inet_pton(AF_INET, "127.0.0.1", &bindAddr.sin_addr)

    let boundRC = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(rxFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try expectEqual(boundRC, 0, "Failed to bind loopback socket")

    var actualAddr = sockaddr_in()
    var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actualAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(rxFD, sa, &actualLen)
        }
    }
    let rxPort = UInt16(bigEndian: actualAddr.sin_port)
    try expect(rxPort > 0)

    let txFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    try expect(txFD >= 0)
    defer { close(txFD) }

    let macA = CryptoIdentity.generateEphemeral()
    let macB = CryptoIdentity.generateEphemeral()
    let key = try unwrap(macA.derivePeerHMACKey(peerPublicKeyBase64: macB.publicKeyBase64))
    let msg = WireMessage(
        cmd: .set,
        senderDeviceID: macA.deviceID,
        senderName: "mac-laptop",
        bootSessionID: "test-boot",
        seq: 7,
        targetLanguage: .korean
    )
    let rawPacket = try WirePacketCodec.encode(message: msg, key: key, nonce: 123456)

    let sent = rawPacket.withUnsafeBytes { raw -> Int in
        withUnsafePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(txFD, raw.baseAddress!, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    try expectEqual(sent, rawPacket.count)

    var recvBuf = [UInt8](repeating: 0, count: 2048)
    let received = recv(rxFD, &recvBuf, recvBuf.count, 0)
    try expectEqual(received, rawPacket.count)

    let decoded = try WirePacketCodec.decode(data: Data(recvBuf[0..<received])) { sender in
        sender == macA.deviceID ? key : nil
    }
    try expectEqual(decoded.message.cmd, .set)
    try expectEqual(decoded.message.targetLanguage, .korean)
    try expectEqual(decoded.nonce, 123456)
}

runTest("Live macOS environment read-only smoke test (SymbolicHotkeys + Karabiner)") {
    let hk = SymbolicHotkeysParser.readSystem()
    let kar = KarabinerConfigParser.loadDefault()
    let settings = AppSettings()
    let active = TriggerResolver.resolveActiveTriggers(settings: settings, systemHotkeys: hk, karabiner: kar)
    try expect(!active.isEmpty, "Should auto-detect at least hardware Lang1 or system/Karabiner triggers")
    print("    (live detected triggers on this Mac: \(active.map(\.label).joined(separator: ", ")))")
}

print("\nSummary: \(passedCount) passed, \(failedCount) failed")
exit(failedCount == 0 ? 0 : 1)
