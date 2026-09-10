/// Out-of-band discovery of a Dart VM service over mDNS (Bonjour).
///
/// Every Flutter app built in debug or profile mode advertises its VM service
/// as `_dartVmService._tcp` on the local network, carrying the port in the SRV
/// record and the service auth code in the TXT record. On a physical iOS
/// device that advertisement is the *only* channel that reliably reports the
/// VM service: the announcement the engine prints to stdout does not reach a
/// pipe through `devicectl --console`, and `idevicesyslog` is gone on modern
/// Xcode. It is also the only channel that works at all for a wirelessly
/// attached device, where there is no USB transport to scrape.
///
/// This is deliberately *not* a second discovery mechanism racing the log
/// scrapers used by every other platform ([discoverVmServiceUri]). It is the
/// single mechanism for physical iOS devices, and no other platform uses it.
/// A device's records are told apart from the host's — a Mac running the same
/// app in a simulator advertises on the same network — by matching the SRV
/// target against the hostnames `devicectl` reports for that device.
///
/// On macOS the mDNS socket requires the Local Network privacy permission.
/// Denied, it fails as a `SocketException` rather than an empty result, which
/// is why [MdnsVmServiceDiscovery.discover] translates that into a specific,
/// actionable error instead of a generic timeout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

/// The mDNS service type every debug/profile Flutter app advertises under.
const dartVmServiceMdnsName = '_dartVmService._tcp.local';

/// Creates the mDNS client used for one query.
///
/// A factory rather than an instance because [MDnsClient] caches records for
/// the lifetime of the client: reusing one across launches would let a
/// previous run's stale port answer the next run's query. One client per
/// query, discarded after.
typedef MDnsClientFactory = MDnsClient Function();

/// Lists the host's network interfaces. Injected so the "is the USB network
/// interface even up?" diagnostic is testable.
typedef NetworkInterfaceLister =
    Future<List<NetworkInterface>> Function({
      bool includeLinkLocal,
      InternetAddressType type,
    });

Future<List<NetworkInterface>> _listNetworkInterfaces({
  bool includeLinkLocal = false,
  InternetAddressType type = InternetAddressType.any,
}) => NetworkInterface.list(includeLinkLocal: includeLinkLocal, type: type);

/// Why an mDNS lookup did not produce a VM service.
enum MdnsDiscoveryFailure {
  /// The mDNS socket could not be opened or joined. On macOS this is almost
  /// always the Local Network privacy permission.
  localNetworkPermission,

  /// No advertisement for the requested app appeared on the requested host
  /// before the timeout.
  notFound,

  /// A record was found but its SRV target could not be resolved to an
  /// address, which is required for a wirelessly attached device.
  addressUnresolved,

  /// Records that should describe one app disagreed with each other.
  ambiguous,
}

/// An mDNS lookup that did not produce a usable VM service.
class MdnsDiscoveryException implements Exception {
  final MdnsDiscoveryFailure failure;
  final String message;

  MdnsDiscoveryException(this.failure, this.message);

  @override
  String toString() => message;
}

/// One resolved `_dartVmService._tcp` advertisement.
class MdnsVmServiceRecord {
  /// Fully-qualified name of the advertised instance, e.g.
  /// `com.example.app._dartVmService._tcp.local`.
  final String serviceName;

  /// The SRV record's target — the advertising host's mDNS name, e.g.
  /// `Example-iPhone.local`.
  final String host;

  /// The port the VM service listens on **on the advertising host**. For a
  /// USB-attached device this is a device-side port that must be forwarded
  /// before it can be dialed from here.
  final int port;

  /// The service auth code as a URI path segment, always with a trailing `/`.
  ///
  /// The VM service rejects the connection without the trailing slash, so it
  /// is normalised here rather than at each call site.
  final String authCodePath;

  /// The advertising host's address, resolved only when asked for — needed to
  /// dial a wirelessly attached device, meaningless for a forwarded port.
  final InternetAddress? address;

  MdnsVmServiceRecord({
    required this.serviceName,
    required this.host,
    required this.port,
    required this.authCodePath,
    this.address,
  });

  /// The VM service URI, dialing [host] on [port].
  ///
  /// Both are parameters because the advertised pair is not always the pair to
  /// dial: a USB-attached device advertises a device-side port reached through
  /// a local forward, so the caller substitutes loopback and the forwarded
  /// port.
  Uri uriFor({required String host, required int port}) =>
      Uri(scheme: 'http', host: host, port: port, path: authCodePath);

  @override
  String toString() => '$serviceName at $host:$port';
}

