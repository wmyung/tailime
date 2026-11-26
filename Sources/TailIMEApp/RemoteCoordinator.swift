import AppKit
import CryptoKit
import Foundation
import TailIMECore

/// Coordinates all remote Tailscale communication, hybrid in-band carrier + UDP absolute switching,
/// continuous Auto-ABC locking on remote focus, mutual pre-approval 6-digit SAS pairing,
/// strict `(deviceID, sourceIP, nonce, replyToSeq)` ACK binding, and fallback key bridging.
final class RemoteCoordinator {
    private(set) var identity: CryptoIdentity
    private(set) var identityPersistent: Bool
    let bootSessionID: String
    let settingsStore: SettingsStore
    let localEngine: LocalSwitchEngine
    let tapController: EventTapController
    let udpEndpoint: TailscaleUDPEndpoint

    private var seqCounter: UInt64 = 0
    private var tailscaleSnapshot = TailscaleStatusSnapshot(selfNode: nil, peers: [])
    private(set) var peerStates: [String: RemotePeerRuntimeState] = [:] // keyed by peer IP

    // Pending outbound requests strictly bound to `(targetDeviceID, targetIP, nonce, seq)`
    private struct PendingRequest {
        let seq: UInt64
        let nonce: UInt64
        let targetDeviceID: String
        let targetIP: String
        let targetHost: String
        let targetLang: InputLanguage
        let sentAt: TimeInterval
        let holdGateGen: UInt64
        var retryWork: DispatchWorkItem?
    }
    private var pendingRequests: [UInt64: PendingRequest] = [:] // keyed by outbound seq

    private struct PendingPing {
        let seq: UInt64
        let nonce: UInt64
        let targetDeviceID: String
        let targetIP: String
        let sentAt: TimeInterval
        let completion: ((Result<(host: String, rttMs: Double, lang: InputLanguage), Error>) -> Void)?
    }
    private var pendingPings: [UInt64: PendingPing] = [:]

    private struct PendingProbe {
        let seq: UInt64
        let nonce: UInt64
        let targetDeviceID: String
        let targetIP: String
        let bundleID: String
        let windowTitle: String
    }
    private var pendingProbes: [UInt64: PendingProbe] = [:]

    // Pending remote receiver `expectSet` safety-net timers (cancelled if in-band carrier arrives first!)
    private var pendingExpectWork: DispatchWorkItem?
    private var lastCarrierArrivalAt: TimeInterval = 0
    private var lastCarrierLanguage: InputLanguage?

    // Probe tracking (receiver side)
    private var lastProbeObservedAt: TimeInterval = 0
    private var lastProbeInjector: String = ""
    private var carrierSupportBySessionKey: [String: Bool] = [:] // "<bundleID>|<peerIP>" -> Bool

    // Track whether an HMAC-authenticated paired peer is actively controlling THIS Mac (30s window, NEVER self-extended by unauthenticated keys!)
    private var activePairedControllerUntil: TimeInterval = 0
    private var controllerExpiryWork: DispatchWorkItem?
    private var remoteKeepaliveTimer: Timer?

    // Continuous rate-limited Auto-ABC guard while focused on a remote session
    private var savedLocalSourceBeforeRemote: String?
    private var autoABCCheckWork: DispatchWorkItem?
    private var lastRemoteFocused = false
    private var autoABCCorrectionTimestamps: [TimeInterval] = []
    private var currentRemoteContext = ActiveRemoteContext()

    // Pending incoming pairing prompts (prevent duplicate alerts from UDP retries)
    private var activePairingPromptDeviceIDs: Set<String> = []
    private var lastKnownRemoteLanguageByIP: [String: InputLanguage] = [:]

    var onStateUpdated: (() -> Void)?
    var onRemoteSwitchedHUD: ((String, InputLanguage?, Double?, Bool) -> Void)? // (host, lang, rttMs, isFallback)
    var onPairingCompleted: ((TrustedPeerRecord) -> Void)?

    init(
        identity: CryptoIdentity,
        identityPersistent: Bool = true,
        settingsStore: SettingsStore,
        localEngine: LocalSwitchEngine,
        tapController: EventTapController,
        udpEndpoint: TailscaleUDPEndpoint
    ) {
        self.identity = identity
        self.identityPersistent = identityPersistent
        self.bootSessionID = UUID().uuidString.prefix(12).description
        self.settingsStore = settingsStore
        self.localEngine = localEngine
        self.tapController = tapController
        self.udpEndpoint = udpEndpoint

        syncKeysToEndpoint()
        wireCallbacks()
    }

    var currentTailscaleSnapshot: TailscaleStatusSnapshot {
        tailscaleSnapshot
    }

    var hostDisplayName: String {
        tailscaleSnapshot.selfNode?.hostName ?? Host.current().localizedName ?? "Mac"
    }

    func updateTailscaleSnapshot(_ snapshot: TailscaleStatusSnapshot) {
        tailscaleSnapshot = snapshot
        udpEndpoint.updateTailscaleSnapshot(snapshot)

        // Update saved peer IPs from our own trusted local Tailscale daemon status
        for peer in snapshot.peers where peer.isMacOS {
            guard let ip = peer.preferredIP else { continue }
            for trusted in settingsStore.trustedPeers {
                if trusted.name.caseInsensitiveCompare(peer.hostName) == .orderedSame
                    || trusted.name.caseInsensitiveCompare(peer.shortDNSName) == .orderedSame {
                    settingsStore.updateTrustedPeerIP(deviceID: trusted.deviceID, ip: ip)
                }
            }
        }
        syncTapRemoteHintSnapshot()
        onStateUpdated?()
    }

    func updateIdentity(_ newIdentity: CryptoIdentity, persistent: Bool) {
        identity = newIdentity
        identityPersistent = persistent
        syncKeysToEndpoint()
        if persistent {
            probeAllPairedMacPeers()
        }
        onStateUpdated?()
    }

