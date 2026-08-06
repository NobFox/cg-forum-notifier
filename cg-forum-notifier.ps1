#Requires -Version 5.1
<#
    CryptoGames Forum -> Discord Webhook Notifier  (v2)
    ---------------------------------------------------
    Polls Invision Community RSS board feeds and posts new topics to a
    Discord webhook as embeds (MonitoRSS-style cards).

    v2 changes:
      - All XML fields read via .InnerText (fixes "System.Xml.XmlElement"
        titles and missing images caused by CDATA/attributed nodes)
      - $MaxPostsPerRun flood guard: excess new items are seeded silently
      - $PSScriptRoot fallback for console/ISE runs

    Schedule:
      Local  - Task Scheduler, every 5-10 min:
        powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\cg-forum-notifier.ps1"
      Hosted - GitHub Actions (see .github/workflows/notifier.yml); secrets come
        from env vars WEBHOOK_PROMOS / WEBHOOK_NEWS / ROLE_CHALLENGE / ROLE_ANNOUNCE,
        and seen_posts.json is committed back to the repo to survive the runner.

    First run seeds seen_posts.json WITHOUT posting anything.
#>

# ═══════════════════════════ CONFIG ═══════════════════════════

# Base folder for state/log/local-secrets. Fallback covers console-paste runs
# where $PSScriptRoot is empty.
$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Secrets come from environment variables:
#   - On GitHub Actions, from repo Secrets (set in the workflow's env: block)
#   - Locally, from local-secrets.ps1 sitting next to this script (gitignored)
# Nothing sensitive is ever stored in this file.
$localSecrets = Join-Path $baseDir 'local-secrets.ps1'
if (Test-Path $localSecrets) { . $localSecrets }

$WebhookPromos = $env:WEBHOOK_PROMOS
$WebhookNews   = $env:WEBHOOK_NEWS

# Roles to ping (numeric IDs - right-click role with Developer Mode on > Copy Role ID). '' = no ping.
$RoleChallenge = $env:ROLE_CHALLENGE   # @Challenge Notifications
$RoleAnnounce  = $env:ROLE_ANNOUNCE    # @Announcements

# Each feed declares its destination webhook (= channel), which role to ping,
# and its intro line. {role} in Intro is replaced with the ping mention.
# Leave Intro '' for no message text above the card.
#
# Any card text below can also be overridden per feed - just add the key.
# Omit a key and the feed uses the global default further down:
#   AuthorName, AuthorIcon, Blurb, OutroTitle, Outro, FooterText, FooterIcon, EmbedColor
# Set Outro = ' ' (or OutroTitle = ' ') to suppress that block entirely.
$Feeds = @(
    @{
        Name       = 'Daily Promotions'
        Url        = 'https://forum.crypto.games/forum/5-daily-promotions.xml'
        Webhook    = $WebhookPromos
        PingRoleId = $RoleChallenge
        Intro      = 'A new event is starting, {role}!'
    }
    @{
        Name       = 'Special Promotions'
        Url        = 'https://forum.crypto.games/forum/12-special-promotions.xml'
        Webhook    = $WebhookPromos
        PingRoleId = $RoleChallenge
        Intro      = 'A special event is coming soon, {role}!'
    }
    @{
        Name       = 'Announcements'
        Url        = 'https://forum.crypto.games/forum/15-site-announcements.xml'
        Webhook    = $WebhookNews
        PingRoleId = $RoleAnnounce
        Intro      = 'New announcement for {role}:'
        AuthorName = 'New Announcement'
        Blurb      = 'A new site announcement has been posted. Read the full thread for details.'
        OutroTitle = 'Site Announcements'
        Outro      = 'Keep an eye on the announcements board for the latest site news and updates.'
    }
)

$BotName    = 'CryptoGames Promotions'
$BotAvatar  = 'https://raw.githubusercontent.com/NobFox/flow-assets/main/CG-logo.png'