/// How long the first query listens before being retransmitted. RFC 6762 §5.1
/// puts the floor for the first retransmission at one second.
const _initialQueryWindow = Duration(seconds: 1);

/// The retransmission interval stops doubling here, so a long timeout keeps
/// asking rather than sitting silent for most of it.
const _maxQueryWindow = Duration(seconds: 4);

/// Finds a Dart VM service by its mDNS advertisement.
class MdnsVmServiceDiscovery {
  final MDnsClientFactory _clientFactory;
  final NetworkInterfaceLister _listInterfaces;

  MdnsVmServiceDiscovery({
    MDnsClientFactory? clientFactory,
    NetworkInterfaceLister? listNetworkInterfaces,
  }) : _clientFactory = clientFactory ?? MDnsClient.new,
       _listInterfaces = listNetworkInterfaces ?? _listNetworkInterfaces;

  /// Waits for [bundleId] to advertise a VM service from one of [hostnames].
  ///
  /// [hostnames] identifies the advertising machine — see
  /// [mdnsTargetMatchesHostname]. Passing the target device's hostnames is
  /// what keeps a simulator on this Mac running the same bundle id from being
  /// mistaken for the device.
  ///
  /// Set [resolveAddress] when the caller must dial the advertising host
  /// directly (a wireless device) rather than through a port forward.
  ///
  /// Throws [MdnsDiscoveryException] rather than returning null: every failure
  /// here has a different remedy, and a null would erase which one it was.
  ///
  /// [onSlow] is called once if nothing has answered after [slowAfter]. A
  /// launch that legitimately takes minutes is indistinguishable from a hang
  /// unless something says so — see [IOSDevice.launch] for why iOS hardware
  /// takes that long.
  Future<MdnsVmServiceRecord> discover({
    required String bundleId,
    required Iterable<String> hostnames,
    bool resolveAddress = false,
    Duration timeout = const Duration(seconds: 30),
    Duration slowAfter = const Duration(seconds: 60),
    void Function(Duration elapsed)? onSlow,
  }) async {
    // One-shot mDNS queries are UDP and are expected to be lost: RFC 6762 §5.1
    // requires a querier to retransmit, "the interval between the first two
    // queries being at least one second, and doubling". `package:multicast_dns`
    // sends exactly one packet per lookup and stops, so retransmission has to
    // happen here. This is not a fallback between mechanisms; it is the one
    // mechanism, implemented to spec.
    final elapsed = Stopwatch()..start();
    // Every advertisement this query saw and did not take, and which host sent
    // it — the two things needed to tell "the app never started" apart from
    // "that was the copy running in a simulator on this Mac".
    final seen = <String, String>{};
    var window = _initialQueryWindow;

    var warned = false;
    while (elapsed.elapsed < timeout) {
      if (!warned && elapsed.elapsed >= slowAfter) {
        warned = true;
        onSlow?.call(elapsed.elapsed);
      }
      final attemptStart = elapsed.elapsed;
      final remaining = timeout - attemptStart;
      final attemptWindow = window < remaining ? window : remaining;
      final record = await _guarded(
        () => _queryOnce(
          bundleId: bundleId,
          hostnames: hostnames,
          resolveAddress: resolveAddress,
          window: attemptWindow,
          seen: seen,
        ),
      );
      if (record != null) return record;

      // The window is the retransmission interval, not just how long to
      // listen. A lookup that comes back early — nothing on the link answered,
      // or the client short-circuited — must not become a tight loop of
      // queries, which would flood the link and defeat the backoff.
      final spent = elapsed.elapsed - attemptStart;
      if (spent < attemptWindow)
        await Future<void>.delayed(attemptWindow - spent);

      window *= 2;
      if (window > _maxQueryWindow) window = _maxQueryWindow;
    }

    throw MdnsDiscoveryException(
      MdnsDiscoveryFailure.notFound,
      await _notFoundMessage(
        bundleId,
        hostnames,
        seen,
        timeout,
        overPointToPointLink: !resolveAddress,
      ),
    );
  }

