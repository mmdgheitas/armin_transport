/// Starts the whole app for a screen test: a session in memory, a scripted server and no real file dialogs.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:armin_transport/app.dart';
import 'package:armin_transport/core/api/models.dart';
import 'package:armin_transport/core/files.dart';
import 'package:armin_transport/core/providers.dart';
import 'package:armin_transport/core/session.dart';
import 'package:armin_transport/core/storage.dart';
import 'package:armin_transport/widgets/feedback.dart';
import 'package:armin_transport/widgets/fields.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../support/fakes.dart';

const String testServer = 'https://armin.test/api/v1';

/// A desktop window and a phone in portrait.
const Size desktopSize = Size(1280, 800);
const Size phoneSize = Size(390, 800);

typedef RouteHandler = FutureOr<ResponseBody> Function(RecordedRequest request);

/// A scripted server: answers by method and path below the API root, e.g. `'GET /shipments'`.
/// A request that the test did not expect gets a 404 that names it.
FakeHandler serverWith(Map<String, RouteHandler> routes) => (request) {
  final path = request.path.startsWith('/api/v1') ? request.path.substring('/api/v1'.length) : request.path;
  final handler = routes['${request.method} $path'];
  if (handler == null) {
    return errorResponse(404, 'not_found', message: 'آزمون پاسخی برای ${request.method} $path ندارد.');
  }
  return handler(request);
};

/// The profile as `/auth/me` reports it.
Json profileOf(Json auth) => {
  'user': auth['user'],
  'permissions': auth['permissions'],
  'app_settings': auth['app_settings'],
};

/// File dialogs that answer at once with what the test prepared.
class FakeFileGateway implements FileGateway {
  List<PickedFile> toPick = <PickedFile>[];
  bool saveResult = true;
  final List<({String name, Uint8List bytes, String mimeType})> saved = [];
  int discarded = 0;

  @override
  Future<List<PickedFile>> pickFiles({List<String> allowedExtensions = const <String>[], String? dialogTitle}) async =>
      toPick;

  @override
  Future<bool> saveFile({
    required String name,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
  }) async {
    if (saveResult) saved.add((name: name, bytes: bytes, mimeType: mimeType));
    return saveResult;
  }

  @override
  Future<void> discardTemporaryFiles() async {
    discarded += 1;
  }
}

class AppHarness {
  AppHarness(this.adapter, this.session, this.files);

  final FakeAdapter adapter;
  final AppSession session;
  final FakeFileGateway files;

  List<RecordedRequest> get calls => adapter.calls;

  static String _nameOf(RecordedRequest call) => '${call.method} ${call.path.replaceFirst('/api/v1', '')}';

  /// The requests so far as "METHOD /path", without the API root.
  List<String> get requests => [for (final call in calls) _nameOf(call)];

  /// How often [request] ("METHOD /path") has been sent.
  int count(String request) => requests.where((name) => name == request).length;

  /// The most recent [request] ("METHOD /path").
  RecordedRequest last(String request) => calls.lastWhere(
    (call) => _nameOf(call) == request,
    orElse: () => throw StateError('$request was not sent. Sent: $requests'),
  );
}

/// Starts the app and waits until the first screen has settled.
///
/// [auth] is the `data` of a login response (`authPayload()`, `adminAuthPayload()`); without it nobody is signed in.
Future<AppHarness> pumpApp(
  WidgetTester tester, {
  Map<String, RouteHandler> routes = const <String, RouteHandler>{},
  String? server = testServer,
  bool serverIsFixed = false,
  Json? auth,
  String? location,
  Size size = desktopSize,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final adapter = FakeAdapter(
    serverWith({
      // Read in the background at every start with a stored session.
      if (auth != null) 'GET /auth/me': (request) => ok(profileOf(auth)),
      ...routes,
    }),
  );
  final session = AppSession(
    storage: MemoryAppStorage(),
    serverUrl: server,
    serverIsFixed: serverIsFixed,
    auth: auth == null ? null : AuthSession.fromAuthResponse(auth, DateTime.now()),
  );
  final files = FakeFileGateway();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSessionProvider.overrideWithValue(session),
        dioProvider.overrideWithValue(fakeDio(adapter)),
        fileGatewayProvider.overrideWithValue(files),
      ],
      child: ArminApp(location: location),
    ),
  );
  await tester.pumpAndSettle();
  return AppHarness(adapter, session, files);
}

/// Finds a button by its label, whatever kind of button it is.
Finder button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton));

/// Whether the button with [label] can be pressed.
bool isEnabled(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(button(label)).enabled;

/// What is shown in the open dialog. The page underneath stays on screen and may hold the same texts and fields.
Finder inDialog(Finder finder) => find.descendant(of: find.byType(AlertDialog), matching: finder);

/// The frame of the form field labelled [label]; with [within], the one inside that part of the screen.
Finder fieldShell(String label, {Finder? within}) {
  final shell = find.byWidgetPredicate((widget) => widget is FieldShell && widget.label == label);
  return within == null ? shell : find.descendant(of: within, matching: shell);
}

/// The text box of the form field labelled [label].
Finder textBox(String label, {Finder? within}) => find.descendant(
  of: fieldShell(label, within: within),
  matching: find.byType(TextField),
);

/// What the text box of the field labelled [label] holds.
String textIn(WidgetTester tester, String label, {Finder? within}) =>
    tester.widget<TextField>(textBox(label, within: within)).controller?.text ?? '';

/// The yes-or-no setting labelled [label].
Finder checkField(String label) => find.byWidgetPredicate((widget) => widget is CheckField && widget.label == label);

/// The box of the setting labelled [label]: what a user taps to change it.
Finder checkBox(String label) => find.descendant(of: checkField(label), matching: find.byType(Checkbox));

/// Whether the setting labelled [label] is ticked.
bool isChecked(WidgetTester tester, String label) => tester.widget<CheckField>(checkField(label)).value;

/// The badge that reads [label]. Unlike a search for the text, this never matches the entry of a dropdown.
Finder badge(String label) => find.byWidgetPredicate((widget) => widget is StatusBadge && widget.label == label);

/// The bare text boxes (those without a label of their own) whose placeholder is [placeholder].
Finder boxesWithPlaceholder(String placeholder) =>
    find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.hintText == placeholder);

/// Scrolls to [target], taps it and waits until the screen has settled.
Future<void> tapOn(WidgetTester tester, Finder target) async {
  // The message of the previous step floats above the lower edge of the screen and may cover the target.
  // A user waits until it has left; the test removes it.
  for (final messenger in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
    messenger.removeCurrentSnackBar();
  }
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// Chooses [option] in the dropdown of the form field labelled [label].
Future<void> choose(WidgetTester tester, String label, String option, {Finder? within}) async {
  await tapOn(
    tester,
    find.descendant(
      of: fieldShell(label, within: within),
      matching: find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
    ),
  );
  // The open menu lies on top of the page: its entry is the last text of that kind.
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

/// A file as the file chooser hands it over.
PickedFile pickedFile(String name, List<int> bytes) =>
    PickedFile(name: name, size: bytes.length, readBytes: () async => Uint8List.fromList(bytes));

/// The answer to a download.
ResponseBody fileResponse(List<int> bytes, {required String filename, String contentType = 'application/pdf'}) =>
    ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        'content-type': [contentType],
        'content-disposition': ['attachment; filename="$filename"'],
      },
    );
