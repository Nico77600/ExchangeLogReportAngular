import { TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { RouterTestingHarness } from '@angular/router/testing';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { Api, Detail, Meta, Overview, Page } from './api';
import { InvestigationComponent } from './investigation';
import { routes } from './routes';

const meta: Meta = { name: 'Synthetic', version: '0.3.0', schemaVersion: 8, supportedSchemaVersion: 8, requiresMigration: false,
  databaseBytes: 1024, coveredFrom: null, coveredTo: null, servers: ['DEMO01'], readOnly: true, mode: 'Serve' };
const page: Page = { columns: [{ name: 'Sender', kind: 'text', grid: true }], rows: [{ id: 12, cells: ['sender@example.invalid'] }], page: 1, size: 100, hasMore: false, total: null };
const overview: Overview = { columns: ['Hour', 'Server', 'Tracking events', 'SMTP transactions', 'Retained access requests'].map(name => ({ name, kind: 'text', grid: true })),
  rows: [{ id: 1, cells: ['2026-10-15T00:00:00Z', 'DEMO01', 3, 4, 5] }], from: '', to: '', basis: 'Retained source rows' };
const detail: Detail = { id: 12, title: 'SMTP client', columns: [{ name: 'Account', kind: 'text', grid: true }], cells: ['<img src=x onerror=alert(1)>'] };
describe('Detailed-style report navigation', () => {
  const api = { meta: vi.fn(), list: vi.fn(), detail: vi.fn(), csv: vi.fn() };
  beforeEach(() => {
    vi.resetAllMocks();
    api.meta.mockResolvedValue(meta); api.list.mockResolvedValue(page); api.detail.mockResolvedValue(detail);
    HTMLDialogElement.prototype.showModal = function(): void { this.open = true; };
    TestBed.configureTestingModule({ providers: [provideRouter(routes), { provide: Api, useValue: api }] });
  });
  async function open(path: string): Promise<{ harness: RouterTestingHarness; component: InvestigationComponent }> {
    const harness = await RouterTestingHarness.create();
    const component = await harness.navigateByUrl(path, InvestigationComponent);
    await harness.fixture.whenStable(); harness.detectChanges();
    return { harness, component };
  }
  it('renders the historical header, tiles, server cards, chart and horizontal navigation', async () => {
    api.list.mockResolvedValue(overview);
    const { harness } = await open('/overview?from=2026-10-15T00:00:00Z&to=2026-10-16T00:00:00Z');
    const element = harness.routeNativeElement;
    expect(element?.querySelector('h1')?.textContent).toBe('Exchange Server troubleshooting');
    expect(element?.querySelectorAll('.tile')).toHaveLength(4);
    expect(element?.querySelector('.server-card')?.textContent).toContain('DEMO01');
    expect(element?.querySelector('.activity-chart')).not.toBeNull();
    expect(element?.querySelector('.tabs')?.textContent).toContain('SMTP clients');
    expect(element?.textContent).toContain('Events, not distinct messages');
  });
  it('opens details in a native modal, preserves filters and wires client transaction drilldown', async () => {
    const { harness, component } = await open('/smtp/clients/12?from=2026-10-15T00:00:00Z&to=2026-10-16T00:00:00Z&user=a%2Bb');
    expect(harness.routeNativeElement?.querySelector('dialog')?.open).toBe(true);
    expect(harness.routeNativeElement?.querySelector('img')).toBeNull();
    expect(harness.routeNativeElement?.textContent).toContain('<img src=x onerror=alert(1)>');
    await component.transactions();
    await harness.fixture.whenStable();
    expect(TestBed.inject(Router).url).toContain('/smtp/clients/12/transactions?');
    expect(TestBed.inject(Router).url).toContain('user=a%2Bb');
    expect(api.list).toHaveBeenLastCalledWith('smtpTransactions', expect.objectContaining({ user: 'a+b', page: 1 }), 12);
  });
  it('opens SMTP details with the canonical reloadable server route', async () => {
    const { harness, component } = await open('/smtp?user=alice');
    await component.open(12); await harness.fixture.whenStable();
    expect(TestBed.inject(Router).url).toContain('/smtp/clients/12?');
    expect(api.detail).toHaveBeenLastCalledWith('smtp', 12, expect.objectContaining({ user: 'alice' }));
  });
  it('keeps the selected client when opening a transaction then closing its dialog', async () => {
    const { harness, component } = await open('/smtp/clients/12/transactions?user=alice');
    await component.open(19); await harness.fixture.whenStable();
    expect(TestBed.inject(Router).url).toContain('/smtp/transactions/19?');
    const transaction: unknown = harness.routeDebugElement?.componentInstance;
    if (!(transaction instanceof InvestigationComponent)) throw new Error('The transaction route did not activate its investigation component.');
    await transaction.back(); await harness.fixture.whenStable();
    expect(TestBed.inject(Router).url).toContain('/smtp/clients/12/transactions?');
    expect(api.list).toHaveBeenLastCalledWith('smtpTransactions', expect.objectContaining({ user: 'alice' }), 12);
  });
  it('does not offer an all-client CSV as though it were a selected-client export', async () => {
    const { harness, component } = await open('/smtp/clients/12/transactions');
    expect(harness.routeNativeElement?.textContent).not.toContain('Export view to CSV');
    await component.exportCsv();
    expect(api.csv).not.toHaveBeenCalled();
  });
  it('does not leak SMTP navigation state into an unrelated view', async () => {
    const { harness, component } = await open('/smtp/clients/12/transactions');
    await component.open(19); await harness.fixture.whenStable();
    await TestBed.inject(Router).navigate(['/sessions']);
    await harness.fixture.whenStable(); harness.detectChanges();
    const sessions: unknown = harness.routeDebugElement?.componentInstance;
    if (!(sessions instanceof InvestigationComponent)) throw new Error('The sessions route did not activate.');
    expect(sessions.clientId()).toBeUndefined();
    expect(harness.routeNativeElement?.textContent).not.toContain('Selected SMTP client');
    expect(harness.routeNativeElement?.textContent).toContain('Export view to CSV');
  });
});
