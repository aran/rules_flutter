/// Self-tests for [DependencyFakeCompiler].
///
/// The fake encodes three behaviours of the real frontend_server. Every claim
/// the reload design rests on is only as good as this fake's fidelity, so the
/// behaviours are asserted here directly rather than left implicit in the tests
/// that use them.
import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('FakeSourceTree', () {
    test('dependentsOf is transitive and excludes the library itself', () {
      final tree = FakeSourceTree()
        ..add('a')
        ..add('b', inlinesFrom: {'a'})
        ..add('c', inlinesFrom: {'b'})
        ..add('unrelated');

      expect(tree.dependentsOf('a'), {'b', 'c'});
      expect(tree.dependentsOf('b'), {'c'});
      expect(tree.dependentsOf('c'), isEmpty);
      expect(tree.dependentsOf('unrelated'), isEmpty);
    });

    test(
      'imageOf records the inlined dependency versions, not just its own',
      () {
        final tree = FakeSourceTree()
          ..add('a')
          ..add('b', inlinesFrom: {'a'});

        expect(tree.imageOf('b'), const LibImage(own: 1, inlined: {'a': 1}));
        tree.edit('a');
        expect(
          tree.imageOf('b'),
          const LibImage(own: 1, inlined: {'a': 2}),
          reason: "b's own bytes never changed, but its compiled form did",
        );
      },
    );
  });

  group('DependencyFakeCompiler', () {
    late FakeSourceTree tree;
    late DependencyFakeCompiler compiler;

    setUp(() {
      tree = FakeSourceTree()
        ..add('a')
        ..add('b', inlinesFrom: {'a'});
      compiler = DependencyFakeCompiler(tree)..seedFromTree();
    });

    Future<Map<String, LibImage>> increment(Set<String> invalidated) async {
      final outcome = await compiler.compileIncrement(
        invalidated: invalidated,
        entrypoint: 'main',
      );
      return tree.deltaByDill[(outcome as CompileSucceeded).dillPath]!;
    }

    test(
      'an explicitly invalidated URI is re-emitted even when unchanged',
      () async {
        final delta = await increment({'a'});
        expect(
          delta.keys,
          {'a'},
          reason: 'explicit invalidation always re-emits, per the spike',
        );
      },
    );

    test('a changed library drags its dependents into the delta', () async {
      tree.edit('a');
      final delta = await increment({'a'});
      expect(delta.keys, {'a', 'b'});
      expect(delta['b'], const LibImage(own: 1, inlined: {'a': 2}));
    });

    test('a library already current in the accepted baseline does NOT re-emit '
        'its dependents', () async {
      tree.edit('a');
      await increment({'a'});
      await compiler.commit();

      // Same invalidation again. The compiler now believes b is current, so it
      // withholds it — the exact behaviour that strands a lagging app.
      final delta = await increment({'a'});
      expect(delta.keys, {
        'a',
      }, reason: 'dependents are judged against the accepted state');
    });

    test(
      'rollback restores the baseline, so dependents are re-derived',
      () async {
        tree.edit('a');
        await increment({'a'});
        await compiler.rollback();

        final delta = await increment({'a'});
        expect(
          delta.keys,
          {'a', 'b'},
          reason: 'a rolled-back compile must not advance the baseline',
        );
      },
    );

    test('commit advances the baseline; rollback leaves it alone', () async {
      tree.edit('a');
      await increment({'a'});
      expect(compiler.accepted['a']!.own, 1, reason: 'not committed yet');
      await compiler.commit();
      expect(compiler.accepted['a']!.own, 2);

      tree.edit('a');
      await increment({'a'});
      await compiler.rollback();
      expect(compiler.accepted['a']!.own, 2);
    });

    test('compileFull emits the whole tree and resets the baseline', () async {
      tree.edit('a');
      final outcome = await compiler.compileFull(
        entrypoint: 'main',
        invalidated: {'a'},
      );
      final delta = tree.deltaByDill[(outcome as CompileSucceeded).dillPath]!;
      expect(delta.keys, {'a', 'b'});
      await compiler.commit();
      expect(compiler.accepted['b'], const LibImage(own: 1, inlined: {'a': 2}));
    });

    test('two compilers over one tree keep independent baselines', () async {
      final other = DependencyFakeCompiler(tree)..seedFromTree();
      tree.edit('a');

      final mine = await increment({'a'});
      await compiler.commit();
      expect(mine.keys, {'a', 'b'});

      // The second compiler never saw that delta, so its baseline still holds
      // the old `a` and it re-derives b for its own app.
      final theirs = await other.compileIncrement(
        invalidated: {'a'},
        entrypoint: 'main',
      );
      expect(tree.deltaByDill[(theirs as CompileSucceeded).dillPath]!.keys, {
        'a',
        'b',
      });
    });
  });

  group('liveImageOf', () {
    test('folds reload deltas over the launch image', () async {
      final tree = FakeSourceTree()
        ..add('a')
        ..add('b', inlinesFrom: {'a'});
      final compiler = DependencyFakeCompiler(tree)..seedFromTree();
      final launched = {...compiler.accepted};
      final app = FakeAppInstance(id: 'app1');

      tree.edit('a');
      final outcome = await compiler.compileIncrement(
        invalidated: {'a'},
        entrypoint: 'main',
      );
      await app.applyKernel(
        (outcome as CompileSucceeded).dillPath,
        mode: ApplyMode.hotReload,
      );

      final live = liveImageOf(app, tree: tree, launchedWith: launched);
      expect(live['a']!.own, 2);
      expect(live['b'], const LibImage(own: 1, inlined: {'a': 2}));
    });

    test('a restart replaces the image rather than overlaying it', () async {
      final tree = FakeSourceTree()..add('a');
      final compiler = DependencyFakeCompiler(tree)..seedFromTree();
      final app = FakeAppInstance(id: 'app1');

      tree.edit('a');
      final outcome = await compiler.compileFull(
        entrypoint: 'main',
        invalidated: {'a'},
      );
      await app.applyKernel(
        (outcome as CompileSucceeded).dillPath,
        mode: ApplyMode.hotRestart,
      );

      final live = liveImageOf(
        app,
        tree: tree,
        launchedWith: const {'stale': LibImage(own: 99)},
      );
      expect(
        live.containsKey('stale'),
        isFalse,
        reason: 'a full dill is the whole program',
      );
      expect(live['a']!.own, 2);
    });
  });
}
