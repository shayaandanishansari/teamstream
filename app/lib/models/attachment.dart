import 'dart:typed_data';

/// A file hung off a task by a specific member.
///
/// Notes answer "what about this?"; attachments answer "here's the thing" — the
/// screenshot, the spec, the photo of the whiteboard. Authorship is a first-
/// class field rather than metadata because the board groups them by member,
/// one row each.
class Attachment {
  final String id;
  final String taskId;
  final String memberId;

  /// The name the person picked, not PocketBase's randomised stored name.
  final String name;

  /// Absolute download URL. Empty while [uploading].
  final String url;

  /// Server-rendered small version of [url], for grid previews. Falls back to
  /// [url] when the backend can't thumbnail this file.
  final String thumbUrl;

  /// Bytes in the file. 0 when unknown.
  final int size;

  final DateTime created;

  /// True between picking the file and the server confirming it.
  final bool uploading;

  /// Held in memory ONLY while [uploading], so an image previews instantly
  /// instead of after a round trip. Dropped once the real record arrives.
  final Uint8List? localBytes;

  const Attachment({
    required this.id,
    required this.taskId,
    required this.memberId,
    required this.name,
    required this.created,
    this.url = '',
    this.thumbUrl = '',
    this.size = 0,
    this.uploading = false,
    this.localBytes,
  });

  /// A placeholder for a file that's been picked but not yet stored. Image
  /// bytes ride along so the preview appears on tap; anything else would just
  /// be megabytes parked in memory for no visible gain.
  factory Attachment.pending({
    required String id,
    required String taskId,
    required String memberId,
    required String name,
    required Uint8List bytes,
  }) =>
      Attachment(
        id: id,
        taskId: taskId,
        memberId: memberId,
        name: name,
        created: DateTime.now(),
        size: bytes.length,
        uploading: true,
        localBytes: isImageName(name) ? bytes : null,
      );

  static const _imageExtensions = {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'avif',
  };

  /// Whether this should render as a picture rather than a file chip.
  bool get isImage => isImageName(name);

  static bool isImageName(String name) => _imageExtensions.contains(_extensionOf(name));

  /// Lowercase extension without the dot, or '' if the name has none.
  String get extension => _extensionOf(name);

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// "412 KB", "2.3 MB". Empty when the size is unknown.
  String get prettySize {
    if (size <= 0) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).round()} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