  /// Runs [body] where a socket error can be observed.
  ///
  /// `package:multicast_dns` lets socket errors escape to the ambient zone
  /// instead of the returned future, so an error zone is the only place a
  /// denied Local Network permission can be caught.
  Future<T> _guarded<T>(Future<T> Function() body) async {
    final completer = Completer<T>();
    unawaited(
      runZonedGuarded(
        () async {
          final result = await body();
          if (!completer.isCompleted) completer.complete(result);
        },
        (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      ),
    );

    try {
      return await completer.future;
    } on SocketException catch (e) {
      throw MdnsDiscoveryException(
        MdnsDiscoveryFailure.localNetworkPermission,
        'Could not open an mDNS socket to look for the Dart VM service.\n'
        'On macOS this means the terminal or IDE running flutter_bazel has '
        'not been granted Local Network access. Grant it in System Settings > '
        'Privacy & Security > Local Network, then run again.\n'
        '$e',
      );
    }
  }

  /// Sends one query and listens for [window]. Null means nothing matched yet.
  ///
  /// A fresh client per attempt, because [MDnsClient] answers a lookup from
  /// its own cache when it can: reusing one would replay the first attempt's
  /// records instead of asking again, and a cache that never saw the device
  /// would never see it.
  Future<MdnsVmServiceRecord?> _queryOnce({
    required String bundleId,
    required Iterable<String> hostnames,
    required bool resolveAddress,
    required Duration window,
    required Map<String, String> seen,
  }) async {
    final client = _clientFactory();
    await client.start();
    try {
      final ptrStream = client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(dartVmServiceMdnsName),
        timeout: window,
      );

      final handled = <String>{};
      await for (final ptr in ptrStream) {
        if (!handled.add(ptr.domainName)) continue;
        seen.putIfAbsent(ptr.domainName, () => 'unknown host');
        if (!mdnsInstanceMatchesBundleId(ptr.domainName, bundleId)) continue;

        // The SRV and TXT records for this instance are already in the
        // client's cache: a responder answers a PTR query with them as
        // additional records, and the client caches a response before it
        // delivers the PTR record that came in the same packet. That ordering
        // is what makes these reads instant — and it is also the only way to
        // get them, because an instance label containing dots (which every
        // iOS bundle id does) cannot be re-encoded into a wire query by
        // `package:multicast_dns`: it splits the name on `.` and would ask
        // for a differently-labelled name that no responder matches. Hence
        // the short timeout — a miss here cannot be recovered by waiting.
        final srvRecords = await _cachedLookup<SrvResourceRecord>(
          client,
          ResourceRecordQuery.service(ptr.domainName),
        );
        if (srvRecords.isEmpty) continue;

        // The same advertisement arrives once per interface the device is
        // reachable on — four copies over USB is normal. Identical duplicates
        // are expected; a disagreement means these are not the same service.
        final ports = srvRecords.map((r) => r.port).toSet();
        if (ports.length > 1) {
          throw MdnsDiscoveryException(
            MdnsDiscoveryFailure.ambiguous,
            'Found ${ports.length} different Dart VM service ports advertised '
            'for ${ptr.domainName} ($ports). Stop any other instance of '
            '$bundleId and run again.',
          );
        }
        final srv = srvRecords.first;
        seen[ptr.domainName] = srv.target;
        if (!mdnsTargetMatchesHostname(srv.target, hostnames)) continue;

        final txtRecords = await _cachedLookup<TxtResourceRecord>(
          client,
          ResourceRecordQuery.text(ptr.domainName),
        );
        final authCodePath = parseMdnsAuthCodePath(
          txtRecords.map((r) => r.text).join('\n'),
        );

        InternetAddress? address;
        if (resolveAddress) {
          address = await _resolveAddress(client, srv.target);
        }

        return MdnsVmServiceRecord(
          serviceName: ptr.domainName,
          host: srv.target,
          port: srv.port,
          authCodePath: authCodePath,
          address: address,
        );
      }

      return null;
    } finally {
      client.stop();
    }
  }

  /// Reads records the PTR response already delivered.
  ///
  /// Deliberately short: [MDnsClient.lookup] answers instantly from its cache
  /// when the record is there, and waits out the timeout for nothing when it
  /// is not.
  static Future<List<T>> _cachedLookup<T extends ResourceRecord>(
    MDnsClient client,
    ResourceRecordQuery query,
  ) => client
      .lookup<T>(query, timeout: const Duration(milliseconds: 500))
      .toList();

