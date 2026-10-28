import { Routes } from '@angular/router';

const investigation = () => import('./investigation').then(module => module.InvestigationComponent);
export const routes: Routes = [
  { path: '', pathMatch: 'full', redirectTo: 'overview' },
  { path: 'smtp/clients/:clientId/transactions', data: { view: 'smtpTransactions' }, loadComponent: investigation },
  { path: 'smtp/transactions', data: { view: 'smtpTransactions' }, loadComponent: investigation },
  { path: 'smtp/transactions/:id', data: { view: 'smtpTransactions' }, loadComponent: investigation },
  { path: 'smtp/clients', data: { view: 'smtp' }, loadComponent: investigation },
  { path: 'smtp/clients/:id', data: { view: 'smtp' }, loadComponent: investigation },
  ...(['overview', 'messages', 'sessions', 'smtp'] as const).flatMap(view => [
    { path: view, data: { view }, loadComponent: investigation },
    ...(view === 'overview' ? [] : [{ path: `${view}/:id`, data: { view }, loadComponent: investigation }])
  ]),
  { path: '**', redirectTo: 'overview' }
];
