// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if !APP_STORE && !targetEnvironment(simulator)

// The device side of the built-in JIT: the loopback tunnel to the device's
// debugserver, and the blessing of one JIT region through it, using the
// vendored idevice library (AGPL-3.0; Andarium/ThirdParty/idevice). It is
// compiled for the iOS device alone.
//
// The runtime installs `builtin_jit_bless` as its host blesser. When a start
// prepares the JIT with no StikDebug attached, the runtime maps the region
// read-execute and calls the blesser with its address and length. The blesser
// opens a tunnel from the stored pairing file to the device's own
// RemoteServiceDiscovery, attaches debugserver to this process, writes one
// byte into each 16 KiB page (which is what makes those pages run code on an
// iOS device), detaches, and returns zero once the process runs unattached
// again. Any failure returns nonzero and the runtime falls back to gadgets.
//
// iOS suspends every thread of a process its debugger stops, so attaching
// debugserver to this very process can wedge it. The runtime only calls the
// blesser from a start the person asked for, on the preparation worker, never
// at launch and never on the main thread, so a wedge is a deliberate,
// experimental act and never the normal path.

/// Installs and removes the built-in blesser on the loader, and holds what it
/// needs. Only `BuiltInJit` (main actor) calls install/remove; the blesser
/// runs on the runtime's worker.
enum BuiltInJitSession {
    /// The host page the device blesses, and the byte written into each.
    private static let pageBytes: UInt64 = 16_384
    private static let blessingByte: UInt8 = 0x69
    /// The device's own tunnel address and the remotepairing fallback port
    /// StikDebug uses when Bonjour discovery is unavailable. An override lets
    /// a person set the port Settings read.
    private static let selfAddress = "10.7.0.1"
    private static let fallbackRemotePairingPort: UInt16 = 49152

    /// The stored pairing file path, read by the blesser. A lock guards it
    /// against the main actor changing it while the worker reads it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pairingPath: String?

    static func install(pairingPath path: String) {
        lock.lock()
        pairingPath = path
        lock.unlock()
        kernarium_runtime_loader_set_jit_host_blesser(builtInJitBlesser, nil)
    }

    static func remove() {
        lock.lock()
        pairingPath = nil
        lock.unlock()
        kernarium_runtime_loader_set_jit_host_blesser(nil, nil)
    }

