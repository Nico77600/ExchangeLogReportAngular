import { HttpClient, HttpErrorResponse, HttpHeaders, HttpParams } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { firstValueFrom } from 'rxjs';
import { Detail, Meta, Overview, Page, endpoints } from './contracts.generated';
export type { Cell, Column, Detail, Meta, Overview, Page, Row } from './contracts.generated';
export type View = 'overview' | 'messages' | 'sessions' | 'smtp' | 'smtpTransactions';
export const viewPaths: Record<View, string> = { overview: '/overview', messages: '/messages', sessions: '/sessions', smtp: '/smtp/clients', smtpTransactions: '/smtp/transactions' };
export interface Filters { from: string; to: string; user: string; server: string; status: string; page: number; size: number }

export function queryParams(filters: Filters, view: View, paging = true): HttpParams {
  let params = new HttpParams().set('from', filters.from).set('to', filters.to);
  if (filters.user) params = params.set('user', filters.user);
  if (filters.server) params = params.set('server', filters.server);
  if (view !== 'overview' && filters.status) params = params.set('status', filters.status);
  if (view !== 'overview' && paging) params = params.set('page', filters.page).set('size', filters.size);
  return params;
}

@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);
  private readonly headers: HttpHeaders;
  constructor() {
    const fragment = new URLSearchParams(location.hash.slice(1));
    const token = fragment.get('token') ?? sessionStorage.getItem('exl-serve-token') ?? '';
    if (fragment.has('token')) {
      sessionStorage.setItem('exl-serve-token', token);
      history.replaceState(history.state, '', location.pathname + location.search);
    }
    this.headers = new HttpHeaders({ 'X-Portal-Token': token });
  }
  meta(): Promise<Meta> { return firstValueFrom(this.http.get<Meta>(endpoints.meta, { headers: this.headers })); }
  list(view: View, filters: Filters, clientId?: number): Promise<Page | Overview> {
    const endpoint = view === 'smtpTransactions' && clientId !== undefined
      ? `${endpoints.smtp}/${clientId}/transactions` : endpoints[view];
    return firstValueFrom(this.http.get<Page | Overview>(endpoint, { headers: this.headers, params: queryParams(filters, view) }));
  }
  detail(view: Exclude<View, 'overview'>, id: number, filters: Filters): Promise<Detail> {
    const params = queryParams({ ...filters, status: '' }, 'overview', false);
    return firstValueFrom(this.http.get<Detail>(`${endpoints[view]}/${id}`, { headers: this.headers, params }));
  }
  csv(view: Exclude<View, 'overview'>, filters: Filters): Promise<Blob> {
    return firstValueFrom(this.http.get(endpoints.export, {
      headers: this.headers, params: queryParams(filters, view, false).set('view', view === 'smtpTransactions' ? 'smtp-transactions' : view), responseType: 'blob'
    }));
  }
  stop(): Promise<unknown> {
    return firstValueFrom(this.http.post(endpoints.shutdown, null, { headers: this.headers }));
  }
}
export function errorText(error: unknown): string {
  if (!(error instanceof HttpErrorResponse)) return error instanceof Error ? error.message : 'Unexpected error.';
  if (error.status === 0) return 'The local listener is unavailable. Keep the Serve window open.';
  if (error.status === 401 || error.status === 403) return 'Access refused. Open the private launch link in this browser. Never put its token in a ticket.';
  const body: unknown = error.error;
  if (typeof body === 'object' && body !== null) {
    if ('error' in body && typeof body.error === 'object' && body.error !== null &&
      'message' in body.error && typeof body.error.message === 'string') return body.error.message;
    if ('title' in body && typeof body.title === 'string') return body.title;
  }
  return `Request failed (HTTP ${error.status}). Narrow the period or consult the Serve window.`;
}
