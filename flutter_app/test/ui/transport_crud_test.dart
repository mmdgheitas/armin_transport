/// Transport CRUD controls, using the same mocked HTTP harness as the other UI tests.
import 'package:armin_transport/core/api/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../support/fakes.dart';
import 'support/app_harness.dart';

void main() {
  testWidgets('admin can edit, soft-delete and restore an employee', (tester) async {
    Json employee = {'id': 'e1', 'full_name': 'Employee', 'username': 'employee', 'country': 'CI', 'deleted_at': null};
    final app = await pumpApp(tester, auth: adminAuthPayload(), location: '/employees', routes: {
      'GET /transport/employees': (request) => ok(pageOf((request.query['deleted'] == 'true') == (employee['deleted_at'] != null) ? [employee] : <Json>[])),
      'PATCH /transport/employees/e1': (request) { employee = {...employee, ...asJson(request.json)}; return ok(employee); },
      'DELETE /transport/employees/e1': (request) { employee = {...employee, 'deleted_at': '2026-11-14T12:00:00Z'}; return ok(null); },
      'POST /transport/employees/e1/restore': (request) { employee = {...employee, 'deleted_at': null}; return ok(employee); },
    });
    await tapOn(tester, button('ویرایش'));
    final field = find.descendant(of: find.byType(AlertDialog), matching: find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'اسم کامل'));
    await tester.enterText(field, 'Renamed employee');
    await tapOn(tester, inDialog(button('ثبت')));
    await tester.pump(const Duration(seconds: 1));
    expect(app.last('PATCH /transport/employees/e1').json['full_name'], 'Renamed employee');
    expect(app.last('PATCH /transport/employees/e1').json.containsKey('password'), isFalse);
    await tapOn(tester, button('حذف'));
    await tapOn(tester, inDialog(button('حذف')));
    expect(app.count('DELETE /transport/employees/e1'), 1);
    await tapOn(tester, button('حذف‌شده‌ها / بازیابی'));
    expect(find.text('Renamed employee'), findsOneWidget);
    await tapOn(tester, button('بازیابی'));
    await tapOn(tester, inDialog(button('بازیابی')));
    expect(app.count('POST /transport/employees/e1/restore'), 1);
  });

  testWidgets('customer has no transport mutation controls', (tester) async {
    final auth = authPayload('customer', {
      'user': {...employeeUser, 'role': 'CUSTOMER', 'company_id': 'c1'},
      'permissions': ['shipment:view', 'document:view', 'document:download'],
    });
    await pumpApp(tester, auth: auth, location: '/loads/s1', routes: {
      'GET /transport/shipments/s1': (request) => ok({
        'id': 's1', 'company_id': 'c1', 'company_name': 'Company', 'tracking_code': 'Exact code', 'truck_count': 1, 'border_count': 0,
        'countries': ['CI'], 'groups': [{'user_id': 'e1', 'full_name': 'Employee', 'country': 'CI', 'limit': 1, 'can_upload': false, 'can_manage': false, 'files': []}],
      }),
    });
    expect(button('ویرایش بار / تخصیص‌ها'), findsNothing);
    expect(button('حذف بار'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(button('بازیابی'), findsNothing);
  });
}
