/// The first screen after login: the numbers of the company (or of all companies) and the latest shipments.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/models.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../routing.dart';
import '../../theme.dart';
import '../../widgets/async_block.dart';
import '../../widgets/feedback.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_table.dart';
import '../shipments/shipment_widgets.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final api = ref.watch(apiProvider);
    if (auth == null) return const SizedBox.shrink();
    final canCreate = auth.can('shipment:create');
    final company = auth.user.company?.name;
    // Widget createButton() => FilledButton.icon(
    //   onPressed: () => context.go(AppPaths.newShipment),
    //   icon: const Icon(Icons.add, size: 18),
    //   label: const Text('ثبت محمولهٔ جدید'),
    // );

    return PageBody(
      children: [
        PageHeader(
          title: '${auth.user.fullName}، خوش آمدید',
          description: company == null ? 'خلاصهٔ وضعیت همهٔ شرکت‌ها' : 'خلاصهٔ وضعیت $company',
          // actions: [if (canCreate) createButton()],
        ),
        AsyncBlock<DashboardSummary>(
          load: api.dashboard,
          builder: (context, summary) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Stats(summary),
              
              const SizedBox(height: 16),
              
              // SectionCard(
              //   title: 'آخرین محموله‌ها',
              //   padded: false,
              //   actions: [
              //     OutlinedButton(onPressed: () => context.go(AppPaths.shipments), child: const Text('مشاهدهٔ همه')),
              //   ],
              //   child: summary.recentShipments.isEmpty
              //       ? EmptyBlock(
              //           icon: Icons.inventory_2_outlined,
              //           title: 'هنوز محموله‌ای ثبت نشده است.',
              //           action: canCreate ? createButton() : null,
              //         )
              //       : ResponsiveTable<Shipment>(
              //           items: summary.recentShipments,
              //           columns: shipmentColumns(showCompany: summary.isGlobal),
              //           onOpen: (shipment) => context.go(AppPaths.shipment(shipment.id)),
              //         ),
              // ),
            
            ],
          ),
        ),
      ],
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats(this.summary);

  final DashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    // final companies = summary.companies;
    // final employees = summary.employees;
    final cards = <Widget>[
      _Stat(Icons.inventory_2_outlined, Tone.info, summary.shipmentsTotal, 'کل محموله‌ها'),
      _Stat(Icons.local_shipping_outlined, Tone.success, summary.shipmentsActive, 'محموله‌های فعال'),
      _Stat(Icons.archive_outlined, Tone.warning, summary.shipmentsArchived, 'محموله‌های بایگانی‌شده'),
      _Stat(Icons.description_outlined, Tone.neutral, summary.documents, 'سندهای بارگذاری‌شده'),
      
      // if (companies != null)
      //   _Stat(
      //     Icons.business_outlined,
      //     Tone.info,
      //     companies.active,
      //     'شرکت فعال از ${formatNumber(companies.total)} شرکت',
      //   ),
      // if (employees != null)
      //   _Stat(
      //     Icons.people_outline,
      //     Tone.success,
      //     employees.active,
      //     'کارمند فعال از ${formatNumber(employees.total)} کارمند',
      //   ),
    
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 900 ? (cards.length > 4 ? 3 : 4) : (width >= 520 ? 2 : 1);
        const gap = 12.0;
        // Rounded down, so that rounding errors never push the last card of a row to the next one.
        final cardWidth = ((width - gap * (columns - 1)) / columns).floorToDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [for (final card in cards) SizedBox(width: cardWidth, child: card)],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.tone, this.value, this.label);

  final IconData icon;
  final Tone tone;
  final int value;
  final String label;

  static const Map<Tone, (Color foreground, Color background)> _colors = {
    Tone.info: (AppColors.primary, AppColors.primarySoft),
    Tone.success: (AppColors.success, AppColors.successSoft),
    Tone.warning: (AppColors.warning, AppColors.warningSoft),
    Tone.neutral: (AppColors.muted, AppColors.surfaceAlt),
    Tone.danger: (AppColors.danger, AppColors.dangerSoft),
  };

  @override
  Widget build(BuildContext context) {
    final colors = _colors[tone]!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: colors.$2, borderRadius: BorderRadius.circular(radiusLarge)),
              child: Icon(icon, size: 22, color: colors.$1),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(formatNumber(value), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.4)),
                  Text(label, style: const TextStyle(fontSize: 13, color: AppColors.muted, height: 1.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
