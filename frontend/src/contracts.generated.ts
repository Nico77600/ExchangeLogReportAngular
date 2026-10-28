// Generated from contracts/serve.json; run npm run contracts.
export type Cell = string | number | boolean | null | Cell[];
export interface Column { name: string; kind: string; grid: boolean; }
export interface Row { id: number; cells: Cell[]; }
export interface Page { columns: Column[]; rows: Row[]; page: number; size: number; hasMore: boolean; total: number | null; }
export interface Overview { columns: Column[]; rows: Row[]; from: string; to: string; basis: string; }
export interface Detail { id: number; title: string; columns: Column[]; cells: Cell[]; }
export interface Meta { name: string; version: string; schemaVersion: number; supportedSchemaVersion: number; requiresMigration: boolean; databaseBytes: number; coveredFrom: string | null; coveredTo: string | null; servers: string[]; readOnly: boolean; mode: string; }
export const endpoints = {
  "meta": "/api/meta",
  "overview": "/api/overview",
  "messages": "/api/messages",
  "sessions": "/api/sessions",
  "smtp": "/api/smtp/clients",
  "smtpTransactions": "/api/smtp/transactions",
  "export": "/api/export.csv",
  "shutdown": "/api/shutdown"
} as const;