    func syncKeysToEndpoint() {
        var map: [String: SymmetricKey] = [:]
        if identityPersistent {
            for record in settingsStore.trustedPeers {
                if let key = identity.derivePeerHMACKey(peerPublicKeyBase64: record.publicKeyBase64) {
                    map[record.deviceID] = key
                }
            }
        }
        udpEndpoint.updatePeerKeys(map)
        syncTapRemoteHintSnapshot()
    }

    /// Publishes precomputed remote hold duration, synchronous in-band carrier key, & unpaired passthrough hints
    /// into `EventTapController`'s atomic snapshot so the O(µs) tap callback stays zero-gap and non-blocking.
    func syncTapRemoteHintSnapshot() {
        let settings = settingsStore.settings
        let ctx = currentRemoteContext
        let carrierPair = tapController.currentSnapshot().carrierPair

        var holdDuration: TimeInterval = 0
        var nextInBandCarrierKeyCode: Int64 = 0
        var unpairedPassthrough = false

        if settings.remoteSyncEnabled && ctx.hasActiveRemoteSession {
            if let peer = ctx.resolvedPeer, let ip = peer.preferredIP,
               trustedRecord(forPeer: peer) != nil {
                if identityPersistent {
                    let sessionKey = "\(ctx.bundleID)|\(ip)"
                    let isRustDesk = ctx.bundleID.lowercased().contains("rustdesk")
                    // Prefer pure Direct UDP + adaptive HoldGate on Direct Tailscale paths and ALWAYS on RustDesk
                    // (RustDesk's rdev/enigo maps extended F16/F17/F20 inconsistently on macOS).
                    // On DERP-relayed non-RustDesk sessions (e.g. Apple Screen Sharing) or explicit inBandOnly, allow in-band carriers.
                    let usesInBand = (settings.transportMode == .inBandOnly)
                        || (settings.transportMode == .autoHybrid && !isRustDesk && !peer.isDirectPath && carrierSupportBySessionKey[sessionKey] == true)
                    if usesInBand {
                        let currentRemoteLang = peerStates[ip]?.currentLanguage
                            ?? lastKnownRemoteLanguageByIP[ip]
                            ?? .english
                        nextInBandCarrierKeyCode = carrierPair.keyCode(for: currentRemoteLang.toggled)
                    } else if peer.isDirectPath {
                        let rttSec = (peerStates[ip]?.lastRTTMs ?? 8.0) / 1000.0
                        holdDuration = min(0.060, max(0.020, rttSec * 2.0 + 0.012))
                    }
                }
            } else if !ctx.isAmbiguousMultiSession {
                let fallbackAction = RemoteTargetResolver.resolveFallbackAction(
                    mode: settings.fallbackKeyMode,
                    peer: ctx.resolvedPeer
                )
                unpairedPassthrough = (fallbackAction == .passthrough)
            }
        }

        tapController.updateSnapshot { snap in
            snap.remoteDirectHoldDuration = holdDuration
            snap.remoteNextInBandCarrierKeyCode = nextInBandCarrierKeyCode
            snap.remoteUnpairedPassthrough = unpairedPassthrough
        }
    }

    // MARK: - Focus & Continuous Auto-ABC Guard

    func handleRemoteContextChanged(_ context: ActiveRemoteContext) {
        currentRemoteContext = context
        let settings = settingsStore.settings
        let isFocused = context.hasActiveRemoteSession

        if isFocused && !lastRemoteFocused {
            autoABCCorrectionTimestamps.removeAll()
            if settings.autoEnglishOnRemoteFocus {
                applyAutoEnglishOnRemoteFocus()
            }
        } else if !isFocused && lastRemoteFocused {
            // Safely flush held keys on focus exit (preserving orphan keyUps & flagsChanged so nothing sticks!)
            tapController.flushHoldGateAsync(reason: .focusChanged, discard: true)
            autoABCCheckWork?.cancel()
            autoABCCheckWork = nil
            if settings.restoreLocalSourceOnRemoteBlur, let saved = savedLocalSourceBeforeRemote {
                localEngine.switchToSourceID(saved, allowHotkeyPulse: false)
            }
            savedLocalSourceBeforeRemote = nil
        }
        lastRemoteFocused = isFocused
        syncTapRemoteHintSnapshot()

        // Immediately send authenticated status query on focus + keep alive every 20s while focused
        // so remote Mac's 30s authenticated controller window stays warm ONLY while we actively control it!
        remoteKeepaliveTimer?.invalidate()
        remoteKeepaliveTimer = nil
        if isFocused, let peer = context.resolvedPeer, let ip = peer.preferredIP {
            requestStatus(fromPeerIP: ip, hostName: peer.hostName)
            let timer = Timer(timeInterval: 20.0, repeats: true) { [weak self] _ in
                guard let self, self.lastRemoteFocused else { return }
                self.requestStatus(fromPeerIP: ip, hostName: peer.hostName)
            }
            timer.tolerance = 2.0
            RunLoop.main.add(timer, forMode: .common)
            remoteKeepaliveTimer = timer
        }
        onStateUpdated?()
    }

    /// Called whenever Local Mac's input source changes: if we are currently focused on a remote session
    /// and `autoEnglishOnRemoteFocus` is ON, keeps Local Mac locked on English (rate-limited to prevent flapping).
    func handleLocalSourceChangedWhileRemoteFocused(_ info: InputSourceInfo) {
        guard lastRemoteFocused,
              settingsStore.settings.remoteSyncEnabled,
              settingsStore.settings.autoEnglishOnRemoteFocus,
              info.language != .english else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        autoABCCorrectionTimestamps = autoABCCorrectionTimestamps.filter { now - $0 < 2.0 }
        guard autoABCCorrectionTimestamps.count < 3 else {
            // Respect persistent external/user override after 3 rapid attempts within 2s (no infinite flapping!)
            return
        }
        autoABCCorrectionTimestamps.append(now)
        if savedLocalSourceBeforeRemote == nil {
            savedLocalSourceBeforeRemote = info.id
        }
        localEngine.switchTo(language: .english, allowHotkeyPulse: false)
    }

