import json, pathlib, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='roadie-speaker-instructions-') as temp:
    directory = pathlib.Path(temp)
    config = directory / 'opencode.json'
    shared = '/site/wp-content/uploads/datamachine-files/shared/SITE.md'
    agent = '/site/wp-content/uploads/datamachine-files/agents/franklin/SOUL.md'
    user = '/site/wp-content/uploads/datamachine-files/users/1/USER.md'
    principal = '/site/wp-content/uploads/datamachine-files/agents/franklin/users/1/USER_MEMORY.md'
    custom = '/operator/USER.md'
    config.write_text(json.dumps({'instructions': [shared, agent, user, principal, custom], 'plugin': [], 'agent': {'general': {'model': 'operator/model'}}}))
    paths = directory / 'instructions'
    paths.write_text('\n'.join([shared, agent, user, principal]) + '\n')
    command = ['python3', str(root / 'lib/repair-opencode-json.py'), '--file', str(config), '--runtime', 'opencode', '--chat-bridge', 'roadie', '--roadie-plugins-dir', '/managed/plugins', '--managed-instructions-file', str(paths), '--speaker-context', '--additive', '--backup-dir', str(directory / 'backups')]
    subprocess.run(command, check=True, capture_output=True)
    result = json.loads(config.read_text())
    assert result['instructions'] == [shared, agent, custom], result['instructions']
    assert result['agent']['general']['model'] == 'operator/model'
    before = config.read_bytes()
    subprocess.run(command, check=True, capture_output=True)
    assert config.read_bytes() == before
print('PASS: speaker context removes only managed personal instructions; operator agent/config survives repeat reconciliation')
