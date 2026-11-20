// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if !APP_STORE

// The built-in JIT.
//
// Andarium can prepare the JIT's executable memory itself, through the
// device's own debugserver reached over a paired loopback tunnel (the idevice
// library), instead of relying on the separate StikDebug app. The person
// couples the device once in Settings by importing a pairing file; from then
// on turning the JIT on uses the built-in path.
//
// This is experimental and off until the person turns it on. iOS suspends
// every thread of a process a debugger attaches to, so a process that attaches
// debugserver to itself can wedge. For that reason the built-in path is never
// taken at launch and never on the main thread: it runs only from an explicit
// start the person asked for, on the JIT preparation worker, and the runtime
// falls back to gadgets if it does not complete. An App Store build has none
// of this.
//
// The pairing file and the coupling policy live here; the device side (the
// tunnel, the debug proxy and the page blessing) is `BuiltInJitSession`,
// compiled for the device alone.

/// Where the built-in JIT stands, for Settings and Home.
enum BuiltInJitCoupling: Equatable, Sendable {
    /// The built-in JIT is off; the person uses StikDebug, or nothing.
    case off
    /// On, but no pairing file is stored: the device is not coupled yet.
    case needsPairing
    /// On and a pairing file is stored: the next start can prepare the JIT
    /// itself.
    case coupled
}

/// The built-in JIT's policy and stored state. A single instance owns the
/// pairing file and the toggle; the device session reads them when it blesses
/// a region.
@MainActor
final class BuiltInJit {
    static let shared = BuiltInJit()

    /// The stored toggle and the pairing file's name in the defaults database
    /// and Application Support.
    private enum Keys {
        static let enabled = "andarium.jit.builtin.enabled"
        static let pairingName = "andarium.jit.builtin.pairing"
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Whether the person turned the built-in JIT on. It applies to the next
    /// start.
    var isEnabled: Bool {
        defaults.bool(forKey: Keys.enabled)
    }

    /// Turns the built-in JIT on or off. Turning it off removes nothing; the
    /// pairing file stays for the next time.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Keys.enabled)
        reinstall()
    }

    /// Whether a pairing file is stored.
    var hasPairing: Bool {
        pairingURL != nil
    }

    /// Where the built-in JIT stands.
    var coupling: BuiltInJitCoupling {
        guard isEnabled else { return .off }
        return hasPairing ? .coupled : .needsPairing
    }

    /// The stored pairing file, or nil when none is stored.
    var pairingURL: URL? {
        guard let name = defaults.string(forKey: Keys.pairingName) else { return nil }
        let url = Self.pairingDirectory(fileManager).appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Stores a pairing file the person picked, replacing any earlier one.
    /// `picked` is a file the person chose; it is copied, so the caller keeps
    /// ownership of the original. Throws when the copy fails.
    func importPairing(from picked: URL) throws {
        let directory = Self.pairingDirectory(fileManager)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("pairing.plist")
        let access = picked.startAccessingSecurityScopedResource()
        defer { if access { picked.stopAccessingSecurityScopedResource() } }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: picked, to: destination)
        defaults.set(destination.lastPathComponent, forKey: Keys.pairingName)
        reinstall()
    }

    /// Removes the stored pairing file and forgets it.
    func removePairing() {
        if let url = pairingURL {
            try? fileManager.removeItem(at: url)
        }
        defaults.removeObject(forKey: Keys.pairingName)
        reinstall()
    }

    /// The folder the pairing file is kept in: Application Support, out of
    /// backups and the file browser.
    private static func pairingDirectory(_ fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("BuiltInJit", isDirectory: true)
    }

    // MARK: Registration

    /// Installs or removes the built-in blesser on the loader, following the
    /// toggle and whether a pairing file is stored. Call it once as the
    /// application opens and after any change.
    func install() {
        reinstall()
    }

    private func reinstall() {
        #if !targetEnvironment(simulator)
        if isEnabled, let pairing = pairingURL {
            BuiltInJitSession.install(pairingPath: pairing.path)
        } else {
            BuiltInJitSession.remove()
        }
        #endif
    }
}

#endif
