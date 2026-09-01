#!/usr/bin/env node

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const inventoryPath = join(root, 'docs/data-machine-code-migration-inventory.json');
const inventory = JSON.parse(readFileSync(inventoryPath, 'utf8'));
const failures = [];

const requiredFields = [
  'id', 'surface', 'source', 'evidence_kind', 'contracts', 'current_owner',
  'current_consumers', 'persistence', 'target_owner', 'disposition',
  'migration_issue', 'verification_gate',
];
const ids = new Set();

for (const [index, row] of inventory.rows.entries()) {
  for (const field of requiredFields) {
    if (!(field in row) || row[field] === '' || row[field] === null) {
      failures.push(`row ${index} (${row.id ?? 'missing id'}) lacks ${field}`);
    }
  }
  if (!row.source?.repository || !row.source?.path || !row.source?.symbol_or_command) {
    failures.push(`row ${row.id ?? index} lacks source repository/path/symbol_or_command`);
  }
  if (!Array.isArray(row.current_consumers) || row.current_consumers.length === 0) {
    failures.push(`row ${row.id ?? index} has no current consumer evidence`);
  }
  if (ids.has(row.id)) failures.push(`duplicate row id ${row.id}`);
  ids.add(row.id);
  if (!inventory.target_owner_values.includes(row.target_owner)) {
    failures.push(`row ${row.id} has invalid target_owner ${row.target_owner}`);
  }
  if (!inventory.disposition_values.includes(row.disposition)) {
    failures.push(`row ${row.id} has invalid disposition ${row.disposition}`);
  }
  if (!inventory.evidence_kind_values.includes(row.evidence_kind)) {
    failures.push(`row ${row.id} has invalid evidence_kind ${row.evidence_kind}`);
  }
}

const coveredSubsystems = new Set(inventory.rows.map((row) => row.subsystem).filter(Boolean));
for (const subsystem of inventory.top_level_dmc_subsystems) {
  if (!coveredSubsystems.has(subsystem)) failures.push(`top-level DMC subsystem is unclassified: ${subsystem}`);
}

const classifications = new Map();
for (const [kind, paths] of Object.entries(inventory.reference_file_classification)) {
  for (const path of paths) {
    if (classifications.has(path)) failures.push(`reference file classified twice: ${path}`);
    classifications.set(path, kind);
  }
}

const wpCodingAgentsSources = new Set(
  inventory.rows
    .filter((row) => row.source.repository === 'wp-coding-agents')
    .map((row) => row.source.path),
);
for (const path of classifications.keys()) {
  if (!wpCodingAgentsSources.has(path)) failures.push(`classified file has no evidence row: ${path}`);
}

const extensions = new Set(['.js', '.json', '.md', '.mjs', '.php', '.py', '.sh', '.ts', '.yaml', '.yml']);
const ignoredDirectories = new Set(['.git', 'node_modules']);
const referencePattern = /\bdata-machine-code\b|\bwp\s+datamachine-code\b|DataMachineCode\\|datamachine_code_|datamachine-code\//;
const exactContractPattern = /\bdata-machine-code\b|\bwp\s+datamachine-code(?:\s+[a-z0-9_/-]+)?|datamachine_code_[a-z0-9_]+|datamachine-code\/[a-z0-9_/-]+|DataMachineCode\\[A-Za-z0-9_\\]+/g;
const lexicalExclusions = new Set(inventory.lexical_reference_exclusions ?? []);
const allContracts = inventory.rows.flatMap((row) => row.contracts);

function contractCovered(contract) {
  return allContracts.some((known) => {
    if (known.endsWith('*')) return contract.startsWith(known.slice(0, -1));
    if (known.includes('*')) {
      const expression = known.split('*').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*');
      return new RegExp(`^${expression}$`).test(contract);
    }
    return known === contract || (known === 'DataMachineCode\\*' && contract.startsWith('DataMachineCode\\'));
  });
}

function walk(directory) {
  for (const name of readdirSync(directory)) {
    if (ignoredDirectories.has(name)) continue;
    const path = join(directory, name);
    const stat = statSync(path);
    if (stat.isDirectory()) {
      walk(path);
      continue;
    }
    const extension = name.includes('.') ? name.slice(name.lastIndexOf('.')) : '';
    if (!extensions.has(extension)) continue;
    const repositoryPath = relative(root, path);
    if (
      repositoryPath === relative(root, inventoryPath)
      || repositoryPath === 'docs/data-machine-code-migration-inventory.md'
      || repositoryPath === 'scripts/validate-dmc-migration-inventory.mjs'
    ) continue;
    const content = readFileSync(path, 'utf8');
    if (!referencePattern.test(content)) continue;
    if (lexicalExclusions.has(repositoryPath)) continue;
    if (!classifications.has(repositoryPath)) {
      failures.push(`DMC reference file is not classified: ${repositoryPath}`);
    }
    for (const contract of content.match(exactContractPattern) ?? []) {
      if (!contractCovered(contract)) failures.push(`DMC contract is not inventoried: ${contract} (${repositoryPath})`);
    }
  }
}

walk(root);

for (const path of classifications.keys()) {
  try {
    if (!referencePattern.test(readFileSync(join(root, path), 'utf8'))) {
      failures.push(`classified reference file no longer contains a DMC reference: ${path}`);
    }
  } catch {
    failures.push(`classified reference file does not exist: ${path}`);
  }
}

for (const path of lexicalExclusions) {
  if (!referencePattern.test(readFileSync(join(root, path), 'utf8'))) {
    failures.push(`lexical DMC exclusion no longer needs an explicit entry: ${path}`);
  }
}

if (failures.length > 0) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}

console.log(`DMC migration inventory valid: ${inventory.rows.length} rows, ${coveredSubsystems.size} subsystems, ${classifications.size} classified repository files`);
