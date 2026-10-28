import { describe, it, expect } from 'vitest';
import { Overview } from './api';
import { summarizeOverview } from './overview';

const overview: Overview = {
  columns: ['Hour', 'Server', 'Tracking events', 'Tracked messages', 'SMTP transactions', 'Retained access requests']
    .map(name => ({ name, kind: 'text', grid: true })),
  rows: [{ id: 1, cells: ['2026-10-15T00:00:00.000Z', 'DEMO01', 3, 2, 4, 5] },
    { id: 2, cells: ['2026-10-15T01:00:00.000Z', 'DEMO01', 6, 2, 7, 8] },
    { id: 3, cells: ['2026-10-16T00:00:00.000Z', 'DEMO02', 9, 2, 10, 11] }],
  from: '2026-10-15T00:00:00Z', to: '2026-10-17T00:00:00Z', basis: 'Retained UTC bins'
};
describe('Detailed-style overview with retained-source semantics', () => {
  it('sums disjoint event bins by server and UTC day, not repeated distinct-message counts', () => {
    const result = summarizeOverview(overview);
    expect(result.totals).toEqual({ tracking: 18, smtp: 21, access: 24 });
    expect(result.servers[0]).toEqual({ name: 'DEMO01', tracking: 9, smtp: 11, access: 13 });
    expect(result.days[0]).toEqual({ day: '2026-10-15', tracking: 9, smtp: 11, access: 13 });
    expect(result.maximum).toBe(13);
    expect(result.totals).not.toHaveProperty('messages');
  });
  it('retains an honest empty selection without inventing zero-valued servers', () => {
    const result = summarizeOverview({ ...overview, rows: [] });
    expect(result.servers).toEqual([]);
    expect(result.days).toEqual([]);
    expect(result.maximum).toBe(1);
  });
  it('surfaces incompatible or corrupt overview contracts instead of showing false zeros', () => {
    expect(() => summarizeOverview({ ...overview, columns: [] })).toThrow('missing');
    expect(() => summarizeOverview({ ...overview, rows: [{ id: 1, cells: ['2026-10-15T00:00:00Z', 'DEMO01', null, 2, 4, 5] }] })).toThrow('Invalid overview count');
  });
});
