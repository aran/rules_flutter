"""One record for each native library a `native_deps` entry brings, with every fact about it.

A `native_deps` entry is a shared library, bare or wrapped in a
`flutter_native_library`. What the build knows of each of its libraries
travels together, in `FlutterInfo.native_libraries`, so that no reader joins
parallel lists back up by File:

- `library`: the File the app bundles.
- `package`: the Dart package whose `native_deps` brought it: a plugin's, or
  the application's own. An application leaves out the libraries of a
  federated plugin's implementations it did not choose, as flutter_tools
  builds no native code of them, and an Android plugin's AAR carries its
  package's.
- `sources`: the first-party sources it is built from, which a hot reload
  stats to notice that the library went stale (`native_library_aspect.bzl`).
- `contract`: the files its bindings were generated from, which the dev tool
  compares to decide whether the library the running app has can serve an
  increment (`flutter_native_library`). Empty when nothing describes them.
- `link_inputs`: what it was linked from, every object file and static
  archive its debugging map names, which an Apple dSYM of it is read from
  (`native_link_aspect.bzl`). Empty for a prebuilt library; None when the
  build cannot see the link or `dsym` is set, and `link_inputs_unset_reason`
  then says why when `dsym` is not.
- `dsym`: the `.dSYM` directory the action that linked it made, which is its
  dSYM as it is (rustc's, for a `rust_shared_library`), or None.
"""

load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load("//flutter/private:constants.bzl", "SHARED_LIBRARY_EXTENSIONS")
load("//flutter/private:native_library_aspect.bzl", "NativeLibraryFactsInfo")
load("//flutter/private:native_link_aspect.bzl", "NativeLinkInfo")

visibility("//flutter/...")

def native_library_records(native_deps, package):
    """The record of each library of each `native_deps` entry.

    A library that nothing describes has an empty `contract` rather than
    being left out: "this library has nothing describing its bindings" is the
    state the dev tool has to be able to name.

    Args:
        native_deps: The `native_deps` targets, wrapped or bare, with the
            `native_library_aspect` and the `native_link_aspect`.
        package: The name of the Dart package they are the `native_deps` of.

    Returns:
        List of `struct(library, package, sources, contract, link_inputs, dsym,
        link_inputs_unset_reason)`, as `FlutterInfo.native_libraries` holds
        them.
    """
    records = []
    for dep in native_deps:
        # A source file is no rule's target, so the aspect does not visit it.
        facts = dep[NativeLibraryFactsInfo] if NativeLibraryFactsInfo in dep else None
        sources = tuple(facts.sources.to_list()) if facts else ()
        contract = ()
        described = {}
        if FlutterNativeLibraryInfo in dep:
            info = dep[FlutterNativeLibraryInfo]
            contract = tuple(info.binding_contract.to_list())
            described = {lib: True for lib in info.libraries.to_list()}
        for f in dep[DefaultInfo].files.to_list():
            if f.extension not in SHARED_LIBRARY_EXTENSIONS:
                continue

            # A prebuilt file was linked from nothing in the build.
            if f.is_source:
                link_inputs, dsym, unset_reason = depset(), None, None
            else:
                link = dep[NativeLinkInfo]
                link_inputs, dsym, unset_reason = link.link_inputs, link.dsym, link.link_inputs_unset_reason
            records.append(struct(
                library = f,
                package = package,
                sources = sources,
                contract = contract if f in described else (),
                link_inputs = link_inputs,
                dsym = dsym,
                link_inputs_unset_reason = unset_reason,
            ))
    return records

def merge_native_libraries(label, records):
    """One record for each library, however many routes brought it.

    A library can reach an application more than once: in its own
    `native_deps` and a plugin's, or in two plugins'. Its records merge into
    one. Its sources are all of theirs, each once, in the order first seen. A
    record with no contract says nothing about the bindings, so it yields to
    one that has one; two that state different contracts for one library fail
    the build, since the dev tool could hold only one of them. One library
    File has one link, so a record that cannot see it yields to one that can.
    Its package is the first route's: an app ships one copy of a library.

    Args:
        label: The application's label, for the error message.
        records: The records, in the order their routes are read.

    Returns:
        dict[File, struct], each library to its merged record, in the order
        the libraries were first seen.
    """
    merged = {}
    for record in records:
        seen = merged.get(record.library)
        if seen == None:
            merged[record.library] = record
            continue
        if seen.contract and record.contract and seen.contract != record.contract:
            fail((
                "%s: two `native_deps` entries bring %s and state different " +
                "binding contracts for it (%s, and %s). One library has one " +
                "contract: wrap it once, and name that wrapper in each place."
            ) % (
                label,
                record.library.short_path,
                [f.short_path for f in seen.contract],
                [f.short_path for f in record.contract],
            ))
        linked = seen if seen.link_inputs != None or seen.dsym != None else record
        merged[record.library] = struct(
            library = record.library,
            package = seen.package,
            sources = tuple({f: None for f in list(seen.sources) + list(record.sources)}.keys()),
            contract = seen.contract or record.contract,
            link_inputs = linked.link_inputs,
            dsym = linked.dsym,
            link_inputs_unset_reason = linked.link_inputs_unset_reason,
        )
    return merged

def native_library_files(app_info):
    """The library File of each record of an application's `native_libraries`, in order.

    Args:
        app_info: The application's `FlutterApplicationInfo`.

    Returns:
        A list of Files.
    """
    return [record.library for record in app_info.native_libraries]

def plugin_native_libraries(app_info):
    """The records of an application's `native_libraries` that a plugin's Android library carries.

    Those of each package with an Android library in
    `FlutterApplicationInfo.android_libs`: an AAR of the plugin carries its
    `native_deps` libraries, as Gradle's of the plugin carries what its own
    build links.

    Args:
        app_info: The application's `FlutterApplicationInfo`.

    Returns:
        A list of records, in the order of `native_libraries`.
    """
    packages = {entry.package: True for entry in app_info.android_libs.to_list()}
    return [record for record in app_info.native_libraries if record.package in packages]
