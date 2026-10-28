import { Component, ElementRef, OnDestroy, OnInit, afterRenderEffect, inject, signal, viewChild } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { DecimalPipe, Location } from '@angular/common';
import { ActivatedRoute, Router, RouterLink, RouterLinkActive } from '@angular/router';
import { combineLatest, Subscription } from 'rxjs';
import { Api, Cell, Detail, Filters, Meta, Overview, Page, View, errorText, viewPaths } from './api';
import { GridComponent, displayCell } from './grid';
import { ActivitySummary, summarizeOverview } from './overview';
@Component({
  standalone: true, imports: [FormsModule, DecimalPipe, GridComponent, RouterLink, RouterLinkActive],
  templateUrl: './investigation.html'
})
export class InvestigationComponent implements OnInit, OnDestroy {
  private readonly api = inject(Api);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  private readonly location = inject(Location);
  private subscription?: Subscription;
  private generation = 0;
  readonly meta = signal<Meta | null>(null);
  readonly result = signal<Page | Overview | null>(null);
  readonly detail = signal<Detail | null>(null);
  readonly error = signal('');
  readonly loading = signal(false);
  readonly elapsed = signal<number | null>(null);
  readonly exporting = signal(false);
  readonly view = signal<View>('overview');
  readonly summary = signal<ActivitySummary | null>(null);
  readonly clientId = signal<number | undefined>(undefined);
  private readonly detailDialog = viewChild<ElementRef<HTMLDialogElement>>('detailDialog');
  readonly text = displayCell;
  readonly names: Record<View, string> = { overview: 'Overview', messages: 'Messages', sessions: 'Client sessions', smtp: 'SMTP clients', smtpTransactions: 'SMTP transactions' };
  readonly routes = [{ path: '/overview', label: 'Overview' }, { path: '/sessions', label: 'Client sessions' },
    { path: '/messages', label: 'Messages' }, { path: '/smtp/clients', label: 'SMTP clients' }];
  readonly captions: Record<View, string> = {
    overview: 'Activity by hour and server from retained source rows. Open a server card to investigate it.',
    messages: 'One row per message, consolidated across servers, including mail refused during SMTP. Open a message to see its route and SMTP evidence.',
    sessions: 'One row per client session. Open a session to see its timeline across front-end and back-end logs, then expand a step for source evidence.',
    smtp: 'One row per SMTP peer and authenticated account group, with volume and outcomes. Open a client to see its transactions and their SMTP transcript.',
    smtpTransactions: 'One row per SMTP transaction. Open a transaction to read its transcript; transcripts are never loaded with the list.'
  };
  filters: Filters = { from: new Date(Date.now() - 7 * 86400000).toISOString(), to: new Date().toISOString(), user: '', server: '', status: '', page: 1, size: 100 };
  fromInput = '';
  toInput = '';
  constructor() {
    afterRenderEffect(() => {
      const dialog = this.detailDialog()?.nativeElement;
      if (dialog && !dialog.open) dialog.showModal();
    });
  }
  private inputTime(value: string): string {
    const date = new Date(value);
    return Number.isFinite(date.getTime()) ? new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16) : '';
  }
  async ngOnInit(): Promise<void> {
    this.view.set(this.route.snapshot.data['view'] as View);
    const state: unknown = this.view() === 'smtpTransactions' && this.route.snapshot.paramMap.has('id')
      ? this.router.getCurrentNavigation()?.extras.state ?? this.location.getState() : undefined;
    if (typeof state === 'object' && state !== null && 'smtpClientId' in state &&
      typeof state.smtpClientId === 'number' && Number.isSafeInteger(state.smtpClientId) && state.smtpClientId > 0) {
      this.clientId.set(state.smtpClientId);
    }
    this.subscription = combineLatest([this.route.paramMap, this.route.queryParamMap]).subscribe(([path, params]) => {
      const client = path.get('clientId');
      if (client !== null) this.clientId.set(Number(client));
      const size = Number(params.get('size') ?? 100);
      const page = Number(params.get('page') ?? 1);
      this.filters = {
        from: params.get('from') ?? this.filters.from, to: params.get('to') ?? this.filters.to,
        user: params.get('user') ?? '', server: params.get('server') ?? '', status: params.get('status') ?? '',
        size: [25, 50, 100, 200, 500].includes(size) ? size : 100,
        page: Number.isInteger(page) && page > 0 ? page : 1
      };
      this.fromInput = this.inputTime(this.filters.from);
      this.toInput = this.inputTime(this.filters.to);
      void this.load();
    });
  }
  ngOnDestroy(): void { this.generation++; this.subscription?.unsubscribe(); }
  async load(): Promise<void> {
    const generation = ++this.generation;
    this.loading.set(true); this.error.set(''); this.elapsed.set(null); this.result.set(null); this.detail.set(null); this.summary.set(null);
    const started = performance.now();
    try {
      const meta = await this.api.meta();
      if (generation !== this.generation) return;
      this.meta.set(meta);
      if (meta.requiresMigration) throw new Error(`Schema ${meta.schemaVersion} cannot be served. Migrate a NEW copy to schema ${meta.supportedSchemaVersion}; Serve never changes this database.`);
      const id = this.route.snapshot.paramMap.get('id');
      const clientId = this.clientId();
      if (clientId !== undefined && (!Number.isSafeInteger(clientId) || clientId <= 0)) throw new Error('Invalid SMTP client identifier.');
      if (id !== null) {
        const view = this.view();
        if (view === 'overview' || !/^[1-9]\d*$/.test(id) || !Number.isSafeInteger(Number(id))) throw new Error('Invalid record identifier.');
        const [detail, result] = await Promise.all([this.api.detail(view, Number(id), this.filters), this.api.list(view, this.filters, this.clientId())]);
        if (generation === this.generation) { this.result.set(result); this.detail.set(detail); }
      } else {
        const result = await this.api.list(this.view(), this.filters, this.clientId());
        if (generation === this.generation) {
          if ('basis' in result) this.summary.set(summarizeOverview(result));
          this.result.set(result);
        }
      }
    } catch (error: unknown) { if (generation === this.generation) this.error.set(errorText(error)); }
    finally { if (generation === this.generation) { this.loading.set(false); this.elapsed.set(Math.round(performance.now() - started)); } }
  }
  async apply(page = 1): Promise<void> {
    const from = new Date(this.fromInput), to = new Date(this.toInput);
    if (!Number.isFinite(from.getTime()) || !Number.isFinite(to.getTime()) || from >= to) {
      this.error.set('Choose a valid period with an end later than its start.'); return;
    }
    this.filters = { ...this.filters, from: from.toISOString(), to: to.toISOString(), page };
    const changed = await this.router.navigate([this.listPath()], { queryParams: { ...this.filters } });
    if (!changed) await this.load();
  }
  async open(id: number): Promise<void> {
    await this.router.navigate([viewPaths[this.view()], id], { queryParams: { ...this.filters }, state: { smtpClientId: this.clientId() } });
  }
  async back(): Promise<void> {
    await this.router.navigate([this.listPath()], { queryParams: { ...this.filters } });
  }
  async navigatePage(page: number): Promise<void> {
    await this.router.navigate([this.listPath()], { queryParams: { ...this.filters, page } });
  }
  listPath(): string { return this.view() === 'smtpTransactions' && this.clientId() !== undefined ? `/smtp/clients/${this.clientId()}/transactions` : viewPaths[this.view()]; }
  async transactions(): Promise<void> {
    const detail = this.detail();
    if (this.view() === 'smtp' && detail) await this.router.navigate(['/smtp/clients', detail.id, 'transactions'], { queryParams: { ...this.filters, page: 1 } });
  }
  async selectServer(server: string): Promise<void> {
    await this.router.navigate(['/overview'], { queryParams: { ...this.filters, server, page: 1 } });
  }
  async clear(): Promise<void> { this.filters = { ...this.filters, user: '', server: '', status: '', page: 1 }; await this.apply(); }
  closeDetail(event: Event): void { event.preventDefault(); void this.back(); }
  paged(): Page | null { const result = this.result(); return result && 'hasMore' in result ? result : null; }
  basis(): string { const result = this.result(); return result && 'basis' in result ? result.basis : ''; }
  nested(value: Cell | undefined): Cell[][] | null { return Array.isArray(value) && value.length > 0 && value.every(Array.isArray) ? value : null; }
  expanded(value: Cell): string { return Array.isArray(value) ? JSON.stringify(value, null, 2) : displayCell(value); }
  async exportCsv(): Promise<void> {
    if (this.view() === 'overview' || this.clientId() !== undefined || this.exporting()) return;
    this.exporting.set(true); this.error.set('');
    try {
      const blob = await this.api.csv(this.view() as Exclude<View, 'overview'>, this.filters);
      const url = URL.createObjectURL(blob), anchor = document.createElement('a');
      anchor.href = url; anchor.download = `ExchangeLogs-${this.view()}.csv`; anchor.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (error: unknown) { this.error.set(errorText(error)); }
    finally { this.exporting.set(false); }
  }
}
