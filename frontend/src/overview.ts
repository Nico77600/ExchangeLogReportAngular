import { Overview } from './api';

export interface ActivityTotals { tracking: number; access: number; smtp: number }
export interface ServerActivity extends ActivityTotals { name: string }
export interface DailyActivity extends ActivityTotals { day: string }
export interface ActivitySummary {
  totals: ActivityTotals;
  servers: ServerActivity[];
  days: DailyActivity[];
  maximum: number;
}

export function summarizeOverview(overview: Overview): ActivitySummary {
  const columns = new Map(overview.columns.map((column, index) => [column.name, index]));
  for (const name of ['Hour', 'Server', 'Tracking events', 'Retained access requests', 'SMTP transactions']) {
    if (!columns.has(name)) throw new Error(`The overview response is missing its ${name} column.`);
  }
  const servers = new Map<string, ServerActivity>(), days = new Map<string, DailyActivity>();
  const totals: ActivityTotals = { tracking: 0, access: 0, smtp: 0 };
  for (const row of overview.rows) {
    const cell = (name: string) => row.cells[columns.get(name) ?? -1];
    const count = (name: string): number => {
      const value = cell(name);
      if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) throw new Error(`Invalid overview count: ${name}.`);
      return value;
    };
    const serverName = cell('Server'), hour = cell('Hour');
    if (typeof serverName !== 'string' || typeof hour !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(hour)) throw new Error('Invalid overview server or UTC hour.');
    const name = serverName, day = hour.slice(0, 10);
    const server = servers.get(name) ?? { name, tracking: 0, access: 0, smtp: 0 };
    const daily = days.get(day) ?? { day, tracking: 0, access: 0, smtp: 0 };
    // Sum disjoint event bins, never per-bin distinct message counts or user counts.
    const values: ActivityTotals = { tracking: count('Tracking events'), access: count('Retained access requests'), smtp: count('SMTP transactions') };
    for (const key of ['tracking', 'access', 'smtp'] as const) {
      totals[key] += values[key]; server[key] += values[key]; daily[key] += values[key];
    }
    servers.set(name, server); days.set(day, daily);
  }
  const activity = [...days.values()].sort((a, b) => a.day.localeCompare(b.day));
  return { totals, servers: [...servers.values()].sort((a, b) => a.name.localeCompare(b.name)), days: activity,
    maximum: Math.max(1, ...activity.map(day => Math.max(day.tracking, day.access))) };
}