    private func applyAutoEnglishOnRemoteFocus() {
        autoABCCheckWork?.cancel()
        if let cur = localEngine.currentInputSource(), cur.language != .english {
            savedLocalSourceBeforeRemote = cur.id
            localEngine.switchTo(language: .english, allowHotkeyPulse: false)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.lastRemoteFocused else { return }
                if self.localEngine.currentInputSource()?.language != .english {
                    self.localEngine.switchTo(language: .english, allowHotkeyPulse: false)
                }
            }
            autoABCCheckWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    // MARK: - Trigger Handling (When Controlling a Remote Machine)

    func handleRemoteTrigger(
        spec: TriggerSpec,
        isOwned: Bool,
        context: ActiveRemoteContext,
        holdGen: UInt64,
        alreadyInjectedCarrierKeyCode: Int64 = 0
    ) {
        let settings = settingsStore.settings
        guard settings.remoteSyncEnabled else {
            if holdGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
            }
            if isOwned || spec.kind == .modifierTap {
                _ = localEngine.toggleKoreanEnglish(allowHotkeyPulse: false)
            }
            return
        }

        var resolvedPeer = context.resolvedPeer
        if resolvedPeer == nil && context.isAmbiguousMultiSession {
            // If multiple sessions are open, check whether only ONE candidate is a paired TailIME Mac.
            let pairedCandidates = context.candidatePeerIPs.compactMap { ip -> TailscalePeer? in
                guard let candidate = tailscaleSnapshot.peer(matchingIP: ip),
                      trustedRecord(forPeer: candidate) != nil else { return nil }
                return candidate
            }
            if pairedCandidates.count == 1 {
                resolvedPeer = pairedCandidates[0]
            } else {
                if holdGen != 0 {
                    tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
                }
                if !identityPersistent {
                    if !pairedCandidates.isEmpty && settings.showRemoteHUD {
                        onRemoteSwitchedHUD?("키체인 접근 허용 필요", nil, nil, true)
                    }
                    return
                }
                let isRustDesk = context.bundleID.lowercased().contains("rustdesk")
                if settings.transportMode != .udpDirectOnly && !isRustDesk && !pairedCandidates.isEmpty {
                    probeAndBindAmbiguousSession(context: context)
                } else if settings.showRemoteHUD {
                    onRemoteSwitchedHUD?("원격 대상 선택 필요 (메뉴바에서 고정)", nil, nil, true)
                }
                return
            }
        }

        guard let peer = resolvedPeer, let ip = peer.preferredIP else {
            if holdGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
            }
            executeFallbackBridge(spec: spec, isOwned: isOwned, peer: nil, context: context)
            return
        }

