import Foundation
import TailIMECore

/// Manages persistence for `AppSettings` and per-peer `TrustedPeerRecord`s, plus watches
/// `~/.config/karabiner` directory (not just the file, since Karabiner replaces karabiner.json atomically).
final class SettingsStore {
    private static let settingsKey = "TailIME.AppSettings.v1"
    private static let trustedPeersKey = "TailIME.TrustedPeers.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    private var _settings: AppSettings
    private var _trustedPeers: [String: TrustedPeerRecord] // deviceID -> record

    private var karabinerDirFD: Int32 = -1
    private var karabinerWatcher: DispatchSourceFileSystemObject?

    var onSettingsChanged: ((AppSettings) -> Void)?
    var onTrustedPeersChanged: (([TrustedPeerRecord]) -> Void)?
    var onKarabinerConfigChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self._settings = decoded
        } else {
            self._settings = AppSettings()
        }

        if let data = defaults.data(forKey: Self.trustedPeersKey),
           let list = try? JSONDecoder().decode([TrustedPeerRecord].self, from: data) {
            self._trustedPeers = Dictionary(uniqueKeysWithValues: list.map { ($0.deviceID, $0) })
        } else {
            self._trustedPeers = [:]
        }
    }

    deinit {
        stopWatchingKarabinerDirectory()
    }

    var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        return _settings
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        let updated: AppSettings
        lock.lock()
        mutate(&_settings)
        updated = _settings
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.settingsKey)
        }
        lock.unlock()
        onSettingsChanged?(updated)
    }

    var trustedPeers: [TrustedPeerRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_trustedPeers.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func trustedPeer(deviceID: String) -> TrustedPeerRecord? {
        lock.lock()
        defer { lock.unlock() }
        return _trustedPeers[deviceID]
    }

    func trustedPeer(matchingIP ip: String) -> TrustedPeerRecord? {
        let lower = ip.lowercased()
        lock.lock()
        defer { lock.unlock() }
        return _trustedPeers.values.first { $0.lastKnownIP?.lowercased() == lower }
    }

    func saveTrustedPeer(_ record: TrustedPeerRecord) {
        let list: [TrustedPeerRecord]
        lock.lock()
        _trustedPeers[record.deviceID] = record
        list = Array(_trustedPeers.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.trustedPeersKey)
        }
        lock.unlock()
        onTrustedPeersChanged?(list)
    }

    func removeTrustedPeer(deviceID: String) {
        let list: [TrustedPeerRecord]
        lock.lock()
        _trustedPeers.removeValue(forKey: deviceID)
        list = Array(_trustedPeers.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.trustedPeersKey)
        }
        lock.unlock()
        onTrustedPeersChanged?(list)
    }

    func updateTrustedPeerIP(deviceID: String, ip: String, os: String? = nil) {
        lock.lock()
        guard var existing = _trustedPeers[deviceID] else {
            lock.unlock()
            return
        }
        var changed = false
        if !ip.isEmpty && existing.lastKnownIP != ip {
            existing.lastKnownIP = ip
            changed = true
        }
        if let os, !os.isEmpty, os.lowercased() != "unknown", existing.os != os {
            existing.os = os
            changed = true
        }
        guard changed else {
            lock.unlock()
            return
        }
        _trustedPeers[deviceID] = existing
        let list = Array(_trustedPeers.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.trustedPeersKey)
        }
        lock.unlock()
        onTrustedPeersChanged?(list)
    }

    /// Watches `~/.config/karabiner` directory for atomic rewrites of `karabiner.json`.
    func startWatchingKarabinerDirectory() {
        stopWatchingKarabinerDirectory()
        let dirPath = KarabinerConfigParser.defaultConfigDirectory
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        karabinerDirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            // Debounce slightly for atomic replace completion
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                self?.onKarabinerConfigChanged?()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.karabinerDirFD, fd >= 0 {
                close(fd)
                self?.karabinerDirFD = -1
            }
        }
        source.resume()
        karabinerWatcher = source
    }

    func stopWatchingKarabinerDirectory() {
        karabinerWatcher?.cancel()
        karabinerWatcher = nil
    }
}
