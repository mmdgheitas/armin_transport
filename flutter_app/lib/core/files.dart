/// Choosing files for upload and saving downloaded files, behind an interface so that
/// screens can be tested without the dialogs of the operating system.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A file the user chose for upload.
class PickedFile {
  const PickedFile({required this.name, required this.size, required this.readBytes});

  final String name;

  /// The size in bytes, or `null` when the platform does not report it before the file is read.
  final int? size;

  final Future<Uint8List> Function() readBytes;
}

abstract class FileGateway {
  /// Lets the user choose files. [allowedExtensions] are given without a dot; empty means any file.
  /// Completes with an empty list when the user cancels.
  Future<List<PickedFile>> pickFiles({List<String> allowedExtensions = const <String>[], String? dialogTitle});

  /// Lets the user choose where to save [bytes]. Completes with `false` when the user cancels.
  Future<bool> saveFile({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
  });

  /// Removes the copies that picking files may have left in the cache of the app.
  Future<void> discardTemporaryFiles();
}

final RegExp _reservedCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]');
final RegExp _directionMarks = RegExp('[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]');
final RegExp _trailingDotsAndSpaces = RegExp(r'[. ]+$');
final RegExp _deviceName = RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$', caseSensitive: false);

// File systems limit a name to 255 UTF-16 units (Windows) or 255 bytes (Android).
// The limits below leave room for what a save dialog may append, such as " (1)".
const int _maxNameUnits = 120;
const int _maxNameBytes = 200;

/// The longest beginning of [text] within [maxUnits] UTF-16 units and [maxBytes] UTF-8 bytes
/// that does not cut a character in two.
String _fit(String text, int maxUnits, int maxBytes) {
  final fitting = StringBuffer();
  var units = 0;
  var bytes = 0;
  for (final rune in text.runes) {
    units += rune > 0xffff ? 2 : 1;
    bytes += rune < 0x80 ? 1 : (rune < 0x800 ? 2 : (rune < 0x10000 ? 3 : 4));
    if (units > maxUnits || bytes > maxBytes) break;
    fitting.writeCharCode(rune);
  }
  return fitting.toString();
}

/// A name that every supported platform accepts for a file, derived from a name sent by the server.
///
/// Path separators and other reserved characters become underscores, so a name can never point
/// outside the folder the user chooses; direction marks are removed, so the real extension stays visible.
String safeFileName(String name, {String fallback = 'download'}) {
  var cleaned = name.replaceAll(_directionMarks, '').replaceAll(_reservedCharacters, '_').trim();
  cleaned = cleaned.replaceAll(_trailingDotsAndSpaces, '');
  if (cleaned.isEmpty || cleaned.replaceAll('_', '').replaceAll('.', '').isEmpty) return fallback;
  if (_deviceName.hasMatch(cleaned)) cleaned = '_$cleaned';
  if (cleaned.length > _maxNameUnits || utf8.encode(cleaned).length > _maxNameBytes) {
    final dot = cleaned.lastIndexOf('.');
    final extension = dot > 0 && cleaned.length - dot <= 12 ? cleaned.substring(dot) : '';
    final stem = cleaned.substring(0, cleaned.length - extension.length);
    final shortened = _fit(stem, _maxNameUnits - extension.length, _maxNameBytes - utf8.encode(extension).length);
    cleaned = '$shortened$extension'.replaceAll(_trailingDotsAndSpaces, '');
  }
  return cleaned;
}

/// The dialogs of the operating system, through the `file_picker` plugin.
class PlatformFileGateway implements FileGateway {
  const PlatformFileGateway();

  @override
  Future<List<PickedFile>> pickFiles({List<String> allowedExtensions = const <String>[], String? dialogTitle}) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: allowedExtensions.isEmpty ? null : allowedExtensions,
    );
    return [for (final file in files) PickedFile(name: file.name, size: file.lengthSync(), readBytes: file.readAsBytes)];
  }

  @override
  Future<bool> saveFile({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
  }) async {
    final saved = await FilePicker.saveFile(
      fileName: safeFileName(name),
      bytes: bytes,
      mimeType: mimeType.split(';').first.trim(),
      dialogTitle: dialogTitle,
    );
    return saved != null;
  }

  @override
  Future<void> discardTemporaryFiles() => FilePicker.clearTemporaryFiles();
}
