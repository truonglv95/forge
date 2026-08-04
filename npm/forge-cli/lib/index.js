'use strict';
const { spawn } = require('node:child_process');
const path = require('node:path');
const { existsSync } = require('node:fs');

const PLATFORM_PACKAGES = {
  'darwin-x64': '@forge-ai/cli-darwin-x64',
  'darwin-arm64': '@forge-ai/cli-darwin-arm64',
  'linux-x64': '@forge-ai/cli-linux-x64',
  'linux-arm64': '@forge-ai/cli-linux-arm64',
  'win32-x64': '@forge-ai/cli-win32-x64',
};
const SUPPORTED_PLATFORMS = Object.keys(PLATFORM_PACKAGES);

function getBinaryPath() {
  const key = `${process.platform}-${process.arch}`;
  const pkgName = PLATFORM_PACKAGES[key];
  if (!pkgName) {
    throw new Error(
      `Unsupported platform/arch: ${key}. ` +
      `Forge CLI supports: ${SUPPORTED_PLATFORMS.join(', ')}.`
    );
  }
  let binaryPath;
  try {
    binaryPath = require(pkgName);
  } catch (err) {
    throw new Error(
      `Platform package "${pkgName}" is not installed or failed to load. ` +
      `Try reinstalling: npm install ${pkgName}\n` +
      `Underlying error: ${err.message}`
    );
  }
  if (!existsSync(binaryPath)) {
    throw new Error(
      `Forge binary not found at: ${binaryPath}. ` +
      `The platform package may be corrupted. Try: npm install ${pkgName}@latest`
    );
  }
  return binaryPath;
}

function spawnForge(args, options) {
  const binaryPath = getBinaryPath();
  return spawn(binaryPath, args || [], { stdio: 'inherit', ...options });
}

function execForge(args, options) {
  return new Promise((resolve, reject) => {
    const child = spawnForge(args || [], { ...(options || {}), stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    if (child.stdout) child.stdout.on('data', (chunk) => { stdout += chunk; });
    if (child.stderr) child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) { resolve({ stdout, stderr, code }); }
      else { const err = new Error(`forge exited with code ${code}`); err.code = code; err.stderr = stderr; err.stdout = stdout; reject(err); }
    });
  });
}

module.exports = { getBinaryPath, spawn: spawnForge, exec: execForge, PLATFORM_PACKAGES, SUPPORTED_PLATFORMS };
