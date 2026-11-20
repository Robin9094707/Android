// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import Foundation

#if !APP_STORE

/// The debugger side of the JIT: whether one is attached to Andarium and
/// serves the runtime's request for executable memory, and the preparation
/// the runtime makes with it. An App Store build compiles this file out and
/// has no JIT.
///
/// There are two debuggers. The external one is StikDebug, whose script serves
/// the runtime's breakpoint request. The built-in one is Andarium itself: when
/// the person couples the device in Settings, the runtime prepares the memory
/// through the device's own debugserver (`BuiltInJitSession`) with no separate
/// app. Either counts as a debugger here.
enum JitDebugger {
    /// Whether an attached debugger is one that serves the request. Release
    /// builds run from StikDebug, whose script serves it. Under Xcode a Debug
    /// build is attached to lldb, which would stop at the request instead of
    /// serving it, so Debug asks the launch to say a servicing debugger is
    /// attached (the test harness's stand-in does).
    static var serves: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["ANDARIUM_JIT_DEBUGGER"] == "1"
        #else
        true
        #endif
    }

    /// Whether the built-in JIT is coupled: the toggle is on and a pairing
    /// file is stored, so the runtime can prepare the memory itself.
    static var builtInCoupled: Bool {
        #if !targetEnvironment(simulator)
        return BuiltInJitSession.isInstalled
        #else
        return false
        #endif
    }

    /// An external servicing debugger (StikDebug) is attached now.
    static func externalAttached() -> Bool {
        serves && kernarium_runtime_loader_debugger_attached() != 0
    }

    /// A debugger that can prepare the JIT is available now: StikDebug
    /// attached, or the built-in JIT coupled.
    static func attached() -> Bool {
        externalAttached() || builtInCoupled
    }

    /// Prepares the executable memory for `shape` when `wanted`, or tells an
    /// attached debugger to leave when not, and says how it came out. The
    /// debugger takes seconds, so this runs off the main thread. With neither
    /// an external servicing debugger nor the built-in JIT, nothing is asked
    /// of the runtime: a breakpoint request would stop in a debugger that does
    /// not serve it.
    static func prepare(wanted: Bool, shape: JitShape, flavor: UInt32) async -> JitAnswer {
        let external = externalAttached()
        let builtIn = builtInCoupled
        // Not wanted and nobody to tell to leave: nothing to do.
        guard wanted || external || builtIn else { return .disabled }
        // Wanted, but nothing can serve it: no external servicing debugger
        // (Debug under Xcode is attached to lldb, which would stop at the
        // request) and no built-in coupling.
        if wanted, !builtIn, !serves { return .noDebugger }
        return await Task.detached(priority: .userInitiated) { () -> JitAnswer in
            guard kernarium_runtime_loader_select(flavor) == 0 else { return .unsupported }
            return JitAnswer(runtimeValue: kernarium_runtime_loader_prepare_jit(
                wanted ? 1 : 0, UInt32(shape.memoryMiB), UInt32(shape.processorCount)))
        }.value
    }
}

#endif
