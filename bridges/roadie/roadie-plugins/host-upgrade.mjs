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
// Without the command (local installs, an unlocked checkout) the plugin
// registers nothing and Roadie keeps refusing managed upgrades.

import { execFile } from 'node:child_process'
import fs from 'node:fs'

const UPGRADE_BIN = process.env.WP_CODING_AGENTS_UPGRADE_BIN || '/usr/local/sbin/wp-coding-agents-upgrade'

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
  if (!fs.existsSync(UPGRADE_BIN)) return
  roadie.addFilter('host_upgrade', () => startUpgrade)
}
