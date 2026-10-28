import { TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { Api, Filters, queryParams } from './api';
describe('Serve typed API client', () => {
  let api: Api;
  let http: HttpTestingController;
  const filters: Filters = { from: '2026-10-01T00:00:00Z', to: '2026-10-16T00:00:00Z', user: 'a+b@example.test', server: 'EX1', status: 'Failed', page: 2, size: 50 };
  beforeEach(() => {
    sessionStorage.setItem('exl-serve-token', 'synthetic-test-token');
    TestBed.configureTestingModule({ providers: [provideHttpClient(), provideHttpClientTesting()] });
    api = TestBed.inject(Api); http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => { http.verify(); sessionStorage.clear(); });
  it('preserves exact literal filters and paging without a report generation request', async () => {
    const pending = api.list('messages', filters);
    const request = http.expectOne(req => req.url === '/api/messages');
    expect(request.request.method).toBe('GET');
    expect(request.request.params.get('user')).toBe('a+b@example.test');
    expect(request.request.params.get('page')).toBe('2');
    expect(request.request.headers.get('X-Portal-Token')).toBe('synthetic-test-token');
    request.flush({ columns: [], rows: [], page: 2, size: 50, hasMore: false, total: null });
    expect((await pending).rows).toEqual([]);
  });
  it('requests details only by the selected record with the period and user scope', async () => {
    const pending = api.detail('sessions', 42, filters);
    const request = http.expectOne(req => req.url === '/api/sessions/42');
    expect(request.request.params.get('from')).toBe(filters.from);
    expect(request.request.params.has('status')).toBe(false);
    expect(request.request.params.has('page')).toBe(false);
    request.flush({ id: 42, title: 'Session', columns: [], cells: [] });
    expect((await pending).id).toBe(42);
  });
  it('exports all matching rows, not the browser page', async () => {
    const pending = api.csv('messages', filters);
    const request = http.expectOne(req => req.url === '/api/export.csv');
    expect(request.request.params.get('view')).toBe('messages');
    expect(request.request.params.has('page')).toBe(false);
    expect(request.request.params.has('size')).toBe(false);
    request.flush(new Blob(['synthetic csv']));
    expect((await pending).size).toBeGreaterThan(0);
  });
  it('omits unsupported list-only parameters on overview', () => {
    const params = queryParams(filters, 'overview');
    expect(params.has('status')).toBe(false);
    expect(params.has('size')).toBe(false);
    expect(params.get('server')).toBe('EX1');
  });
  it('uses an empty authenticated shutdown POST', async () => {
    const pending = api.stop();
    const request = http.expectOne('/api/shutdown');
    expect(request.request.body).toBeNull();
    request.flush({ stopped: true });
    await pending;
  });
  it('loads only a selected SMTP client group and keeps transaction detail separate', async () => {
    const pending = api.list('smtpTransactions', filters, 42);
    const request = http.expectOne(req => req.url === '/api/smtp/clients/42/transactions');
    expect(request.request.params.get('user')).toBe(filters.user);
    request.flush({ columns: [], rows: [], page: 2, size: 50, hasMore: false, total: null });
    await pending;
    const detail = api.detail('smtpTransactions', 19, filters);
    http.expectOne(req => req.url === '/api/smtp/transactions/19').flush({ id: 19, title: 'SMTP', columns: [], cells: [] });
    expect((await detail).id).toBe(19);
  });
  it('uses the backend transaction CSV selector rather than the frontend view name', async () => {
    const pending = api.csv('smtpTransactions', filters);
    const request = http.expectOne(req => req.url === '/api/export.csv');
    expect(request.request.params.get('view')).toBe('smtp-transactions');
    request.flush(new Blob(['synthetic csv']));
    await pending;
  });
});
