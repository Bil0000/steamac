# Vendored WiVRn code

* Source: https://github.com/WiVRn/WiVRn, tag **v26.9**, commit `bbc6e4cc36c355fa6180980abd231673dc15115d`.
* Licence: GPL-3.0-or-later (`host/vrhost/COPYING`); `external/magic_enum.hpp` is MIT (v0.9.5, as vendored by WiVRn).
* Files: `common/{wivrn_packets.h, wivrn_serialization.h, wivrn_serialization_types.h, packed_quaternion.h,
  protocol_version.h, crypto.*, smp.*, secrets.*, wivrn_sockets.*}` and `external/magic_enum.hpp`, **unmodified**.
* Build-time dependencies fetched by CMake at the versions WiVRn v26.9 uses: OpenXR-SDK `release-1.1.58` headers
  (the protocol hash depends on their array sizes) and Boost.PFR `boost-1.89.0`. OpenSSL 3 from the system/Homebrew.
* macOS shims live outside the vendored tree, in `host/vrhost/compat/wivrn_macos_compat.h` (force-included):
  `mmsghdr`/`recvmmsg`/`sendmmsg`, `MSG_NOSIGNAL` = 0 (the process ignores `SIGPIPE`), `IPV6_ADD/DROP_MEMBERSHIP`.
  `-Wno-c++11-narrowing` because `msghdr::msg_iovlen` is an `int` on macOS.
* Known macOS difference not shimmed: `UDP::receive_from_raw()` sizes its buffer with
  `recvfrom(MSG_PEEK | MSG_TRUNC)`, which returns the datagram length on Linux and 0 on macOS. steamac-vrhost does not
  call it (the handshake reads the first datagram with a plain `recvfrom`).
* Protocol hash of this tree: `fc26e619b7ab80f8` (`steamac-vrhost --protocol`, pinned in `tests/test_protocol.cpp`).
  WiVRn `master` at `bc3e374` (2026-10-11) has no packet/serialization change since v26.9 (comment-only diff).

## Re-vendoring

Copy the same files from the new tag, rebuild, run `ctest`. `test_protocol` fails on purpose when the hash changes:
update the constant there and in `docs/vr.md` together with the client version users must install.