    /// Whether the built-in blesser is installed (the toggle is on and a
    /// pairing file is stored). Safe to read from any thread.
    static var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairingPath != nil
    }

    private static func currentPairingPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pairingPath
    }

    /// The remotepairing port Settings may have stored; the fallback otherwise.
    private static var remotePairingPort: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "andarium.jit.builtin.port")
        if stored > 0, stored <= Int(UInt16.max) { return UInt16(stored) }
        return fallbackRemotePairingPort
    }

    // MARK: Blessing

    /// Prepares the region through the device's debugserver. Returns true when
    /// the pages were blessed and the process runs unattached again.
    static func bless(address: UInt64, length: UInt64) -> Bool {
        guard let path = currentPairingPath() else {
            log("no pairing file is stored")
            return false
        }
        idevice_init_logger(Disabled, Disabled, nil)

        var pairing: OpaquePointer?
        if let error = path.withCString({ rp_pairing_file_read($0, &pairing) }) {
            report(error, "could not read the pairing file")
            return false
        }
        guard let pairing else {
            log("the pairing file was empty")
            return false
        }
        defer { rp_pairing_file_free(pairing) }

        var tunnel = Tunnel()
        guard openTunnel(pairing: pairing, into: &tunnel) else { return false }
        defer { tunnel.free() }

        guard let adapter = tunnel.adapter, let handshake = tunnel.handshake else {
            log("the tunnel produced no adapter")
            return false
        }

        var debugProxy: OpaquePointer?
        if let error = debug_proxy_connect_rsd(adapter, handshake, &debugProxy) {
            report(error, "could not open the debug proxy")
            return false
        }
        guard let debugProxy else {
            log("the debug proxy was not created")
            return false
        }
        defer { debug_proxy_free(debugProxy) }

        return runDebugger(debugProxy, address: address, length: length)
    }

    /// Opens the loopback tunnel from the pairing file to this device.
    private static func openTunnel(pairing: OpaquePointer, into tunnel: inout Tunnel) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = remotePairingPort.bigEndian
        guard selfAddress.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            log("could not parse the device address")
            return false
        }
        let error = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockptr in
                "Andarium".withCString { host in
                    tunnel_create_rppairing(
                        sockptr,
                        socklen_t(MemoryLayout<sockaddr_in>.size),
                        host,
                        pairing,
                        nil,
                        nil,
                        &tunnel.adapter,
                        &tunnel.handshake)
                }
            }
        }
        if let error {
            report(error, "could not create the tunnel")
            return false
        }
        return true
    }

    /// Attaches to this process, writes the blessing byte into every page, and
    /// detaches.
    private static func runDebugger(
        _ debugProxy: OpaquePointer, address: UInt64, length: UInt64
    ) -> Bool {
        // Leave acknowledged mode once, as a debugger session does.
        debug_proxy_send_ack(debugProxy)
        _ = sendCommand(debugProxy, "QStartNoAckMode")
        debug_proxy_set_ack_mode(debugProxy, 0)

        // Attach to this very process.
        let pid = getpid()
        let attach = sendCommand(debugProxy, "vAttach;" + String(UInt32(bitPattern: pid), radix: 16))
        guard let attach, !attach.hasPrefix("E") else {
            log("vAttach was refused: \(attach ?? "<nil>")")
            return false
        }

        let ok = writePages(debugProxy, address: address, length: length)

        // Detach so the guest never runs under the debugger, whatever the
        // writes did.
        _ = sendCommand(debugProxy, "D")
        return ok
    }

    /// Writes one blessing byte into each 16 KiB page of the region.
    private static func writePages(
        _ debugProxy: OpaquePointer, address: UInt64, length: UInt64
    ) -> Bool {
        guard length > 0 else { return true }
        let pages = Int((length - 1) / pageBytes) + 1
        // One hex byte to write into each page (`M<addr>,1:<byte>`).
        let byte = String(blessingByte, radix: 16)
        let hexByte = byte.count == 1 ? "0" + byte : byte
        var page = 0
        while page < pages {
            let at = address + UInt64(page) * pageBytes
            let command = "M" + String(at, radix: 16) + ",1:" + hexByte
            guard let reply = sendCommand(debugProxy, command), reply == "OK" || reply.isEmpty else {
                log("the write at page \(page) of \(pages) failed: \(sendFailure)")
                return false
            }
            page += 1
        }
        return true
    }

    // MARK: Packets

    private static var sendFailure = ""

    private static func sendCommand(_ debugProxy: OpaquePointer, _ command: String) -> String? {
        guard let handle = debugserver_command_new(command, nil, 0) else { return nil }
        defer { debugserver_command_free(handle) }
        var response: UnsafeMutablePointer<CChar>?
        let error = debug_proxy_send_command(debugProxy, handle, &response)
        if let error {
            sendFailure = message(error)
            idevice_error_free(error)
            if let response { idevice_string_free(response) }
            return nil
        }
        defer { if let response { idevice_string_free(response) } }
        return response.map { String(cString: $0) } ?? ""
    }

    // MARK: Errors

    private struct Tunnel {
        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        mutating func free() {
            if let handshake { rsd_handshake_free(handshake) }
            if let adapter { adapter_free(adapter) }
            adapter = nil
            handshake = nil
        }
    }

    private static func message(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        if let text = error.pointee.message {
            return "[\(error.pointee.code)] \(String(cString: text))"
        }
        return "code \(error.pointee.code)"
    }

    private static func report(_ error: UnsafeMutablePointer<IdeviceFfiError>, _ what: String) {
        log("\(what): \(message(error))")
        idevice_error_free(error)
    }

    private static func log(_ text: String) {
        print("Andarium: built-in JIT: \(text)")
    }
}

/// The host blesser the loader calls (runtime API `set_jit_host_blesser`):
/// prepares the region through the device's debugserver, zero on success.
@_cdecl("builtin_jit_bless")
func builtInJitBlesser(_ context: UnsafeMutableRawPointer?, _ address: UInt64, _ length: UInt64) -> Int32 {
    BuiltInJitSession.bless(address: address, length: length) ? 0 : 1
}

#endif
