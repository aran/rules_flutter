/// The loopback addresses the host running a test can actually assign.
///
/// Shared by every test whose subject is a server that serves `localhost`,
/// because the answer differs per host and hard-coding either family reports
/// on the machine rather than on the tool.
library;

import 'dart:io';

/// The loopback addresses this host can actually assign to a socket.
///
/// Both of them on a normal machine — and `HttpMultiServer` binds both for
/// `localhost`. Not everywhere, though: a host with no IPv6 address on any
/// interface fails EADDRNOTAVAIL when it binds ::1, so a case that hard-codes
/// ::1 there reports on the machine rather than on the tool.
///
/// Decided the way `HttpMultiServer` itself decides what to bind:
/// `supportsIPv4`/`supportsIPv6` are a port-0 bind of each loopback, and
/// *any* `SocketException` means "not this host" — a kernel booted with
/// `ipv6.disable=1` refuses at `socket()` rather than at `bind()`, so an
/// errno list would part ways with the predicate that decides the bind.
/// Matching it exactly keeps this the set the server under test serves on.
Future<List<InternetAddress>> assignableLoopbacks() async {
  final assignable = <InternetAddress>[];
  for (final address in [
    InternetAddress.loopbackIPv4,
    InternetAddress.loopbackIPv6,
  ]) {
    try {
      await (await ServerSocket.bind(address, 0)).close();
      assignable.add(address);
    } on SocketException {
      // Exactly what `supportsIPv6` concludes from the same failure: this
      // host has no such address to serve on.
    }
  }
  return assignable;
}
