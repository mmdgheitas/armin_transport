/// Tenant-scoped work history, without security logs or private staff file metadata.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../audit/audit_labels.dart';

class CompanyActivityPage extends ConsumerWidget {
  const CompanyActivityPage({super.key, this.companyId});

  final String? companyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    if (auth == null) return const SizedBox.shrink();
    final api = ref.watch(apiProvider);
    final id = auth.user.role == 'CUSTOMER' ? auth.user.companyId : companyId;
    return PageBody(children: [
      const PageHeader(title: 'سابقهٔ فعالیت شرکت', description: 'چه کسی، چه کاری و در چه زمانی انجام داده است.'),
      if (id == null)
        PagedTable<Company>(
          filters: null,
          load: (page) => api.companies(page: page),
          emptyIcon: Icons.business_outlined,
          emptyTitle: 'هنوز شرکتی ثبت نشده است.',
          columns: [TableColumn<Company>('شرکت', (context, company) => Text(company.name))],
          actions: (context, company) => [TextButton(
            onPressed: () => context.go(Uri(path: AppPaths.companyActivity, queryParameters: {'company_id': company.id}).toString()),
            child: const Text('مشاهدهٔ فعالیت‌ها'))],
        )
      else
        PagedTable<AuditLogEntry>(
          key: ValueKey<String>(id),
          filters: id,
          load: (page) async {
            final result = await api.client.get('/companies/${Uri.encodeComponent(id)}/activity', query: {'page': page});
            return PageOf<AuditLogEntry>.fromJson(result.data, AuditLogEntry.fromJson);
          },
          emptyIcon: Icons.history,
          emptyTitle: 'هنوز فعالیتی ثبت نشده است.',
          columns: [
            TableColumn<AuditLogEntry>('زمان', (context, entry) => Text(formatDateTime(entry.createdAt))),
            TableColumn<AuditLogEntry>('انجام‌دهنده', (context, entry) => Text(entry.user?.fullName ?? 'سامانه')),
            TableColumn<AuditLogEntry>('عملیات', (context, entry) => Text(auditActionLabel(entry.action))),
          ],
        ),
    ]);
  }
}
