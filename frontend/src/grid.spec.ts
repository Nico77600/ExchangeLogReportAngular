import { TestBed } from '@angular/core/testing';
import { describe, it, expect } from 'vitest';
import { GridComponent, displayCell } from './grid';
describe('CDK investigation grid', () => {
  it('escapes untrusted log data as text and emits only the selected id', async () => {
    const fixture = TestBed.createComponent(GridComponent);
    fixture.componentRef.setInput('columns', [{ name: 'Subject', kind: 'text', grid: true }]);
    fixture.componentRef.setInput('rows', [{ id: 12, cells: ['<img src=x onerror=alert(1)>'] }]);
    fixture.detectChanges();
    await fixture.whenStable();
    fixture.detectChanges();
    const events: number[] = [];
    fixture.componentInstance.open.subscribe(id => events.push(id));
    fixture.componentInstance.open.emit(12);
    expect(events).toEqual([12]);
    expect(fixture.nativeElement.querySelector('img')).toBeNull();
    expect(fixture.nativeElement.querySelector('cdk-virtual-scroll-viewport')).not.toBeNull();
  });
  it('excludes deferred detail columns from the list', () => {
    const fixture = TestBed.createComponent(GridComponent);
    fixture.componentRef.setInput('columns', [
      { name: 'Sender', kind: 'text', grid: true }, { name: 'Transcript', kind: 'steps', grid: false }
    ]);
    expect(fixture.componentInstance.visibleColumns().map(item => item.column.name)).toEqual(['Sender']);
  });
  it('formats ISO times without a browser-timezone reinterpretation or HTML execution', () => {
    expect(displayCell('2026-10-15T12:00:00+02:00', { name: 'Time', kind: 'time', grid: true })).toBe('2026-10-15 12:00:00+02:00');
    expect(displayCell(null)).toBe('-');
    expect(displayCell(['one', 'two'])).toBe('one, two');
    expect(displayCell('<script>')).toBe('<script>');
  });
});