# Global defaults - used by any feed that doesn't override the matching key above
$DefaultAuthorName = 'New Event Starting Soon!'
$DefaultAuthorIcon = 'https://content.invisioncic.com/c309237/monthly_2022_03/daily-promo.png.4e3f0b0962a6e309f70d44da3d377103.png'
$DefaultBlurb      = 'A new event is starting soon. Be sure to look through the thread for the full description and rules.'
$DefaultOutroTitle = 'Promotions'
$DefaultOutro      = 'Remember to check our promotions page on the forum for a view of all our current planned daily events.'
$DefaultFooterText = 'Catch the winning spirit!'
$DefaultFooterIcon = 'https://cdn.discordapp.com/emojis/753003323933851748.gif'
$DefaultEmbedColor = 15105570

$MaxPostsPerRun = 5      # flood guard: extra new items are marked seen without posting
$MaxSeenIds     = 500    # cap state file growth

# ══════════════════════════════════════════════════════════════

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Fail fast rather than silently doing nothing if secrets aren't configured
$missing = $Feeds | Where-Object { -not $_.Webhook } | ForEach-Object { $_.Name }
if ($missing) {
    throw "No webhook URL configured for: $($missing -join ', '). Set the env vars (GitHub Secrets) or create local-secrets.ps1 next to this script."
}

$StateFile = Join-Path $baseDir 'seen_posts.json'
$LogFile   = Join-Path $baseDir 'notifier.log'

function Write-Log {
    param([string]$Message)
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line   # also surfaces in the GitHub Actions run log
}

function Get-ItemText {
    # Always returns the text content of a child element, regardless of
    # whether PowerShell's XML adapter would surface it as string or XmlElement.
    param([System.Xml.XmlElement]$Item, [string]$Name)
    $node = $Item[$Name]
    if ($null -ne $node) { return $node.InnerText.Trim() }
    return $null
}

function Get-FirstImageUrl {
    param([string]$Html)
    if ($Html -and $Html -match '<img[^>]+src="([^"]+)"') {
        $src = $Matches[1]
        if ($src.StartsWith('//')) { $src = 'https:' + $src }   # protocol-relative fix
        return $src
    }
    return $null
}

function Get-FeedValue {
    # Per-feed override if the key is present and non-empty, else the global default
    param([hashtable]$Feed, [string]$Key, $Default)
    if ($Feed.ContainsKey($Key) -and $Feed[$Key]) { return $Feed[$Key] }
    return $Default
}

function Send-DiscordEmbed {
    param([hashtable]$Post, [hashtable]$Feed)

    $authorName = Get-FeedValue $Feed 'AuthorName' $DefaultAuthorName
    $authorIcon = Get-FeedValue $Feed 'AuthorIcon' $DefaultAuthorIcon
    $blurb      = Get-FeedValue $Feed 'Blurb'      $DefaultBlurb
    $outroTitle = Get-FeedValue $Feed 'OutroTitle' $DefaultOutroTitle
    $outro      = Get-FeedValue $Feed 'Outro'      $DefaultOutro
    $footerText = Get-FeedValue $Feed 'FooterText' $DefaultFooterText
    $footerIcon = Get-FeedValue $Feed 'FooterIcon' $DefaultFooterIcon
    $embedColor = Get-FeedValue $Feed 'EmbedColor' $DefaultEmbedColor

    $embed = @{
        author      = @{ name = $authorName; icon_url = $authorIcon }
        title       = $Post.Title
        url         = $Post.Link
        description = "$blurb`n`n$($Post.Link)"
        color       = $embedColor
        footer      = @{ text = $footerText; icon_url = $footerIcon }
    }
    # Whitespace-only Outro/OutroTitle = suppress the block
    if ($outro.Trim() -and $outroTitle.Trim()) {
        $embed.fields = @(@{ name = $outroTitle; value = $outro })
    }
    if ($Post.ImageUrl) { $embed.image = @{ url = $Post.ImageUrl } }

    $payloadHash = @{ username = $BotName; embeds = @($embed) }
    if ($BotAvatar) { $payloadHash.avatar_url = $BotAvatar }

    if ($Feed.Intro) {
        $mention = if ($Feed.PingRoleId) { "<@&$($Feed.PingRoleId)>" } else { '' }
        $payloadHash.content = ($Feed.Intro -replace '\{role\}', $mention).Trim()
        # allowed_mentions: only the declared role can ping; nothing else in the
        # text (or a post title echoed anywhere) can trigger accidental mentions
        $payloadHash.allowed_mentions = if ($Feed.PingRoleId) {
            @{ parse = @(); roles = @($Feed.PingRoleId) }
        } else {
            @{ parse = @() }
        }
    }

    $payload = $payloadHash | ConvertTo-Json -Depth 6
    $body    = [System.Text.Encoding]::UTF8.GetBytes($payload)   # emoji-safe on PS 5.1 and 7

    Invoke-RestMethod -Uri $Feed.Webhook -Method Post -ContentType 'application/json' -Body $body | Out-Null
}

