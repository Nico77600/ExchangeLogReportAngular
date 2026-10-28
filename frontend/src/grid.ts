import { Component, input, output } from '@angular/core';
import { ScrollingModule } from '@angular/cdk/scrolling';
import { Cell, Column, Row } from './api';
export function displayCell(value: Cell | undefined, column?: Column): string {
  if (value === null || value === undefined) return '-';
  if (Array.isArray(value)) return value.some(Array.isArray) ? `${value.length} details` : value.map(item => displayCell(item)).join(', ');
  if (column?.kind === 'time' && typeof value === 'string') return value.replace('T', ' ').replace(/\.0+(?=[Z+])/, '');
  if (typeof value === 'number') return value.toLocaleString(undefined, { maximumFractionDigits: 2 });
  return String(value);
}
@Component({
  selector: 'exl-grid', standalone: true, imports: [ScrollingModule],
  template: `
    <div class="virtual-scroll" role="table" [attr.aria-label]="label()">
      <div class="virtual-head" role="row">
        <span role="columnheader">Record</span>
        @for (item of visibleColumns(); track item.index) { <span role="columnheader">{{ item.column.name }}</span> }
      </div>
      <cdk-virtual-scroll-viewport itemSize="36" class="grid-viewport" [style.width.px]="84 + visibleColumns().length * 180">
        <div *cdkVirtualFor="let row of rows(); trackBy: trackRow" class="virtual-row" role="row">
          <span role="cell">@if (detailEnabled()) { <button type="button" class="row-open" (click)="open.emit(row.id)" [attr.aria-label]="'Open record ' + row.id">Open</button> } @else { {{ row.id }} }</span>
          @for (item of visibleColumns(); track item.index) {
            <span role="cell" [title]="text(row.cells[item.index], item.column)">{{ text(row.cells[item.index], item.column) }}</span>
          }
        </div>
      </cdk-virtual-scroll-viewport>
    </div>
    @if (!rows().length) { <p class="grid-empty">No records match this selection.</p> }
  `
})
export class GridComponent {
  readonly label = input('Investigation records');
  readonly columns = input<Column[]>([]);
  readonly rows = input<Row[]>([]);
  readonly detailEnabled = input(true);
  readonly open = output<number>();
  readonly text = displayCell;
  visibleColumns(): { column: Column; index: number }[] {
    return this.columns().map((column, index) => ({ column, index })).filter(item => item.column.grid);
  }
  trackRow(_index: number, row: Row): number { return row.id; }
}
