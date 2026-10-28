import { readFileSync, writeFileSync } from 'node:fs';
const path = new URL('../package-lock.json', import.meta.url);
const lock = JSON.parse(readFileSync(path, 'utf8'));
let changed = 0;
for (const [key, entry] of Object.entries(lock.packages)) {
  if (!entry.resolved) continue;
  const source = new URL(entry.resolved);
  if (source.protocol !== 'https:' || source.username || source.password ||
      !(source.hostname === 'registry.npmjs.org' || source.hostname.endsWith('.pkgs.visualstudio.com'))) {
    throw new Error(`Unreviewed dependency origin for ${key}`);
  }
  if (!entry.integrity?.match(/^sha(?:512|256|1)-/)) throw new Error(`Missing integrity for ${key}`);
  const name = entry.name ?? key.slice(key.lastIndexOf('node_modules/') + 'node_modules/'.length);
  if (!/^(@[a-z0-9._-]+\/)?[a-z0-9._-]+$/i.test(name) ||
      !/^\d+\.\d+\.\d+(?:[-+][a-z0-9.-]+)?$/i.test(entry.version)) throw new Error(`Unsupported package identity ${key}`);
  const basename = name.slice(name.lastIndexOf('/') + 1);
  const target = `https://registry.npmjs.org/${name}/-/${basename}-${entry.version}.tgz`;
  if (entry.resolved !== target) { entry.resolved = target; changed++; }
}
writeFileSync(path, JSON.stringify(lock, null, 2) + '\n');
console.log(`Normalized ${changed} public package URLs; exact versions and integrity digests unchanged.`);
