/** Route table and main navigation. Guards are declarative; see core/router.js. */

import { companyActivityPage } from './pages/company-activity.js';
import { auditLogsPage } from './pages/audit-logs.js';
import { companiesPage } from './pages/companies.js';
import { dashboardPage } from './pages/dashboard.js';
import { loginPage } from './pages/login.js';
import { productFieldsPage } from './pages/product-fields.js';
import { profilePage } from './pages/profile.js';
import { shipmentDetailPage } from './pages/shipment-detail.js';
import { shipmentNewPage } from './pages/shipment-new.js';
import { shipmentsPage } from './pages/shipments.js';
import { trackPage } from './pages/track.js';
import { usersPage } from './pages/users.js';

export const ROUTES = [
  { path: '/company-activity', page: companyActivityPage, auth: true, permission: 'company_activity:view' },
  { path: '/track', page: trackPage, auth: true },
  { path: '/login', page: loginPage, layout: 'public', narrow: true, guestOnly: true },
  { path: '/dashboard', page: dashboardPage, auth: true, permission: 'dashboard:view' },
  { path: '/shipments', page: shipmentsPage, auth: true, permission: 'shipment:view' },
  { path: '/shipments/new', page: shipmentNewPage, auth: true, permission: 'shipment:create', navPath: '/shipments' },
  { path: '/shipments/:id', page: shipmentDetailPage, auth: true, permission: 'shipment:view', navPath: '/shipments' },
  { path: '/companies', page: companiesPage, auth: true, permission: 'company:view' },
  { path: '/users', page: usersPage, auth: true, permission: 'user:view' },
  { path: '/product-fields', page: productFieldsPage, auth: true, permission: 'product_field:manage' },
  { path: '/audit-logs', page: auditLogsPage, auth: true, permission: 'audit_log:view' },
  { path: '/profile', page: profilePage, auth: true },
];

export const NAV_ITEMS = [
  { path: '/company-activity', label: 'سابقهٔ فعالیت شرکت', icon: 'list', permission: 'company_activity:view' },
  { path: '/dashboard', label: 'داشبورد', icon: 'grid', permission: 'dashboard:view' },
  { path: '/shipments', label: 'محموله‌ها', icon: 'package', permission: 'shipment:view' },
  { path: '/companies', label: 'شرکت‌ها', icon: 'briefcase', permission: 'company:view' },
  { path: '/users', label: 'کاربران', icon: 'users', permission: 'user:view' },
  { path: '/product-fields', label: 'فیلدهای محموله', icon: 'sliders', permission: 'product_field:manage' },
  { path: '/audit-logs', label: 'گزارش رویدادها', icon: 'list', permission: 'audit_log:view' },
];
