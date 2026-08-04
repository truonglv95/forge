#!/usr/bin/env node
'use strict';
const { spawn } = require('../lib/index.js');
const args = process.argv.slice(2);
let child;
try {
  child = spawn(args);
} catch (err) {
  process.stderr.write(`forge: ${err.message}\n`);
  process.exit(1);
}
child.on('error', (err) => {
  process.stderr.write(`forge: ${err.message}\n`);
  process.exit(1);
});
child.on('close', (code, signal) => {
  if (signal) {
    try { process.kill(process.pid, signal); } catch (_) {}
    process.exit(1);
  }
  process.exit(code ?? 1);
});
