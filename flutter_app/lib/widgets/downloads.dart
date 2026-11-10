/// Getting a document from the server onto the device.
library;

import '../core/api/api_client.dart';
import '../core/files.dart';

/// Downloads a file and lets the user choose where to keep it.
///
/// Completes with `true` when the file was saved and with `false` when the user cancelled.
/// Whatever the download or the device reports as a failure is thrown.
Future<bool> saveDownload({
  required Future<DownloadedFile> Function() download,
  required FileGateway files,
  required String fallbackName,
}) async {
  final file = await download();
  // "download" is what the client reports when the server did not name the file.
  final name = file.filename == 'download' ? fallbackName : file.filename;
  return files.saveFile(name: name, bytes: file.bytes, mimeType: file.contentType, dialogTitle: 'ذخیرهٔ سند');
}
