// Installation runtime providers/plugins belong to the host environment, not
// to the code checkout selected for a fork. Project permissions remain local.
import fs from 'node:fs/promises'
import path from 'node:path'

export function registerRuntimeConfig(roadie) {
  const site = process.env.DATAMACHINE_SITE_PATH
  if (!site) return
  roadie.addFilter('opencode_server_config', (config) => (async () => {
    if (config instanceof Error) return config
    const raw = await fs.readFile(path.join(site, 'opencode.json'), 'utf8').catch((cause) => cause?.code === 'ENOENT' ? null : Promise.reject(cause))
    if (raw === null) return config
    const settings = JSON.parse(raw)
    if (settings.plugin !== undefined && (!Array.isArray(settings.plugin) || settings.plugin.some((value) => typeof value !== 'string'))) throw new Error('The host runtime plugin configuration is invalid.')
    if (settings.provider !== undefined && (!settings.provider || typeof settings.provider !== 'object' || Array.isArray(settings.provider))) throw new Error('The host runtime provider configuration is invalid.')
    const resolveSpec = (value) => value.startsWith('./') || value.startsWith('../') ? path.resolve(site, value) : value
    const providers = Object.fromEntries(Object.entries(settings.provider ?? {}).map(([name, value]) => [name, { ...value, ...(typeof value.npm === 'string' && { npm: resolveSpec(value.npm) }) }]))
    return {
      ...config,
      ...(typeof settings.model === 'string' && { model: settings.model }),
      ...(typeof settings.small_model === 'string' && { small_model: settings.small_model }),
      plugin: [...new Set([...(config.plugin ?? []), ...(settings.plugin ?? []).map(resolveSpec)])],
      provider: { ...(config.provider ?? {}), ...providers },
    }
  })().catch((cause) => new Error('Could not load the installation runtime profile; backend startup was stopped.', { cause })))
}
