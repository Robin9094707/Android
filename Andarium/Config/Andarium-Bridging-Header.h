// SPDX-License-Identifier: GPL-2.0-or-later
#import "../../GuestHost/Sources/KernariumRuntimeLoader.h"

// The vendored idevice library, for the built-in JIT (Live/BuiltInJitSession).
// It is linked for the iOS device alone; the header only declares, so parsing
// it in a Simulator or preview build is harmless. An App Store build does not
// take the built-in JIT, so it never calls these declarations.
#if __has_include("idevice.h")
#import "idevice.h"
#endif