  Future<InternetAddress> _resolveAddress(
    MDnsClient client,
    String target,
  ) async {
    // Unlike the SRV/TXT reads above, a host name has ordinary DNS labels, so
    // this one can go out on the wire if the PTR response did not carry an
    // address record for the advertising host.
    final records = await client
        .lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(target),
          timeout: const Duration(seconds: 5),
        )
        .toList();
    final address = selectMdnsAddress(records.map((r) => r.address).toList());
    if (address == null) {
      throw MdnsDiscoveryException(
        MdnsDiscoveryFailure.addressUnresolved,
        'The Dart VM service advertised on $target but that host did not '
        'resolve to an IPv4 address. A wirelessly attached device must be '
        'reachable from this machine — check that both are on the same '
        'network.',
      );
    }
    return address;
  }

  Future<String> _notFoundMessage(
    String bundleId,
    Iterable<String> hostnames,
    Map<String, String> seen,
    Duration timeout, {
    required bool overPointToPointLink,
  }) async {
    final buffer = StringBuffer()
      ..writeln(
        'No Dart VM service advertised for $bundleId on '
        '${hostnames.join(', ')} within ${timeout.inSeconds}s.',
      );
    if (seen.isEmpty) {
      buffer.writeln(
        'No app advertised a Dart VM service at all. The app must '
        'be built in debug or profile mode.',
      );
    } else {
      buffer.writeln('Saw these advertisements, none of them a match:');
      seen.forEach((instance, host) {
        buffer.writeln('  $instance  on $host');
      });
    }
    // Only meaningful for an advertiser reached over a point-to-point link —
    // the same bit as "we were not asked to resolve a routable address". A
    // device on the network answers over that network and has no business
    // needing a link-local interface here.
    if (!overPointToPointLink) return buffer.toString();
    final interfaces = await _listInterfaces(
      includeLinkLocal: true,
      type: InternetAddressType.IPv4,
    );
    final hasLinkLocal = interfaces.any(
      (i) => i.addresses.any((a) => a.isLinkLocal),
    );
    if (!hasLinkLocal) {
      buffer.writeln(
        'This machine has no IPv4 link-local interface, so a '
        'USB-attached device cannot answer an mDNS query. Turn off Personal '
        'Hotspot on the device, and uncheck "Disable unless needed" for '
        'iPhone USB under System Settings > Network.',
      );
    }
    return buffer.toString();
  }
}

/// Whether the advertised instance [domainName] belongs to [bundleId].
///
/// The instance name is the bundle id verbatim, except that mDNS renames a
/// service whose name is already taken by appending ` (2)`, ` (3)`, … — which
/// happens when a previous instance of the same app has not finished
/// withdrawing its advertisement. Matching those too is why this is not a
/// plain equality check; matching on a bare prefix instead would also accept
/// an unrelated `com.example.app.share-extension`.
bool mdnsInstanceMatchesBundleId(String domainName, String bundleId) {
  const suffix = '.$dartVmServiceMdnsName';
  if (!domainName.endsWith(suffix)) return false;
  final instance = domainName.substring(0, domainName.length - suffix.length);
  if (instance == bundleId) return true;
  return RegExp(
    r'^' + RegExp.escape(bundleId) + r' \(\d+\)$',
  ).hasMatch(instance);
}

/// Whether an SRV record's [target] names one of [hostnames].
///
/// Compared on the first DNS label only, because the two names for one device
/// come from different sources and differ below that label: `devicectl`
/// reports `Example-iPhone.coredevice.local` while the device advertises
/// itself as `Example-iPhone.local.`. The first label is generated by the same
/// sanitiser on both sides, so comparing it is exact — unlike re-deriving it
/// from the user-facing device name, which carries spaces and punctuation that
/// the sanitiser rewrites.
bool mdnsTargetMatchesHostname(String target, Iterable<String> hostnames) {
  final targetLabel = mdnsFirstLabel(target);
  if (targetLabel.isEmpty) return false;
  return hostnames.any((h) => mdnsFirstLabel(h) == targetLabel);
}

/// The first DNS label of [name], lowercased, with trailing dots ignored.
String mdnsFirstLabel(String name) {
  final trimmed = name.trim();
  final dot = trimmed.indexOf('.');
  return (dot < 0 ? trimmed : trimmed.substring(0, dot)).toLowerCase();
}

/// The `authCode=` value from a TXT record, as a URI path segment.
///
/// Always ends in `/`: the VM service answers `invalid authentication code`
/// for a path missing it. An empty result means the app runs with
/// `--disable-service-auth-codes`, which is a legitimate configuration.
String parseMdnsAuthCodePath(String txt) {
  const prefix = 'authCode=';
  for (final line in const LineSplitter().convert(txt)) {
    if (!line.startsWith(prefix)) continue;
    final code = line.substring(prefix.length);
    return code.endsWith('/') ? code : '$code/';
  }
  return '';
}

/// The address to dial from [addresses], or null if there is none.
///
/// Prefers a routable address: a device on Wi-Fi also answers on its
/// link-local USB address, which is not reachable once the cable is out.
InternetAddress? selectMdnsAddress(List<InternetAddress> addresses) {
  if (addresses.isEmpty) return null;
  final routable = addresses.where((a) => !a.isLinkLocal).toList();
  return routable.isNotEmpty ? routable.first : addresses.first;
}