        guard let trusted = trustedRecord(forPeer: peer) else {
            if holdGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
            }
            executeFallbackBridge(spec: spec, isOwned: isOwned, peer: peer, context: context)
            return
        }

        guard identityPersistent,
              let hmacKey = identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
            if holdGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
            }
            if settings.showRemoteHUD {
                onRemoteSwitchedHUD?("키체인 접근 허용 필요", nil, nil, true)
            }
            return
        }

        let carrierPair = tapController.currentSnapshot().carrierPair
        let currentRemoteLang = peerStates[ip]?.currentLanguage
            ?? lastKnownRemoteLanguageByIP[ip]
            ?? .english
        // If tap synchronously injected an in-band carrier, match its exact target language!
        let targetLang = carrierPair.language(for: alreadyInjectedCarrierKeyCode) ?? currentRemoteLang.toggled

        lastKnownRemoteLanguageByIP[ip] = targetLang
        if var st = peerStates[ip] {
            st.currentLanguage = targetLang
            peerStates[ip] = st
        }
        syncTapRemoteHintSnapshot()

        let sessionKey = "\(context.bundleID)|\(ip)"
        let carrierKnown = carrierSupportBySessionKey[sessionKey]

        switch settings.transportMode {
        case .inBandOnly:
            if holdGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
            }
            if alreadyInjectedCarrierKeyCode == 0 {
                tapController.injectInBandCarrier(keyCode: carrierPair.keyCode(for: targetLang))
            }
            sendExpectSetUDP(
                targetLang: targetLang,
                targetDeviceID: trusted.deviceID,
                toIP: ip,
                hostName: peer.hostName,
                key: hmacKey,
                deadlineMs: 250
            )

        case .udpDirectOnly:
            sendDirectSetUDP(
                targetLang: targetLang,
                targetDeviceID: trusted.deviceID,
                toIP: ip,
                hostName: peer.hostName,
                key: hmacKey,
                holdGen: holdGen
            )

        case .autoHybrid:
            let isRustDesk = context.bundleID.lowercased().contains("rustdesk")
            if !isRustDesk && !peer.isDirectPath && (carrierKnown == true || alreadyInjectedCarrierKeyCode != 0) {
                if holdGen != 0 {
                    tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: holdGen)
                }
                let deadlineMs = 130
                if alreadyInjectedCarrierKeyCode == 0 {
                    tapController.injectInBandCarrier(keyCode: carrierPair.keyCode(for: targetLang))
                }
                sendExpectSetUDP(
                    targetLang: targetLang,
                    targetDeviceID: trusted.deviceID,
                    toIP: ip,
                    hostName: peer.hostName,
                    key: hmacKey,
                    deadlineMs: deadlineMs
                )
            } else {
                sendDirectSetUDP(
                    targetLang: targetLang,
                    targetDeviceID: trusted.deviceID,
                    toIP: ip,
                    hostName: peer.hostName,
                    key: hmacKey,
                    holdGen: holdGen
                )
                if !isRustDesk && !peer.isDirectPath && carrierKnown == nil {
                    probeCarrierCapability(
                        bundleID: context.bundleID,
                        targetDeviceID: trusted.deviceID,
                        peerIP: ip,
                        key: hmacKey,
                        windowTitle: context.windowTitle
                    )
                }
            }
        }
    }

    private func executeFallbackBridge(spec: TriggerSpec, isOwned: Bool, peer: TailscalePeer?, context: ActiveRemoteContext) {
        let mode = settingsStore.settings.fallbackKeyMode
        let action = RemoteTargetResolver.resolveFallbackAction(mode: mode, peer: peer)
        let localBefore = localEngine.currentInputSource()?.id

        tapController.injectFallbackAction(action, originalSpec: isOwned ? spec : nil)

        if let localBefore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                guard let self else { return }
                if self.localEngine.currentInputSource()?.id != localBefore {
                    self.localEngine.switchToSourceID(localBefore, allowHotkeyPulse: false)
                }
            }
        }

        if settingsStore.settings.showRemoteHUD {
            let label = peer?.hostName ?? (context.windowTitle.isEmpty ? "원격" : context.windowTitle)
            onRemoteSwitchedHUD?(label, nil, nil, true)
        }
    }

    // MARK: - Outbound UDP Senders

    private func nextSeq() -> UInt64 {
        seqCounter &+= 1
        return seqCounter
    }

    private func sendDirectSetUDP(
        targetLang: InputLanguage,
        targetDeviceID: String,
        toIP ip: String,
        hostName: String,
        key: SymmetricKey,
        holdGen: UInt64
    ) {
        let seq = nextSeq()
        let nonce = UInt64.random(in: 1...UInt64.max)
        let now = ProcessInfo.processInfo.systemUptime

        let msg = WireMessage(
            cmd: .set,
            senderDeviceID: identity.deviceID,
            senderName: hostDisplayName,
            bootSessionID: bootSessionID,
            seq: seq,
            targetLanguage: targetLang,
            version: "1.0.2"
        )
        udpEndpoint.send(message: msg, toIP: ip, key: key, nonce: nonce)

        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRequests[seq] != nil else { return }
            self.udpEndpoint.send(message: msg, toIP: ip, key: key, nonce: nonce)
        }
        pendingRequests[seq] = PendingRequest(
            seq: seq,
            nonce: nonce,
            targetDeviceID: targetDeviceID,
            targetIP: ip,
            targetHost: hostName,
            targetLang: targetLang,
            sentAt: now,
            holdGateGen: holdGen,
            retryWork: retry
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: retry)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let req = self.pendingRequests.removeValue(forKey: seq) else { return }
            req.retryWork?.cancel()
            if req.holdGateGen != 0 {
                self.tapController.flushHoldGateAsync(reason: .timeout, expectedGeneration: req.holdGateGen)
            }
        }
    }

    private func sendExpectSetUDP(
        targetLang: InputLanguage,
        targetDeviceID: String,
        toIP ip: String,
        hostName: String,
        key: SymmetricKey,
        deadlineMs: Int
    ) {
        let seq = nextSeq()
        let nonce = UInt64.random(in: 1...UInt64.max)
        let now = ProcessInfo.processInfo.systemUptime

        let msg = WireMessage(
            cmd: .expectSet,
            senderDeviceID: identity.deviceID,
            senderName: hostDisplayName,
            bootSessionID: bootSessionID,
            seq: seq,
            targetLanguage: targetLang,
            carrierDeadlineMs: deadlineMs,
            version: "1.0.2"
        )
        udpEndpoint.send(message: msg, toIP: ip, key: key, nonce: nonce)

        pendingRequests[seq] = PendingRequest(
            seq: seq,
            nonce: nonce,
            targetDeviceID: targetDeviceID,
            targetIP: ip,
            targetHost: hostName,
            targetLang: targetLang,
            sentAt: now,
            holdGateGen: 0,
            retryWork: nil
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.pendingRequests.removeValue(forKey: seq)
        }
    }

    /// Sends a manual deterministic `.set` (e.g. from `tailime-ctl remote-set`) using the coordinator's
    /// monotonic `nextSeq()` counter so CLI tests NEVER poison the peer's sliding-window replay guard!
    func sendManualRemoteSet(
        targetQuery: String,
        targetLang: InputLanguage
    ) -> (peerName: String, ip: String)? {
        let trusted: TrustedPeerRecord?
        if let direct = settingsStore.trustedPeer(matchingIP: targetQuery) {
            trusted = direct
        } else if let tsPeer = tailscaleSnapshot.peer(matchingIP: targetQuery) {
            trusted = trustedRecord(forPeer: tsPeer)
        } else {
            trusted = settingsStore.trustedPeers.first {
                $0.name.caseInsensitiveCompare(targetQuery) == .orderedSame
            }
        }
        guard identityPersistent,
              let trusted,
              let liveIP = resolveLiveIP(for: trusted) ?? (TailscaleIPValidator.isTailscaleIP(targetQuery) ? targetQuery : nil),
              let hmacKey = identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
            return nil
        }

        lastKnownRemoteLanguageByIP[liveIP] = targetLang
        if var st = peerStates[liveIP] {
            st.currentLanguage = targetLang
            peerStates[liveIP] = st
        }
        syncTapRemoteHintSnapshot()

        sendDirectSetUDP(
            targetLang: targetLang,
            targetDeviceID: trusted.deviceID,
            toIP: liveIP,
            hostName: trusted.name,
            key: hmacKey,
            holdGen: 0
        )
        return (trusted.name, liveIP)
    }

    func requestStatus(fromPeerIP ip: String, hostName: String) {
        guard identityPersistent,
              let trusted = trustedRecord(forIP: ip),
              let key = identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
            return
        }
        let msg = WireMessage(
            cmd: .status,
            senderDeviceID: identity.deviceID,
            senderName: hostDisplayName,
            bootSessionID: bootSessionID,
            seq: nextSeq()
        )
        udpEndpoint.send(message: msg, toIP: ip, key: key)
    }

    func pingPeer(
        ip: String,
        completion: ((Result<(host: String, rttMs: Double, lang: InputLanguage), Error>) -> Void)? = nil
    ) {
        guard identityPersistent else {
            completion?(.failure(NSError(
                domain: "TailIME",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "키체인 기기 키 접근이 거부되어 있습니다. '키체인 다시 읽기'를 눌러 허용해 주세요."]
            )))
            return
        }
        guard let trusted = trustedRecord(forIP: ip),
              let key = identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
            completion?(.failure(NSError(
                domain: "TailIME",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "먼저 이 Mac과 페어링해야 합니다."]
            )))
            return
        }

        let seq = nextSeq()
        let nonce = UInt64.random(in: 1...UInt64.max)
        let now = ProcessInfo.processInfo.systemUptime
        pendingPings[seq] = PendingPing(
            seq: seq,
            nonce: nonce,
            targetDeviceID: trusted.deviceID,
            targetIP: ip,
            sentAt: now,
            completion: completion
        )

        let msg = WireMessage(
            cmd: .ping,
            senderDeviceID: identity.deviceID,
            senderName: hostDisplayName,
            bootSessionID: bootSessionID,
            seq: seq,
            version: "1.0.2"
        )
        udpEndpoint.send(message: msg, toIP: ip, key: key, nonce: nonce)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let pending = self.pendingPings.removeValue(forKey: seq) else { return }
            pending.completion?(.failure(NSError(
                domain: "TailIME",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey: "응답 시간 초과 (상대 Mac에서 TailIME 실행 및 Tailscale 연결 확인)"]
            )))
        }
    }

    func probeAllPairedMacPeers() {
        guard identityPersistent else { return }
        for trusted in settingsStore.trustedPeers {
            if let ip = resolveLiveIP(for: trusted) {
                pingPeer(ip: ip, completion: nil)
            }
        }
    }

    func broadcastLocalStateChange(_ info: InputSourceInfo) {
        guard identityPersistent else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for trusted in settingsStore.trustedPeers {
            guard let ip = resolveLiveIP(for: trusted),
                  let key = identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
                continue
            }
            if let tsPeer = tailscaleSnapshot.peer(matchingIP: ip), !tsPeer.online && now > activePairedControllerUntil {
                continue
            }
            let msg = WireMessage(
                cmd: .state,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                currentLanguage: info.language,
                sourceID: info.id
            )
            udpEndpoint.send(message: msg, toIP: ip, key: key)
        }
    }

    // MARK: - In-Band Carrier Probing & Multi-Window Binding

    private func probeCarrierCapability(
        bundleID: String,
        targetDeviceID: String,
        peerIP: String,
        key: SymmetricKey,
        windowTitle: String
    ) {
        guard identityPersistent else { return }
        let carrierPair = tapController.currentSnapshot().carrierPair
        let token = UInt64.random(in: 1...UInt64.max)

        tapController.injectInBandCarrier(keyCode: carrierPair.probeKeyCode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.identityPersistent else { return }
            let seq = self.nextSeq()
            let nonce = UInt64.random(in: 1...UInt64.max)
            self.pendingProbes[seq] = PendingProbe(
                seq: seq,
                nonce: nonce,
                targetDeviceID: targetDeviceID,
                targetIP: peerIP,
                bundleID: bundleID,
                windowTitle: windowTitle
            )
            let query = WireMessage(
                cmd: .probeQuery,
                senderDeviceID: self.identity.deviceID,
                senderName: self.hostDisplayName,
                bootSessionID: self.bootSessionID,
                seq: seq,
                probeToken: token
            )
            self.udpEndpoint.send(message: query, toIP: peerIP, key: key, nonce: nonce)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.pendingProbes.removeValue(forKey: seq)
            }
        }
    }

    private func probeAndBindAmbiguousSession(context: ActiveRemoteContext) {
        guard identityPersistent else { return }
        let carrierPair = tapController.currentSnapshot().carrierPair
        let token = UInt64.random(in: 1...UInt64.max)

        tapController.injectInBandCarrier(keyCode: carrierPair.probeKeyCode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, self.identityPersistent else { return }
            for ip in context.candidatePeerIPs {
                guard let trusted = self.trustedRecord(forIP: ip),
                      let key = self.identity.derivePeerHMACKey(peerPublicKeyBase64: trusted.publicKeyBase64) else {
                    continue
                }
                let seq = self.nextSeq()
                let nonce = UInt64.random(in: 1...UInt64.max)
                self.pendingProbes[seq] = PendingProbe(
                    seq: seq,
                    nonce: nonce,
                    targetDeviceID: trusted.deviceID,
                    targetIP: ip,
                    bundleID: context.bundleID,
                    windowTitle: context.windowTitle
                )
                let query = WireMessage(
                    cmd: .probeQuery,
                    senderDeviceID: self.identity.deviceID,
                    senderName: self.hostDisplayName,
                    bootSessionID: self.bootSessionID,
                    seq: seq,
                    probeToken: token
                )
                self.udpEndpoint.send(message: query, toIP: ip, key: key, nonce: nonce)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.pendingProbes.removeValue(forKey: seq)
                }
            }
        }
    }

    // MARK: - Direct Tailscale Pairing (Mutual Pre-Approval Key Exchange + 6-Digit SAS)

    @discardableResult
    func initiatePairing(withPeerIP ip: String, isReply: Bool = false) -> Bool {
        guard identityPersistent else { return false }
        let hello = WireMessage(
            cmd: .pairHello,
            senderDeviceID: identity.deviceID,
            senderName: hostDisplayName,
            bootSessionID: bootSessionID,
            seq: nextSeq(),
            publicKeyBase64: identity.publicKeyBase64,
            pairReply: isReply,
            version: "1.0.2"
        )
        udpEndpoint.send(message: hello, toIP: ip, key: nil)
        return true
    }

    @discardableResult
    func importPairingToken(_ token: String) -> TrustedPeerRecord? {
        guard let payload = CryptoIdentity.decodePairingToken(token),
              payload.deviceID != identity.deviceID else {
            return nil
        }
        let record = TrustedPeerRecord(
            deviceID: payload.deviceID,
            name: payload.name,
            publicKeyBase64: payload.publicKeyBase64,
            lastKnownIP: payload.tailscaleIP
        )
        settingsStore.saveTrustedPeer(record)
        syncKeysToEndpoint()
        if let ip = record.lastKnownIP {
            pingPeer(ip: ip, completion: nil)
        }
        onPairingCompleted?(record)
        onStateUpdated?()
        return record
    }

    // MARK: - Wiring Incoming Events & Packets

    private func wireCallbacks() {
        // Remote Host Side: Authenticated paired controller's In-Band Carrier arrived!
        // Note: NEVER self-extend `activePairedControllerUntil` from an unauthenticated keystroke —
        // only HMAC-authenticated UDP packets extend the controller window!
        tapController.onInBandCarrierReceived = { [weak self] targetLang, _, sessionHoldGen in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingExpectWork?.cancel()
                self.pendingExpectWork = nil
                self.lastCarrierArrivalAt = ProcessInfo.processInfo.systemUptime
                self.lastCarrierLanguage = targetLang
                self.localEngine.switchTo(language: targetLang, allowHotkeyPulse: true) { [weak self] info in
                    guard let self else { return }
                    if sessionHoldGen != 0 {
                        self.tapController.flushSessionHoldGateAsync(reason: .completed, expectedGeneration: sessionHoldGen)
                    }
                    if let info {
                        self.broadcastLocalStateChange(info)
                    }
                }
            }
        }

        tapController.onInBandProbeReceived = { [weak self] injector, uptime in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastProbeObservedAt = uptime
                self.lastProbeInjector = injector
            }
        }

        udpEndpoint.onPacketReceived = { [weak self] incoming in
            DispatchQueue.main.async {
                self?.handleIncomingPacket(incoming)
            }
        }
    }

    private func handleIncomingPacket(_ incoming: IncomingUDPPacket) {
        let msg = incoming.packet.message
        let srcIP = incoming.sourceIP
        let srcPort = incoming.sourcePort

        // Security rule: ONLY update a trusted peer's saved IP after constant-time HMAC authentication succeeds!
        if incoming.packet.authenticated {
            settingsStore.updateTrustedPeerIP(deviceID: msg.senderDeviceID, ip: srcIP)
        }

        let peerKey = settingsStore.trustedPeer(deviceID: msg.senderDeviceID)
            .flatMap { identity.derivePeerHMACKey(peerPublicKeyBase64: $0.publicKeyBase64) }

        switch msg.cmd {
        case .pairHello:
            handleIncomingPairHello(msg: msg, srcIP: srcIP, srcPort: srcPort)

        case .pairAck:
            guard incoming.packet.authenticated else { return }
            pingPeer(ip: srcIP, completion: nil)

        case .ping:
            guard incoming.packet.authenticated, let peerKey else { return }
            let cur = localEngine.currentInputSource()
            let pong = WireMessage(
                cmd: .pong,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                replyToSeq: msg.seq,
                currentLanguage: cur?.language ?? .english,
                sourceID: cur?.id,
                ok: true,
                version: "1.0.2"
            )
            udpEndpoint.send(message: pong, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)

        case .pong:
            guard incoming.packet.authenticated, let replyTo = msg.replyToSeq else { return }
            guard let pending = pendingPings[replyTo],
                  pending.targetDeviceID == msg.senderDeviceID,
                  pending.targetIP == srcIP,
                  pending.nonce == incoming.packet.nonce else {
                return
            }
            pendingPings.removeValue(forKey: replyTo)

            let now = ProcessInfo.processInfo.systemUptime
            let rttMs = max(0.1, (now - pending.sentAt) * 1000.0)
            let lang = msg.currentLanguage ?? .english
            lastKnownRemoteLanguageByIP[srcIP] = lang

            pending.completion?(.success((msg.senderName ?? srcIP, rttMs, lang)))
            var state = peerStates[srcIP] ?? RemotePeerRuntimeState(
                peerID: msg.senderDeviceID,
                hostName: msg.senderName ?? srcIP,
                ip: srcIP
            )
            state.daemonReachable = true
            state.currentLanguage = lang
            state.currentSourceID = msg.sourceID
            state.lastRTTMs = rttMs
            state.lastSeenAt = Date()
            peerStates[srcIP] = state
            syncTapRemoteHintSnapshot()
            onStateUpdated?()

        case .status:
            guard incoming.packet.authenticated, let peerKey else { return }
            markPairedControllerActive()
            let cur = localEngine.currentInputSource()
            let stateMsg = WireMessage(
                cmd: .state,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                replyToSeq: msg.seq,
                currentLanguage: cur?.language ?? .english,
                sourceID: cur?.id,
                ok: true
            )
            udpEndpoint.send(message: stateMsg, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)

        case .state:
            guard incoming.packet.authenticated else { return }
            if let lang = msg.currentLanguage {
                lastKnownRemoteLanguageByIP[srcIP] = lang
                var state = peerStates[srcIP] ?? RemotePeerRuntimeState(
                    peerID: msg.senderDeviceID,
                    hostName: msg.senderName ?? srcIP,
                    ip: srcIP
                )
                state.daemonReachable = true
                state.currentLanguage = lang
                state.currentSourceID = msg.sourceID
                state.lastSeenAt = Date()
                peerStates[srcIP] = state
                onStateUpdated?()
            }

        case .set:
            guard incoming.packet.authenticated, let peerKey, let targetLang = msg.targetLanguage else { return }
            // Cancel any older pending expectSet timer so a stale expectSet can NEVER overwrite this newer .set!
            pendingExpectWork?.cancel()
            pendingExpectWork = nil
            markPairedControllerActive()
            localEngine.switchTo(language: targetLang, allowHotkeyPulse: true) { [weak self] info in
                guard let self else { return }
                let resultLang = info?.language ?? targetLang
                let ack = WireMessage(
                    cmd: .ack,
                    senderDeviceID: self.identity.deviceID,
                    senderName: self.hostDisplayName,
                    bootSessionID: self.bootSessionID,
                    seq: self.nextSeq(),
                    replyToSeq: msg.seq,
                    currentLanguage: resultLang,
                    sourceID: info?.id,
                    ok: true,
                    via: "udp"
                )
                self.udpEndpoint.cacheIdempotentReply(
                    ack,
                    forSenderDeviceID: msg.senderDeviceID,
                    bootSessionID: msg.bootSessionID,
                    seq: msg.seq
                )
                self.udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)
            }

        case .expectSet:
            guard incoming.packet.authenticated, let peerKey, let targetLang = msg.targetLanguage else { return }
            markPairedControllerActive()
            let now = ProcessInfo.processInfo.systemUptime
            if lastCarrierLanguage == targetLang && (now - lastCarrierArrivalAt) < 0.12 {
                let cur = localEngine.currentInputSource()
                let ack = WireMessage(
                    cmd: .ack,
                    senderDeviceID: identity.deviceID,
                    senderName: hostDisplayName,
                    bootSessionID: bootSessionID,
                    seq: nextSeq(),
                    replyToSeq: msg.seq,
                    currentLanguage: cur?.language ?? targetLang,
                    sourceID: cur?.id,
                    ok: true,
                    via: "carrier"
                )
                udpEndpoint.cacheIdempotentReply(ack, forSenderDeviceID: msg.senderDeviceID, bootSessionID: msg.bootSessionID, seq: msg.seq)
                udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)
                return
            }

            pendingExpectWork?.cancel()
            let deadlineSec = Double(min(250, max(20, msg.carrierDeadlineMs ?? 55))) / 1000.0
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let nowCheck = ProcessInfo.processInfo.systemUptime
                if self.lastCarrierLanguage == targetLang && (nowCheck - self.lastCarrierArrivalAt) < (deadlineSec + 0.08) {
                    let cur = self.localEngine.currentInputSource()
                    let ack = WireMessage(
                        cmd: .ack,
                        senderDeviceID: self.identity.deviceID,
                        senderName: self.hostDisplayName,
                        bootSessionID: self.bootSessionID,
                        seq: self.nextSeq(),
                        replyToSeq: msg.seq,
                        currentLanguage: cur?.language ?? targetLang,
                        sourceID: cur?.id,
                        ok: true,
                        via: "carrier"
                    )
                    self.udpEndpoint.cacheIdempotentReply(ack, forSenderDeviceID: msg.senderDeviceID, bootSessionID: msg.bootSessionID, seq: msg.seq)
                    self.udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)
                    return
                }
                self.localEngine.switchTo(language: targetLang, allowHotkeyPulse: true) { [weak self] info in
                    guard let self else { return }
                    let ack = WireMessage(
                        cmd: .ack,
                        senderDeviceID: self.identity.deviceID,
                        senderName: self.hostDisplayName,
                        bootSessionID: self.bootSessionID,
                        seq: self.nextSeq(),
                        replyToSeq: msg.seq,
                        currentLanguage: info?.language ?? targetLang,
                        sourceID: info?.id,
                        ok: true,
                        via: "udp-fallback"
                    )
                    self.udpEndpoint.cacheIdempotentReply(ack, forSenderDeviceID: msg.senderDeviceID, bootSessionID: msg.bootSessionID, seq: msg.seq)
                    self.udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)
                }
            }
            pendingExpectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + deadlineSec, execute: work)

        case .ack:
            // Strict binding: ACK must match our pending request's `(replyToSeq, targetDeviceID, targetIP, nonce)`!
            guard incoming.packet.authenticated,
                  let replyTo = msg.replyToSeq,
                  let req = pendingRequests[replyTo],
                  req.targetDeviceID == msg.senderDeviceID,
                  req.targetIP == srcIP,
                  req.nonce == incoming.packet.nonce else {
                return
            }
            pendingRequests.removeValue(forKey: replyTo)
            req.retryWork?.cancel()
            if req.holdGateGen != 0 {
                tapController.flushHoldGateAsync(reason: .completed, expectedGeneration: req.holdGateGen)
            }

            let now = ProcessInfo.processInfo.systemUptime
            let rttMs = max(0.1, (now - req.sentAt) * 1000.0)
            let resultLang = msg.currentLanguage ?? req.targetLang
            lastKnownRemoteLanguageByIP[srcIP] = resultLang

            if msg.via == "udp-fallback" {
                let bundle = currentRemoteContext.bundleID
                if !bundle.isEmpty {
                    carrierSupportBySessionKey["\(bundle)|\(srcIP)"] = false
                    syncTapRemoteHintSnapshot()
                }
            }

            var state = peerStates[srcIP] ?? RemotePeerRuntimeState(
                peerID: msg.senderDeviceID,
                hostName: msg.senderName ?? srcIP,
                ip: srcIP
            )
            state.daemonReachable = true
            state.currentLanguage = resultLang
            state.currentSourceID = msg.sourceID
            state.lastRTTMs = rttMs
            state.lastSeenAt = Date()
            peerStates[srcIP] = state
            syncTapRemoteHintSnapshot()
            onStateUpdated?()

            if settingsStore.settings.showRemoteHUD {
                onRemoteSwitchedHUD?(state.hostName, resultLang, rttMs, false)
            }

        case .probeQuery:
            guard incoming.packet.authenticated, let peerKey else { return }
            markPairedControllerActive()
            let now = ProcessInfo.processInfo.systemUptime
            let observed = (lastProbeObservedAt > 0) && ((now - lastProbeObservedAt) < 0.35)
            // Consume observation once so overlapping probe queries from another session cannot claim the same key!
            if observed {
                lastProbeObservedAt = 0
            }
            let reply = WireMessage(
                cmd: .probeResult,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                replyToSeq: msg.seq,
                ok: true,
                via: observed ? lastProbeInjector : "none",
                probeToken: msg.probeToken,
                probeObserved: observed
            )
            udpEndpoint.send(message: reply, toIP: srcIP, port: srcPort, key: peerKey, nonce: incoming.packet.nonce)

        case .probeResult:
            guard incoming.packet.authenticated,
                  let replyTo = msg.replyToSeq,
                  let pending = pendingProbes[replyTo],
                  pending.targetDeviceID == msg.senderDeviceID,
                  pending.targetIP == srcIP,
                  pending.nonce == incoming.packet.nonce else {
                return
            }
            pendingProbes.removeValue(forKey: replyTo)

            let observed = msg.probeObserved == true
            if !pending.bundleID.isEmpty {
                carrierSupportBySessionKey["\(pending.bundleID)|\(srcIP)"] = observed
            }
            if var state = peerStates[srcIP] {
                state.supportsInBandCarrier = observed
                peerStates[srcIP] = state
            }
            if observed && !pending.windowTitle.isEmpty {
                let title = pending.windowTitle
                settingsStore.updateSettings { $0.learnedWindowTitles[title] = srcIP }
            }
            syncTapRemoteHintSnapshot()
            onStateUpdated?()
        }
    }

    private func handleIncomingPairHello(msg: WireMessage, srcIP: String, srcPort: UInt16) {
        guard identityPersistent,
              let pubKey = msg.publicKeyBase64,
              CryptoIdentity.deviceID(forPublicKeyBase64: pubKey) == msg.senderDeviceID,
              msg.senderDeviceID != identity.deviceID else {
            return
        }

        // Already trusted with the exact same public key -> reply with authenticated pairAck WITHOUT mutating stored IP!
        if let existing = settingsStore.trustedPeer(deviceID: msg.senderDeviceID),
           existing.publicKeyBase64 == pubKey,
           let key = identity.derivePeerHMACKey(peerPublicKeyBase64: pubKey) {
            let ack = WireMessage(
                cmd: .pairAck,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                replyToSeq: msg.seq,
                ok: true
            )
            udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: key)
            return
        }

        // Step 1 of Mutual Pre-Approval Handshake:
        // If this is the initiator's initial pairHello (pairReply != true), IMMEDIATELY echo back our public key
        // BEFORE showing the alert, so BOTH Mac A and Mac B display the exact same 6-digit SAS simultaneously!
        if msg.pairReply != true {
            initiatePairing(withPeerIP: srcIP, isReply: true)
        }

        guard let sas = identity.confirmationCode(peerPublicKeyBase64: pubKey) else { return }
        guard activePairingPromptDeviceIDs.insert(msg.senderDeviceID).inserted else { return }

        let peerName = msg.senderName ?? srcIP
        let alert = NSAlert()
        alert.messageText = "TailIME 기기 페어링 확인"
        alert.informativeText = """
        '\(peerName)' (\(srcIP))와(과) 암호화 페어링을 진행합니다.

        확인 코드 (SAS):  \(sas)

        두 Mac 화면에 표시된 6자리 코드가 서로 일치하는지 확인한 뒤 양쪽에서 승인하세요.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "승인 및 신뢰")
        alert.addButton(withTitle: "거절")
        NSApp.activate(ignoringOtherApps: true)
        let approved = alert.runModal() == .alertFirstButtonReturn
        activePairingPromptDeviceIDs.remove(msg.senderDeviceID)

        guard approved else { return }

        let record = TrustedPeerRecord(
            deviceID: msg.senderDeviceID,
            name: peerName,
            publicKeyBase64: pubKey,
            lastKnownIP: srcIP
        )
        settingsStore.saveTrustedPeer(record)
        syncKeysToEndpoint()

        if let key = identity.derivePeerHMACKey(peerPublicKeyBase64: pubKey) {
            let ack = WireMessage(
                cmd: .pairAck,
                senderDeviceID: identity.deviceID,
                senderName: hostDisplayName,
                bootSessionID: bootSessionID,
                seq: nextSeq(),
                replyToSeq: msg.seq,
                ok: true
            )
            udpEndpoint.send(message: ack, toIP: srcIP, port: srcPort, key: key)
        }
        onPairingCompleted?(record)
        onStateUpdated?()
    }

    // MARK: - Helpers

    private func markPairedControllerActive() {
        // Short 30s authenticated window refreshed only by HMAC-authenticated UDP keepalive/commands.
        activePairedControllerUntil = ProcessInfo.processInfo.systemUptime + 30.0
        tapController.updateSnapshot { $0.hasActivePairedController = true }
        controllerExpiryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime >= self.activePairedControllerUntil {
                self.tapController.updateSnapshot { $0.hasActivePairedController = false }
            }
        }
        controllerExpiryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 31.0, execute: work)
    }

    private func trustedRecord(forPeer peer: TailscalePeer) -> TrustedPeerRecord? {
        if let ip = peer.ipv4, let rec = settingsStore.trustedPeer(matchingIP: ip) { return rec }
        if let ip = peer.ipv6, let rec = settingsStore.trustedPeer(matchingIP: ip) { return rec }
        return settingsStore.trustedPeers.first {
            $0.name.caseInsensitiveCompare(peer.hostName) == .orderedSame
                || $0.name.caseInsensitiveCompare(peer.shortDNSName) == .orderedSame
        }
    }

    private func trustedRecord(forIP ip: String) -> TrustedPeerRecord? {
        if let rec = settingsStore.trustedPeer(matchingIP: ip) { return rec }
        if let peer = tailscaleSnapshot.peer(matchingIP: ip) {
            return trustedRecord(forPeer: peer)
        }
        return nil
    }

    private func resolveLiveIP(for trusted: TrustedPeerRecord) -> String? {
        if let match = tailscaleSnapshot.peers.first(where: {
            $0.hostName.caseInsensitiveCompare(trusted.name) == .orderedSame
                || $0.shortDNSName.caseInsensitiveCompare(trusted.name) == .orderedSame
        }), let ip = match.preferredIP {
            return ip
        }
        return trusted.lastKnownIP
    }
}
