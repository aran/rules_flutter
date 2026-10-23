// Library-level `@Tags` extraction for the test runners.
import 'package:test/test.dart';

import '../extract_library_tags.dart';

void main() {
  group('extractLibraryTags', () {
    test('reads tags off the first directive', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden', 'slow'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          '\n'
          'void main() {}\n',
        ),
        {'golden', 'slow'},
      );
    });

    test('reads tags off a library directive', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden'])\n"
          'library;\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a file without tags has none', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('annotations after the first directive do not count', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          "@Tags(['golden'])\n"
          "import 'package:test/test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('annotations on declarations do not count', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          "@Tags(['golden'])\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('reads prefixed tags and const lists with trailing commas', () {
      expect(
        extractLibraryTags(
          "@test.Tags(const ['golden',])\n"
          "import 'package:flutter_test/flutter_test.dart' as test;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('ignores other annotations', () {
      expect(
        extractLibraryTags(
          "@TestOn('vm')\n"
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('ignores tags hidden in comments and strings', () {
      expect(
        extractLibraryTags(
          "// @Tags(['comment'])\n"
          "/* @Tags(['comment']) */\n"
          "import 'package:flutter_test/flutter_test.dart'; // @Tags(['comment'])\n"
          "const marker = \"@Tags(['string'])\";\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('skips directives with configurations and combinators', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden'])\n"
          "import 'a.dart' if (dart.library.io) 'b.dart' show a hide b;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('concatenates adjacent strings and unescapes', () {
      expect(
        extractLibraryTags(
          // The backslash escape decodes to a tag no selector could name, so
          // it stays out of the list: tag names must name valid selector
          // atoms, and invalid names are refused below.
          "@Tags(['gol' 'den', 'slow-mo', 'under_score'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden', 'slow-mo', 'under_score'},
      );
    });

    test('an invalid tag name is an error', () {
      expect(
        () => extractLibraryTags(
          "@Tags(['sp ace'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 1)
              .having(
                (e) => e.message,
                'message',
                'Invalid tag name. Tags must be (optionally hyphenated) Dart '
                    'identifiers.',
              ),
        ),
      );
      expect(
        () => extractLibraryTags(
          r"@Tags(['s\low'])"
          '\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(isA<TagsParseException>()),
      );
    });

    test('reads tags after a nested block comment', () {
      expect(
        extractLibraryTags(
          '/* outer /* inner */ still outer */\n'
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a quote inside a block comment opens no string', () {
      expect(
        extractLibraryTags(
          "/* don't */\n"
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('reads tags after a generic annotation', () {
      expect(
        extractLibraryTags(
          '@Foo<int>(3)\n'
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a generic Tags annotation still counts', () {
      expect(
        extractLibraryTags(
          "@Tags<String>(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('skips comments and strings inside annotations and directives', () {
      expect(
        extractLibraryTags(
          "@Tags<String /* version */>(['golden'])\n"
          "@Foo(')')\n"
          "import /* lib */ 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a declaration before any directive means no directives', () {
      expect(extractLibraryTags('void main() {}\n'), isEmpty);
    });

    test('an empty file has no tags', () {
      expect(extractLibraryTags(''), isEmpty);
    });

    test('reads a typed list literal', () {
      expect(
        extractLibraryTags(
          "@Tags(<String>['a', 'b'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'a', 'b'},
      );
    });

    test('reads a const typed list literal', () {
      expect(
        extractLibraryTags(
          "@Tags(const <String>['a'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'a'},
      );
    });

    test('reads tags after a script tag', () {
      expect(
        extractLibraryTags(
          '#!/usr/bin/env dart\n'
          "@Tags(['she'])\n"
          'library;\n'
          'void main() {}\n',
        ),
        {'she'},
      );
    });

    test('an empty list has no tags', () {
      expect(
        extractLibraryTags(
          '@Tags([])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a const identifier argument is an error, not an empty result', () {
      expect(
        () => extractLibraryTags(
          '@Tags(kTags)\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 1)
              .having((e) => e.message, 'message', 'Expected a List.'),
        ),
      );
    });

    test('an interpolated element is an error', () {
      expect(
        () => extractLibraryTags(
          r"@Tags(['a${1}'])"
          '\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 1)
              .having(
                (e) => e.message,
                'message',
                'Expected a String literal.',
              ),
        ),
      );
      expect(
        () => extractLibraryTags(
          r"@Tags(['a$b'])"
          '\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(isA<TagsParseException>()),
      );
    });

    test('a non-string element is an error', () {
      expect(
        () => extractLibraryTags(
          '@Tags([42])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected a String literal.',
          ),
        ),
      );
    });

    test('a set literal argument is an error', () {
      expect(
        () => extractLibraryTags(
          "@Tags(const {'a'})\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected a List.',
          ),
        ),
      );
    });

    test('a spread element is an error', () {
      expect(
        () => extractLibraryTags(
          '@Tags([...kTags])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected only literal elements.',
          ),
        ),
      );
    });

    test('a second Tags annotation is an error', () {
      expect(
        () => extractLibraryTags(
          "@Tags(['a'])\n"
          "@Tags(['b'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 2)
              .having(
                (e) => e.message,
                'message',
                'Only a single Tags may be used.',
              ),
        ),
      );
    });

    test('a block comment between @ and the name still counts', () {
      expect(
        extractLibraryTags(
          "@/*c*/Tags(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('a line comment between @ and the name still counts', () {
      expect(
        extractLibraryTags(
          '@ // gap\n'
          "Tags(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('a doc line comment between @ and the name still counts', () {
      expect(
        extractLibraryTags(
          '@ /// documents the suite\n'
          "Tags(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('a doc block comment between @ and the name still counts', () {
      expect(
        extractLibraryTags(
          '@/** documents the suite */Tags('
          "['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('whitespace between @ and the name still counts', () {
      expect(
        extractLibraryTags(
          "@ Tags(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          '@\n\tTags('
          "['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('gaps around the prefix dot still count', () {
      expect(
        extractLibraryTags(
          "@t . Tags(['c12'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          "@t/*c*/.Tags(['c12'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          "@t./*c*/Tags(['c12'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          "@/*c*/t/*c*/./*c*/Tags(['c12'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          '@t // gap\n'
          ".Tags(['c12'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('a gap before the argument list still counts', () {
      expect(
        extractLibraryTags(
          "@Tags (['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          "@Tags/*c*/(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
      expect(
        extractLibraryTags(
          '@Tags // gap\n'
          "(['c12'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'c12'},
      );
    });

    test('a comment gap in a non-test prefix still does not count', () {
      expect(
        extractLibraryTags(
          "@other/*c*/.Tags(['golden'])\n"
          "import 'package:other/other.dart' as other;\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('similar annotation names still do not count', () {
      expect(
        extractLibraryTags(
          "@Tagsx(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
      expect(
        extractLibraryTags(
          "@Skip('skip it')\n"
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
      expect(
        extractLibraryTags(
          "@Skip('skip it')\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a comment-split identifier is not a Tags name', () {
      expect(
        extractLibraryTags(
          "@Tag/*c*/s(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a gapped duplicate Tags is still a duplicate', () {
      expect(
        () => extractLibraryTags(
          "@/*c*/Tags(['a'])\n"
          "@Tags(['b'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Only a single Tags may be used.',
          ),
        ),
      );
    });
    test('a Tags through another library prefix does not count', () {
      expect(
        extractLibraryTags(
          "@other.Tags(['golden'])\n"
          "import 'package:other/other.dart' as other;\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a Tags through a package:test prefix counts', () {
      expect(
        extractLibraryTags(
          "@t.Tags(['golden'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a Tags through a conditional test import prefix counts', () {
      expect(
        extractLibraryTags(
          "@t.Tags(['golden'])\n"
          "import 'a.dart' if (dart.library.io) 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a three-part Tags name does not count', () {
      expect(
        extractLibraryTags(
          "@a.b.Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart' as a;\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a second Tags through a prefix is still a duplicate', () {
      expect(
        () => extractLibraryTags(
          "@Tags(['a'])\n"
          "@t.Tags(['b'])\n"
          "import 'package:test/test.dart' as t;\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Only a single Tags may be used.',
          ),
        ),
      );
    });

    test('the error names the line of the bad annotation', () {
      expect(
        () => extractLibraryTags(
          "@TestOn('vm')\n"
          '// a comment\n'
          '@Tags(kTags)\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having((e) => e.line, 'line', 3),
        ),
      );
    });
  });
}
