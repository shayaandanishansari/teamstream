import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teamstream/identity/identity.dart';
import 'package:teamstream/models/attachment.dart';
import 'package:teamstream/ui/board/work_folding.dart';

void main() {
  group('Attachment', () {
    Attachment named(String name) => Attachment(
          id: 'a',
          taskId: 't',
          memberId: 'm',
          name: name,
          created: DateTime(2026),
        );

    test('decides image-ness from the name, case and path insensitively', () {
      expect(named('whiteboard.PNG').isImage, isTrue);
      expect(named('photo.jpeg').isImage, isTrue);
      expect(named('spec.pdf').isImage, isFalse);
      expect(named('README').isImage, isFalse, reason: 'no extension at all');
      expect(named('trailing.').isImage, isFalse, reason: 'a dot is not an extension');
    });

    test('sizes read as sizes, and stay quiet when unknown', () {
      Attachment sized(int n) => Attachment(
            id: 'a',
            taskId: 't',
            memberId: 'm',
            name: 'f.bin',
            created: DateTime(2026),
            size: n,
          );
      expect(sized(0).prettySize, isEmpty);
      expect(sized(512).prettySize, '512 B');
      expect(sized(2048).prettySize, '2 KB');
      expect(sized(3 * 1024 * 1024).prettySize, '3.0 MB');
    });

    test('a pending image keeps its bytes, a pending document does not', () {
      final bytes = Uint8List.fromList([9, 9, 9]);
      final image = Attachment.pending(
          id: 'x', taskId: 't', memberId: 'm', name: 'shot.png', bytes: bytes);
      final doc = Attachment.pending(
          id: 'y', taskId: 't', memberId: 'm', name: 'notes.pdf', bytes: bytes);

      expect(image.uploading, isTrue);
      expect(image.localBytes, bytes);
      expect(doc.uploading, isTrue);
      expect(doc.localBytes, isNull, reason: 'nothing would render them');
      expect(doc.size, 3, reason: 'the size is still known without holding the bytes');
    });
  });

  group('WorkFolding', () {
    late SharedPreferences prefs;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    ProviderContainer container() {
      final c = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    test('records only what was actually toggled', () {
      final c = container();
      expect(c.read(workFoldingProvider), isEmpty,
          reason: 'untouched Works must fall through to the board default');

      c.read(workFoldingProvider.notifier).setCollapsed('w1', true);
      expect(c.read(workFoldingProvider), {'w1': true});

      c.read(workFoldingProvider.notifier).setCollapsed('w1', false);
      expect(c.read(workFoldingProvider), {'w1': false},
          reason: 'an explicit re-open must be remembered, not just forgotten');
    });

    test('survives a restart', () {
      final first = container();
      first.read(workFoldingProvider.notifier).setCollapsed('w1', true);
      first.read(workFoldingProvider.notifier).setCollapsed('w2', false);

      // A fresh container is a fresh launch: state comes back off disk.
      final second = container();
      expect(second.read(workFoldingProvider), {'w1': true, 'w2': false});
    });
  });
}
