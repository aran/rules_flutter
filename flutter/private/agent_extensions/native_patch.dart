// Native hot patches: the in-app half of `flutter_native_library.hot_patch`.
//
// A process can never replace a library it has `dlopen`ed, but a library can
// load a second one and send its calls there. The dev tool builds that second
// library and puts it where this app can read it; these extensions tell it
// where that is, where the running library was loaded, and then hand the file
// to the library's own loader. What a patch contains, and how calls reach it,
// is the library's business — nothing here looks inside either.
//
// Native only, and kept out of `agent.dart` for that reason: that file is also
// staged for the web dev loop, where `dart:ffi` does not exist. Registered from
// the same generated plugin registrant, so it survives a hot restart the same
// way.
//
// Imports only `dart:*`, like `agent.dart`: no `package:ffi`, so allocation goes
// through the C library directly.

import 'dart:convert';
import 'dart:developer';
import 'dart:ffi';
import 'dart:io';

void registerRulesFlutterNativeAgentExtensions() {
  registerExtension(
    'ext.rules_flutter.nativePatchDirectory',
    _handlePatchDirectory,
  );
  registerExtension(
    'ext.rules_flutter.nativeSymbolAddress',
    _handleSymbolAddress,
  );
  registerExtension('ext.rules_flutter.applyNativePatch', _handleApplyPatch);
}

/// The function a patchable library exports to load a patch: the patch's path
/// in, zero or a message out.
const String _applySymbol = 'flutter_hot_patch_apply';

/// What a patchable library exports to say which version of [_applySymbol]'s
/// contract it implements, so a library and an agent that disagree fail by
/// name instead of making a call with the wrong shape.
const String _abiSymbol = 'flutter_hot_patch_abi';

/// The one version this agent calls: [_applySymbol] as
/// `int32_t (const char *patch_path, char *message, size_t message_capacity)`.
const int _abiVersion = 1;

/// How much of a refusal the library may write. A loader explains why a patch
/// did not load in a sentence or two; the rest is truncated by the library.
const int _messageCapacity = 4096;

/// A directory this app can load a library from, created if missing.
///
/// Asked of the app rather than worked out by the dev tool: where an app may
/// write and `dlopen` from is a fact about its sandbox — a macOS container, an
/// iOS data container, Android's code cache — and the app is the one party that
/// knows it without guessing.
Future<ServiceExtensionResponse> _handlePatchDirectory(
  String method,
  Map<String, String> params,
) async {
  final directory = Directory('${Directory.systemTemp.path}/flutter_hot_patch')
    ..createSync(recursive: true);
  return ServiceExtensionResponse.result(
    jsonEncode({'path': directory.path}),
  );
}

/// Where `symbol` sits in the running copy of `library`.
Future<ServiceExtensionResponse> _handleSymbolAddress(
  String method,
  Map<String, String> params,
) async {
  final library = params['library'];
  final symbol = params['symbol'];
  if (library == null || symbol == null) {
    return _err('nativeSymbolAddress needs `library` and `symbol`');
  }
  try {
    final address = DynamicLibrary.open(library).lookup<Void>(symbol).address;
    return ServiceExtensionResponse.result(
      jsonEncode({'address': '0x${address.toRadixString(16)}'}),
    );
  } on ArgumentError catch (e) {
    return _err('could not find $symbol in $library: ${e.message}');
  }
}

/// Load `patch` into the running copy of `library`, through the library's own
/// loader — or, with no `patch`, send its calls back to the code it launched
/// with.
///
/// The second form is how an edit that was patched in and then undone gets
/// undone in the app too: the source matches the launched library again, so
/// there is nothing to build, but the process is still running the patch.
Future<ServiceExtensionResponse> _handleApplyPatch(
  String method,
  Map<String, String> params,
) async {
  final library = params['library'];
  final patch = params['patch'];
  if (library == null) {
    return _err('applyNativePatch needs `library`');
  }
  final DynamicLibrary opened;
  final int abi;
  try {
    opened = DynamicLibrary.open(library);
    abi = opened.lookupFunction<Uint32 Function(), int Function()>(
      _abiSymbol,
    )();
  } on ArgumentError catch (e) {
    return _err(
      '$library does not export $_abiSymbol, so it cannot load a patch: '
      '${e.message}',
    );
  }
  if (abi != _abiVersion) {
    return _err(
      '$library implements hot patch ABI $abi, and this app\'s rules_flutter '
      'agent calls ABI $_abiVersion. Rebuild the library and the app against '
      'the same rules_flutter.',
    );
  }
  final int Function(Pointer<Uint8>, Pointer<Uint8>, int) apply;
  try {
    apply = opened
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Size),
          int Function(Pointer<Uint8>, Pointer<Uint8>, int)
        >(_applySymbol);
  } on ArgumentError catch (e) {
    return _err(
      '$library does not export $_applySymbol, so it cannot load a patch: '
      '${e.message}',
    );
  }
  final path = patch == null ? null : _NativeString(patch);
  final message = _Allocation(_messageCapacity);
  try {
    message.bytes.value = 0;
    final status = apply(
      path?.bytes ?? nullptr,
      message.bytes,
      _messageCapacity,
    );
    if (status == 0) {
      return ServiceExtensionResponse.result(jsonEncode({'applied': true}));
    }
    final said = message.readString();
    final what = patch == null
        ? 'refused to return to its launched code'
        : 'refused the patch $patch';
    return _err(
      '$library $what (status $status)${said.isEmpty ? '' : ': $said'}',
    );
  } finally {
    path?.free();
    message.free();
  }
}

ServiceExtensionResponse _err(String message) => ServiceExtensionResponse.error(
  ServiceExtensionResponse.invalidParams,
  message,
);

/// C-heap memory, through the platform allocator `package:ffi` uses: the C
/// library everywhere but Windows, where `DynamicLibrary.process()` cannot see
/// it and COM's task allocator stands in.
class _Allocation {
  final Pointer<Uint8> bytes;

  _Allocation(int size) : bytes = _allocate(size);

  void free() => _release(bytes);

  /// The NUL-terminated UTF-8 string the library wrote, cut at the capacity if
  /// it wrote no terminator.
  String readString() {
    final units = <int>[];
    for (var i = 0; i < _messageCapacity; i++) {
      final unit = bytes[i];
      if (unit == 0) break;
      units.add(unit);
    }
    return utf8.decode(units, allowMalformed: true);
  }
}

class _NativeString extends _Allocation {
  _NativeString(String value) : this._(utf8.encode(value));

  _NativeString._(List<int> units) : super(units.length + 1) {
    for (var i = 0; i < units.length; i++) {
      bytes[i] = units[i];
    }
    bytes[units.length] = 0;
  }
}

final DynamicLibrary _allocatorLibrary = Platform.isWindows
    ? DynamicLibrary.open('ole32.dll')
    : DynamicLibrary.process();

final Pointer<Uint8> Function(int) _allocate = _allocatorLibrary
    .lookupFunction<
      Pointer<Uint8> Function(Size),
      Pointer<Uint8> Function(int)
    >(
      Platform.isWindows ? 'CoTaskMemAlloc' : 'malloc',
    );

final void Function(Pointer<Uint8>) _release = _allocatorLibrary
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >(
      Platform.isWindows ? 'CoTaskMemFree' : 'free',
    );
