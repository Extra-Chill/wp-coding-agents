// host-upgrade.mjs — Roadie plugin: `roadie upgrade` and /upgrade-and-restart
// upgrade this wp-coding-agents install.
//
// Roadie runs managed (ROADIE_MANAGED=1), so it never upgrades itself. This
// plugin gives it the host's upgrade path through Roadie's `host_upgrade`
// hook: it starts /usr/local/sbin/wp-coding-agents-upgrade (installed by
// setup with a sudoers grant for exactly `start` and `status`). The upgrade
// runs what is merged to main, in its own systemd unit, and restarts Roadie
// when it succeeds, so the request returns as soon as the upgrade has started.
//
// Local launchd installs use a separate one-shot launchd job so the upgrade
// survives Roadie's restart; manual installs without either host path register
// nothing.

import { execFile } from 'node:child_process'
import fs from 'node:fs'

const UPGRADE_BIN = process.env.WP_CODING_AGENTS_UPGRADE_BIN || '/usr/local/sbin/wp-coding-agents-upgrade'
const LOCAL_CONFIG = process.env.ROADIE_LOCAL_UPGRADE_CONFIG
  || new URL('../roadie-upgrade.json', import.meta.url)

function localConfig() {
  try {
    return JSON.parse(fs.readFileSync(LOCAL_CONFIG, 'utf8'))
  } catch {
    return null
  }
}

function runLaunchctl(args) {
  return new Promise((resolve) => {
    execFile('launchctl', args, { timeout: 10_000 }, (error, stdout, stderr) => {
      resolve({ error, output: `${stdout}${stderr}`.trim() })
    })
  })
}

function startLocalUpgrade(config) {
  return async function () {
    const target = `gui/${process.getuid()}/${config.label || 'com.wp.roadie-upgrade'}`
    const status = await runLaunchctl(['print', target])
    if (!status.error && /\bstate\s*=\s*running\b/i.test(status.output)) {
      return { ok: false, message: 'A Roadie upgrade is already running. Check `launchctl print ' + target + '`.' }
    }
    const started = await runLaunchctl(['kickstart', target])
    if (started.error) return { ok: false, message: started.output || `launchctl kickstart failed: ${started.error.message}` }
    return {
      ok: true,
      message: `Roadie upgrade to the version pinned on main started. Follow: tail -f ${config.log}; result: ${config.state} (or launchctl print ${target}).`,
    }
  }
}

function startUpgrade() {
  return new Promise((resolve) => {
    execFile('sudo', ['-n', UPGRADE_BIN, 'start'], { timeout: 60_000 }, (error, stdout, stderr) => {
      const output = `${stdout}${stderr}`.trim()
      if (!error) {
        resolve({
          ok: true,
          message: 'Upgrade started from main. Roadie restarts when it finishes.\n'
            + 'Follow: `journalctl -u wp-coding-agents-upgrade.service -f` · result: `sudo wp-coding-agents-upgrade status`',
        })
        return
      }
      if (error.code === 3) {
        resolve({ ok: false, message: 'An upgrade is already running. Check: `sudo wp-coding-agents-upgrade status`' })
        return
      }
      resolve({ ok: false, message: `Could not start the upgrade${output ? `: ${output}` : '.'}` })
    })
  })
}

export function register(roadie) {
  if (fs.existsSync(UPGRADE_BIN)) {
    roadie.addFilter('host_upgrade', () => startUpgrade)
    return
  }
  const config = localConfig()
  if (config && config.plist && fs.existsSync(config.plist)) {
    roadie.addFilter('host_upgrade', () => startLocalUpgrade(config))
  }
}
