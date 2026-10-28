import { readFileSync, writeFileSync } from 'node:fs';
const root = new URL('../', import.meta.url);
const contract = JSON.parse(readFileSync(new URL('contracts/serve.json', root), 'utf8'));
const types = Object.entries(contract.definitions).map(([name, value]) =>
  value.union ? `export type ${name} = ${value.union.join(' | ')};` :
    `export interface ${name} { ${Object.entries(value).map(([key, type]) => `${key}: ${type};`).join(' ')} }`);
writeFileSync(new URL('src/contracts.generated.ts', root),
  `// Generated from contracts/serve.json; run npm run contracts.\n${types.join('\n')}\nexport const endpoints = ${JSON.stringify(contract.endpoints, null, 2)} as const;\n`);