# ─── Load state ───
$firstRun = -not (Test-Path $StateFile)
[System.Collections.Generic.List[string]]$seen = @()
if (-not $firstRun) {
    try {
        $loaded = @(Get-Content $StateFile -Raw | ConvertFrom-Json) | Where-Object { $_ }
        if ($loaded.Count -gt 0) { $seen.AddRange([string[]]$loaded) }
        else { Write-Log 'WARN: state file was empty - treating as first run (seed only)'; $firstRun = $true }
    }
    catch { Write-Log 'WARN: state file unreadable - treating as first run (seed only)'; $firstRun = $true }
}

$posted = 0

foreach ($feed in $Feeds) {
    try {
        $resp = Invoke-WebRequest -Uri $feed.Url -UseBasicParsing -TimeoutSec 30
        [xml]$rss = $resp.Content
    }
    catch {
        Write-Log "ERROR fetching $($feed.Name): $($_.Exception.Message)"
        continue
    }

    $items = @($rss.rss.channel.item)
    if ($items.Count -eq 0) { Write-Log "WARN: $($feed.Name) returned no items"; continue }

    # Collect unseen items, oldest-first so the channel reads chronologically
    [array]::Reverse($items)
    $unseen = foreach ($item in $items) {
        $guid = Get-ItemText $item 'guid'
        if ($guid -and -not $seen.Contains($guid)) {
            [pscustomobject]@{ Item = $item; Guid = $guid }
        }
    }
    $unseen = @($unseen)
    if ($unseen.Count -eq 0) { continue }

    # First run, or a newly added feed (zero overlap with seen list): seed silently
    if ($firstRun -or $unseen.Count -eq $items.Count) {
        if (-not $firstRun) { Write-Log "New feed detected ($($feed.Name)) - seeded $($unseen.Count) existing posts silently" }
        foreach ($u in $unseen) { $seen.Add($u.Guid) }
        continue
    }

    # Flood guard: seed everything except the newest $MaxPostsPerRun
    if ($unseen.Count -gt $MaxPostsPerRun) {
        $excess = $unseen.Count - $MaxPostsPerRun
        Write-Log "WARN: $($unseen.Count) new items on $($feed.Name) - seeding oldest $excess silently, posting newest $MaxPostsPerRun"
        foreach ($u in $unseen[0..($excess - 1)]) { $seen.Add($u.Guid) }
        $unseen = @($unseen[$excess..($unseen.Count - 1)])
    }

    foreach ($u in $unseen) {
        $item = $u.Item

        $post = @{
            Title    = Get-ItemText $item 'title'
            Link     = Get-ItemText $item 'link'
            ImageUrl = Get-FirstImageUrl -Html (Get-ItemText $item 'description')
        }

        try {
            Send-DiscordEmbed -Post $post -Feed $feed
            $seen.Add($u.Guid)
            $posted++
            Write-Log "Posted: [$($feed.Name)] $($post.Title) (guid $($u.Guid))"
            Start-Sleep -Milliseconds 750
        }
        catch {
            # Not marked seen - retries next run
            Write-Log "ERROR posting guid $($u.Guid): $($_.Exception.Message)"
        }
    }
}

# ─── Save state (keep newest N ids) ───
if ($seen.Count -gt $MaxSeenIds) {
    $seen = [System.Collections.Generic.List[string]]($seen | Select-Object -Last $MaxSeenIds)
}
ConvertTo-Json @($seen) | Set-Content -Path $StateFile -Encoding UTF8

if ($firstRun) { Write-Log "First run: seeded $($seen.Count) existing posts, nothing sent" }
elseif ($posted -gt 0) { Write-Log "Done: $posted new post(s) sent" }
