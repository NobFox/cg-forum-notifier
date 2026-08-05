# Copy this file to  local-secrets.ps1  and fill in your TEST SERVER values.
# local-secrets.ps1 is gitignored and must never be committed.
# On GitHub Actions these same variables come from repo Secrets instead.

$env:WEBHOOK_PROMOS = 'https://discord.com/api/webhooks/xxx/yyy'   # test server promos channel
$env:WEBHOOK_NEWS   = 'https://discord.com/api/webhooks/xxx/zzz'   # test server news channel
$env:ROLE_CHALLENGE = ''    # test server role ID, or '' for no ping
$env:ROLE_ANNOUNCE  = ''
