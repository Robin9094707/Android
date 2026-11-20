# idevice (vendored)

Rust FFI bindings to the on-device debugging services, used by Andarium's
built-in JIT to reach the device's own debugserver through a paired tunnel.

- Upstream: https://github.com/jkcoxson/idevice
- Licence: MIT (see upstream `LICENSE.txt`)
- Pinned commit: `idevice.pin`

`idevice.h` is generated from the pinned source and checked in (with an added
`SPDX-License-Identifier: MIT` line) so the project builds without a network
fetch. `build-idevice-xcframework.sh` rebuilds the static library and the
xcframework on a Mac and refreshes the header. Andarium links
`IDevice.xcframework` and imports `idevice.h` through its bridging header; only
the iOS device slice is built, because the built-in JIT runs on a real device
alone.
