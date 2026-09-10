import 'dart:io';

import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// A stand-in for `NetworkInterface.list`, so the not-found diagnostic that
/// asks "is the USB network interface even up?" is testable off hardware.
Future<List<NetworkInterface>> noInterfaces({
  bool includeLinkLocal = false,
  InternetAddressType type = InternetAddressType.any,
}) async => const [];

void main() {
  const bundleId = 'com.example.app';
  const deviceHost = 'Test-iPhone.local';
  const deviceHostnames = [
    'Test-iPhone.coredevice.local',
    'TEST-COREDEVICE-UUID.coredevice.local',
  ];

  MdnsVmServiceDiscovery discoveryOver(FakeMDnsClientFactory factory) =>
      MdnsVmServiceDiscovery(
        clientFactory: factory.call,
        listNetworkInterfaces: noInterfaces,
      );

  group('mdnsInstanceMatchesBundleId', () {
    test('accepts the bundle id verbatim', () {
      expect(
        mdnsInstanceMatchesBundleId(
          'com.example.app.$dartVmServiceMdnsName',
          'com.example.app',
        ),
        isTrue,
      );
    });

    // mDNS renames a service whose name is already taken. A previous instance
    // that has not finished withdrawing produces exactly this.
    test('accepts a conflict-renamed instance', () {
      expect(
        mdnsInstanceMatchesBundleId(
          'com.example.app (2).$dartVmServiceMdnsName',
          'com.example.app',
        ),
        isTrue,
      );
    });

    test('rejects a different app that starts with the same bundle id', () {
      expect(
        mdnsInstanceMatchesBundleId(
          'com.example.app.share.$dartVmServiceMdnsName',
          'com.example.app',
        ),
        isFalse,
      );
    });

    test('rejects another service type', () {
      expect(
        mdnsInstanceMatchesBundleId(
          'com.example.app._http._tcp.local',
          'com.example.app',
        ),
        isFalse,
      );
    });
  });

  group('mdnsTargetMatchesHostname', () {
    // devicectl reports `<name>.coredevice.local`; the device advertises
    // `<name>.local.`. Only the first label is common to both.
    test('matches on the first label across differing parent domains', () {
      expect(
        mdnsTargetMatchesHostname('Test-iPhone.local.', deviceHostnames),
        isTrue,
      );
    });

    test('is case insensitive', () {
      expect(
        mdnsTargetMatchesHostname('TEST-IPHONE.local', deviceHostnames),
        isTrue,
      );
    });

    test('rejects this Mac advertising the same app from a simulator', () {
      expect(
        mdnsTargetMatchesHostname('Mac-Studio.local', deviceHostnames),
        isFalse,
      );
    });

    test('rejects a hostname that merely shares a suffix', () {
      expect(
        mdnsTargetMatchesHostname(
          'Other-iPhone.coredevice.local',
          deviceHostnames,
        ),
        isFalse,
      );
    });
  });

  group('parseMdnsAuthCodePath', () {
    test('appends the trailing slash the VM service requires', () {
      expect(parseMdnsAuthCodePath('authCode=OTuN9bi0zgk='), 'OTuN9bi0zgk=/');
    });

    test('keeps an existing trailing slash', () {
      expect(parseMdnsAuthCodePath('authCode=abc/'), 'abc/');
    });

    test('finds the auth code among other TXT keys', () {
      expect(parseMdnsAuthCodePath('other=1\nauthCode=xyz\nmore=2'), 'xyz/');
    });

    // `--disable-service-auth-codes` is a legitimate configuration.
    test('is empty when there is no auth code', () {
      expect(parseMdnsAuthCodePath('other=1'), '');
    });
  });

  group('selectMdnsAddress', () {
    test('prefers a routable address over a link-local one', () {
      final chosen = selectMdnsAddress([
        InternetAddress('169.254.21.246'),
        InternetAddress('192.168.1.244'),
      ]);
      expect(chosen?.address, '192.168.1.244');
    });

    test('takes a link-local address when it is all there is', () {
      final chosen = selectMdnsAddress([InternetAddress('169.254.21.246')]);
      expect(chosen?.address, '169.254.21.246');
    });

    test('is null with nothing to choose from', () {
      expect(selectMdnsAddress([]), isNull);
    });
  });

  group('MdnsVmServiceDiscovery.discover', () {
    test('resolves port and auth code from the advertisement', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: deviceHost,
          port: 50541,
          authCode: 'OTuN9bi0zgk=',
        ),
      );

      final record = await discoveryOver(factory).discover(
        bundleId: bundleId,
        hostnames: deviceHostnames,
      );

      expect(record.port, 50541);
      expect(record.authCodePath, 'OTuN9bi0zgk=/');
      expect(record.host, deviceHost);
      expect(record.address, isNull);
      expect(
        record.uriFor(host: '127.0.0.1', port: 4321).toString(),
        'http://127.0.0.1:4321/OTuN9bi0zgk=/',
      );
    });

    test('closes the client it opened', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: deviceHost,
          port: 1,
          authCode: 'a',
        ),
      );
      await discoveryOver(
        factory,
      ).discover(bundleId: bundleId, hostnames: deviceHostnames);
      expect(factory.clients.single.stopped, isTrue);
    });

    // A one-shot mDNS query is UDP and gets lost; RFC 6762 §5.1 requires the
    // querier to retransmit.
    test(
      'retransmits until an answer arrives',
      () async {
        final factory = FakeMDnsClientFactory(
          silentAttempts: 2,
          records: dartVmServiceRecords(
            instance: bundleId,
            host: deviceHost,
            port: 50541,
            authCode: 'a',
          ),
        );

        final record = await discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          timeout: const Duration(seconds: 20),
        );

        expect(record.port, 50541);
        expect(factory.clients.length, 3);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // A lookup that answers instantly — nothing on the link, or a client that
    // short-circuits — must not become a tight loop of queries.
    test(
      'paces retransmissions instead of spinning',
      () async {
        final factory = FakeMDnsClientFactory();
        final elapsed = Stopwatch()..start();

        await expectLater(
          discoveryOver(factory).discover(
            bundleId: bundleId,
            hostnames: deviceHostnames,
            timeout: const Duration(seconds: 3),
          ),
          throwsA(isA<MdnsDiscoveryException>()),
        );

        // 3s at 1s then 2s intervals is two queries, not hundreds.
        expect(factory.clients.length, lessThanOrEqualTo(4));
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(seconds: 3)),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // A launch that legitimately takes minutes is indistinguishable from a
    // hang unless something says so.
    test(
      'reports that it is still waiting once past slowAfter',
      () async {
        final factory = FakeMDnsClientFactory();
        final reported = <Duration>[];

        await expectLater(
          discoveryOver(factory).discover(
            bundleId: bundleId,
            hostnames: deviceHostnames,
            timeout: const Duration(seconds: 4),
            slowAfter: const Duration(seconds: 1),
            onSlow: reported.add,
          ),
          throwsA(isA<MdnsDiscoveryException>()),
        );

        expect(reported, hasLength(1), reason: 'once, not once per retry');
        expect(
          reported.single,
          greaterThanOrEqualTo(const Duration(seconds: 1)),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('stays quiet when the answer arrives before slowAfter', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: deviceHost,
          port: 1,
          authCode: 'a',
        ),
      );
      final reported = <Duration>[];

      await discoveryOver(factory).discover(
        bundleId: bundleId,
        hostnames: deviceHostnames,
        slowAfter: const Duration(seconds: 1),
        onSlow: reported.add,
      );

      expect(reported, isEmpty);
    });

    // The link-local hint is about a USB point-to-point link. A device on the
    // network answers over that network, so telling its user to check "iPhone
    // USB" sends them to the wrong place.
    test('omits the USB link-local hint for a networked device', () async {
      final factory = FakeMDnsClientFactory();

      await expectLater(
        discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          resolveAddress: true,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<MdnsDiscoveryException>().having(
            (e) => e.message,
            'message',
            isNot(contains('link-local')),
          ),
        ),
      );
    });

    test('resolves the device address when asked to', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: deviceHost,
          port: 50541,
          authCode: 'a',
          addresses: ['169.254.21.246', '192.168.1.244'],
        ),
      );

      final record = await discoveryOver(factory).discover(
        bundleId: bundleId,
        hostnames: deviceHostnames,
        resolveAddress: true,
      );

      expect(record.address?.address, '192.168.1.244');
      expect(
        record
            .uriFor(host: record.address!.address, port: record.port)
            .toString(),
        'http://192.168.1.244:50541/a/',
      );
    });

    test('fails loudly when the address cannot be resolved', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: deviceHost,
          port: 1,
          authCode: 'a',
        ),
      );

      expect(
        () => discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          resolveAddress: true,
        ),
        throwsA(
          isA<MdnsDiscoveryException>().having(
            (e) => e.failure,
            'failure',
            MdnsDiscoveryFailure.addressUnresolved,
          ),
        ),
      );
    });

    // This Mac running the same bundle id in a simulator advertises on the
    // same network. Taking it would connect hot reload to the wrong process.
    test('ignores the same bundle id advertised by another host', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: bundleId,
          host: 'Mac-Studio.local',
          port: 50541,
          authCode: 'a',
        ),
      );

      await expectLater(
        discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<MdnsDiscoveryException>()
              .having(
                (e) => e.failure,
                'failure',
                MdnsDiscoveryFailure.notFound,
              )
              .having((e) => e.message, 'message', contains('Mac-Studio')),
        ),
      );
    });

    test('ignores another app on the same device', () async {
      final factory = FakeMDnsClientFactory(
        records: dartVmServiceRecords(
          instance: 'com.example.other',
          host: deviceHost,
          port: 50541,
          authCode: 'a',
        ),
      );

      await expectLater(
        discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<MdnsDiscoveryException>().having(
            (e) => e.failure,
            'failure',
            MdnsDiscoveryFailure.notFound,
          ),
        ),
      );
    });

    test('says so when nothing advertised at all', () async {
      final factory = FakeMDnsClientFactory();

      await expectLater(
        discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<MdnsDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('No app advertised a Dart VM service'),
          ),
        ),
      );
    });

    // Without an IPv4 link-local interface a USB-attached device cannot answer
    // an mDNS query at all, so the message names that cause.
    test('names the missing link-local interface in the failure', () async {
      final factory = FakeMDnsClientFactory();

      await expectLater(
        discoveryOver(factory).discover(
          bundleId: bundleId,
          hostnames: deviceHostnames,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(
          isA<MdnsDiscoveryException>().having(
            (e) => e.message,
            'message',
            contains('link-local'),
          ),
        ),
      );
    });

    // package:multicast_dns lets socket errors escape to the ambient zone
    // rather than the returned future, so this catches nothing unless the
    // error zone is wired up.
    test(
      'turns a socket error into the Local Network permission error',
      () async {
        final factory = FakeMDnsClientFactory(
          startError: const SocketException('Operation not permitted'),
        );

        await expectLater(
          discoveryOver(
            factory,
          ).discover(bundleId: bundleId, hostnames: deviceHostnames),
          throwsA(
            isA<MdnsDiscoveryException>()
                .having(
                  (e) => e.failure,
                  'failure',
                  MdnsDiscoveryFailure.localNetworkPermission,
                )
                .having((e) => e.message, 'message', contains('Local Network')),
          ),
        );
      },
    );
  });
}
