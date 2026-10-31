# mutation-check.ps1  (v7)
# Mutation-testing harness for the webhook-gateway production SQL.
# Windows PowerShell 5.1.  PURE ASCII source.  No backtick line continuations.
# Run from an INTERACTIVE PowerShell session at the repo root (not via powershell -File):
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\mutation-check.ps1 -SelfTest                      validate harness invariants only (the run prints the count); no DB, no jest
#   .\mutation-check.ps1 -ListOnly                      pre-flight: anchors, before/after text; no writes, no runs
#   .\mutation-check.ps1 -Inspect -Only C02             deep inspection of ONE mutant
#   .\mutation-check.ps1 -GenerateOnly -Only B01        write sql\_mutants\B01.sql only
#   .\mutation-check.ps1 -Only C01,B01,S01              run a subset (baseline first)
#   .\mutation-check.ps1                                full run: baseline, generate, run, report
#   .\mutation-check.ps1 -CleanOrphans                  drop leftover whtest_* databases and exit
# Switches: -SelfTest -SkipBaseline -SkipBad -NoProbes -Strict -TimeoutSec N -GateTimeoutSec N -ContainerName NAME
# Exit codes: 0 ok | 1 baseline failed | 2 anchor/no-op/integrity abort | 3 usage | 4 -Strict gaps | 5 database unreachable
#
# ============================================================================
# HISTORY
# v4: fixed v3 crash ("Cannot index into a null array") by renaming the source
#     cache from $script:Src to $script:CachedSources, preventing the unqualified
#     $src variable (which shares scope with $script:Src under PowerShell's case-
#     insensitivity) from silently overwriting the hashtable across iterations.
# v5: added -SelfTest, KnownGapSuites, Get-MissingGapSuites, refined
#     MissingTestNotes to name the specific gap suite to create.
# v6:
#   1. Port auto-probe: $env:PGPORT -> 5433 -> 5432. v5 hardcoded 5432, which
#      silently broke environments that expose Postgres on 5433 (v4's default).
#   2. KnownGapSuites is now DERIVED from MissingTestNotes.Values via
#      "Test target: <suite>" -> never goes stale when notes change.
#   3. Get-MissingGapSuites uses strict regex "^(gap)(_\w+)?$" instead of
#      .Contains(), which could false-positive on "claim_basic_gaps_v2".
#   4. Contradictory flag combos are rejected up-front with exit code 3.
#   5. -SelfTest expanded from 4 to 9 invariants (see text below).
#   6. Format-MutantMatch() deduplicates the before/after rendering shared by
#      -Inspect and -ListOnly.
#   7. Shadow regex in SelfTest now catches "$script:src =" in addition to
#      "$src =", and the check is documented to be case-insensitive.
# v7 (this file):
#   F1. Resolve-PgPort now runs whenever the DB is needed (also with -SkipBaseline).
#   F3. Get-MissingGapSuites accepts an EXACT stem only (item 3 of v6 is superseded:
#       "claim_basic_gaps_v2" and any other suffix are NOT accepted).
#   F4. Show-RunFailure no longer prints migrate/prisma/seed hints.
#   F5. Port candidates are @(5433) only; $env:PGPORT remains the override; if nothing
#       answers, one message is printed and the script exits 5.
#   F6. Wait-Db prefers the docker health status of -ContainerName (only "healthy"
#       is accepted); it falls back to the TCP check when docker or a health status is absent.
#   F7. After every TIMEOUT the -CleanOrphans logic runs once (failures are ignored).
#   P1. -SelfTest rewritten: every invariant can fail; the invariant count is computed and printed.
# ============================================================================
#
# DESIGN
#  * Per mutant, TWO phases:  gate = smoke only;  domain = every other suite.
#    A mutant whose SQL breaks syntax/binding/permissions fails the gate -> INVALID, never a kill.
#  * Source files are normalized CRLF/CR -> LF before regex matching; mutants are written as LF UTF-8, no BOM.
#  * Every mutant is generated from a FRESH disk read, verified against the initial SHA-256 of the source.
#  * Known gap suites: derived from MissingTestNotes so the harness always reports the exact
#    .test.ts file the developer needs to create (or confirms it has been created).

param(
    [switch]$SelfTest,
    [switch]$ListOnly,
    [switch]$Inspect,
    [switch]$GenerateOnly,
    [switch]$SkipBaseline,
    [switch]$SkipBad,
    [switch]$NoProbes,
    [switch]$Strict,
    [switch]$CleanOrphans,
    [int]$TimeoutSec = 300,
    [int]$GateTimeoutSec = 120,
    [string]$ContainerName = 'wg_postgres',
    [string[]]$Only
)

Set-Location $PSScriptRoot
$ErrorActionPreference = 'Stop'
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# Static configuration
# ---------------------------------------------------------------------------

$script:GateSuite = 'smoke'
$script:DomainSuites = @('claim_basic','claim_fairness','claim_race','crash_recovery',
                         'claim_release_cycle','janitor','release_breaker','release_shutdown')

$script:EnvNames = @('CLAIM_SQL_FILE','JANITOR_SQL_FILE','RELEASE_BREAKER_SQL_FILE',
                     'RELEASE_SHUTDOWN_SQL_FILE','FORCE_COLOR')
$script:KnownSqlFiles = @('sql/claim.sql','sql/janitor.sql','sql/release_breaker.sql','sql/release_shutdown.sql')
$script:PgHost = '127.0.0.1'
$script:PgPort = 0  # 0 = unresolved; resolved by Resolve-PgPort during startup
$script:PgPortCandidates = @(5433)  # the tests read PGPORT (default 5433); $env:PGPORT remains the override

# ---------------------------------------------------------------------------
# Mutant registry
#   Add-Mutant Id File Intent Pattern Replacement Expected Probe
#   Pattern     : .NET regex; must match EXACTLY ONCE in the (LF-normalized) source, within at most 2 lines.
#   Replacement : .NET replacement string ($$ = literal dollar, ${1} = group 1). Always single-quoted.
#   Expected    : suite stems expected to kill it.
#   Probe       : exploratory mutant; survival is information, not an alarm.
# ---------------------------------------------------------------------------

$script:MutantList = New-Object System.Collections.ArrayList

function Add-Mutant {
    param([string]$Id, [string]$File, [string]$Intent, [string]$Pattern, [string]$Replacement, [string[]]$Expected, [bool]$Probe)
    $exp = @()
    if ($Expected) { $exp = @($Expected) }
    [void]$script:MutantList.Add([pscustomobject]@{
        Id = $Id; File = $File; Intent = $Intent
        Pattern = $Pattern; Replacement = $Replacement
        Expected = $exp; Probe = $Probe
    })
}

# ---- sql/claim.sql ----
Add-Mutant 'C01' 'sql/claim.sql' 'remove SKIP LOCKED' '(?i)FOR\s+UPDATE\s+SKIP\s+LOCKED' 'FOR UPDATE' @('claim_race') $false
Add-Mutant 'C02' 'sql/claim.sql' 'per-tenant cap 2 -> 10' '(?im)^([^\S\r\n]*)LIMIT\s+2(?![0-9.,])([^\r\n]*)' '${1}LIMIT 10${2}' @('claim_basic','claim_fairness') $false
Add-Mutant 'C03' 'sql/claim.sql' 'batch size 10 -> 100' '(?i)ORDER\s+BY\s+next_attempt_at\s*,\s*id\s+LIMIT\s+10(?![0-9.,])' 'ORDER BY next_attempt_at, id LIMIT 100' @('claim_basic') $false
Add-Mutant 'C04' 'sql/claim.sql' 'reclaim boundary <= -> <' '(?i)(d\.attempts\s*)<=(\s*d\.max_attempts)' '${1}<${2}' @('crash_recovery') $false
Add-Mutant 'C05' 'sql/claim.sql' 'reclaim_count bound 3 -> 100' '(?i)(d\.reclaim_count\s*<\s*)3(?![0-9.,])' '${1}100' @('crash_recovery') $false
Add-Mutant 'C06' 'sql/claim.sql' 'total_attempts not incremented' '(?i)(total_attempts\s*=\s*d\.total_attempts\s*\+\s*)1(\s*,)' '${1}0${2}' @('claim_basic','claim_release_cycle') $false
Add-Mutant 'C07' 'sql/claim.sql' 'attempts not incremented' '(?im)^([^\S\r\n]*)attempts(\s*=\s*d\.attempts\s*\+\s*)1(\s*,)' '${1}attempts${2}0${3}' @('claim_basic') $false
Add-Mutant 'C08' 'sql/claim.sql' 'lease_token = NULL on claim' '(?i)(lease_token\s*=\s*)gen_random_uuid\(\)' '${1}NULL' @('claim_basic') $false
Add-Mutant 'C09' 'sql/claim.sql' 'lock window 30s -> 5s' '(?i)(locked_until\s*=\s*now\(\)\s*\+\s*interval\s+)''30\s+seconds''' '${1}''5 seconds''' @('claim_basic') $false
Add-Mutant 'C10' 'sql/claim.sql' 'reclaim_count increment replaced by +0' '(?i)\+\s*CASE\s+WHEN\s+d\.status\s*=\s*''processing''\s+THEN\s+1\s+ELSE\s+0\s+END\s*,' '+ 0,' @('crash_recovery') $false
Add-Mutant 'C11' 'sql/claim.sql' 'pending budget guard loosened' '(?i)(d\.attempts\s*<\s*)(d\.max_attempts)' '${1}${2} + 100' @('claim_basic') $false
Add-Mutant 'C12' 'sql/claim.sql' 'LATERAL reclaims unexpired leases' '(?i)(d\.locked_until\s*<\s*now\(\))(?!\s*\+)' '${1} + interval ''1 hour''' @('claim_basic') $false
Add-Mutant 'C13' 'sql/claim.sql' 'active_tenants forgets expired processing' '(?im)^[^\S\r\n]*OR\s*\(status\s*=\s*''processing''\s+AND\s+locked_until\s*<\s*now\(\)\)' '' @('crash_recovery') $false
Add-Mutant 'C14' 'sql/claim.sql' 'SET status = pending instead of processing' '(?im)^([^\S\r\n]*)SET\s+status\s*=\s*''processing''' '${1}SET status = ''pending''' @('claim_basic') $false
Add-Mutant 'C15' 'sql/claim.sql' 'paused rows claimable' '(?i)\(d\.status\s*=\s*''pending''' '(d.status IN (''pending'',''paused'')' @('claim_basic_gaps') $false
Add-Mutant 'C16' 'sql/claim.sql' 'outer ordering: oldest first -> by id' '(?i)ORDER\s+BY\s+next_attempt_at\s*,\s*id\s+LIMIT\s+10(?![0-9.,])' 'ORDER BY id LIMIT 10' @('claim_basic_gaps') $false
Add-Mutant 'C17' 'sql/claim.sql' 'LATERAL ordering: oldest first -> by id' '(?i)ORDER\s+BY\s+d\.next_attempt_at\s*,\s*d\.id' 'ORDER BY d.id' @('claim_basic_gaps') $false
Add-Mutant 'C18' 'sql/claim.sql' 'LATERAL ignores the tenant' '(?i)WHERE\s+d\.tenant_id\s*=\s*at\.tenant_id' 'WHERE true' @('claim_basic','claim_fairness') $false
Add-Mutant 'C19' 'sql/claim.sql' 'PROBE LATERAL due check loosened by 1h' '(?i)(AND\s+d\.next_attempt_at\s*<=\s*now\(\))(?!\s*\+)' '${1} + interval ''1 hour''' @() $true
Add-Mutant 'C20' 'sql/claim.sql' 'PROBE updated_at not touched by claim' '(?im)^([^\S\r\n]*)updated_at\s*=\s*now\(\)' '${1}updated_at = d.updated_at' @() $true
Add-Mutant 'C21' 'sql/claim.sql' 'PROBE RETURNING drops total_attempts' '(?i)d\.attempts\s*,\s*d\.total_attempts\s*,\s*d\.max_attempts\s*,\s*d\.reclaim_count\s*;' 'd.attempts, d.max_attempts, d.reclaim_count;' @() $true

# ---- sql/janitor.sql ----
Add-Mutant 'J01' 'sql/janitor.sql' 'drop reclaim_count >= 3 branch' '(?i)\(reclaim_count\s*>=\s*3\s+OR\s+attempts\s*>\s*max_attempts\)' '(attempts > max_attempts)' @('janitor','crash_recovery') $false
Add-Mutant 'J02' 'sql/janitor.sql' 'drop attempts > max_attempts branch' '(?i)\(reclaim_count\s*>=\s*3\s+OR\s+attempts\s*>\s*max_attempts\)' '(reclaim_count >= 3)' @('janitor') $false
Add-Mutant 'J03' 'sql/janitor.sql' 'expiry window pushed back one day' '(?i)(AND\s+locked_until\s*<\s*now\(\))' '${1} - interval ''1 day''' @('janitor','crash_recovery') $false
Add-Mutant 'J04' 'sql/janitor.sql' 'status dlq -> pending' '(?im)^([^\S\r\n]*)SET\s+status\s*=\s*''dlq''' '${1}SET status = ''pending''' @('janitor') $false
Add-Mutant 'J05' 'sql/janitor.sql' 'lease_token not cleared' '(?i)(lease_token\s*=\s*)NULL' '${1}lease_token' @('janitor_gaps') $false
Add-Mutant 'J06' 'sql/janitor.sql' 'expiry window pushed forward one day' '(?i)(AND\s+locked_until\s*<\s*now\(\))' '${1} + interval ''1 day''' @('janitor') $false
Add-Mutant 'J07' 'sql/janitor.sql' 'COALESCE removed' '(?i)COALESCE\(\s*last_error\s*,\s*''janitor:\s*stuck\s+row''\)' '''janitor: stuck row''' @('janitor') $false
Add-Mutant 'J08' 'sql/janitor.sql' 'status filter expanded to pending' '(?im)^([^\S\r\n]*)WHERE\s+status\s*=\s*''processing''' '${1}WHERE status IN (''processing'',''pending'')' @('janitor_gaps') $false
Add-Mutant 'J09' 'sql/janitor.sql' 'locked_until not cleared' '(?im)^([^\S\r\n]*)locked_until\s*=\s*NULL' '${1}locked_until = locked_until' @('janitor','janitor_gaps') $false

# ---- sql/release_breaker.sql ----
Add-Mutant 'B01' 'sql/release_breaker.sql' 'remove lease_token fence' '(?im)(AND\s+)(?:\w+\.)?lease_token\s*=\s*(\$\d+)' '${1}(${2}::uuid IS NULL OR TRUE)' @('release_breaker','claim_release_cycle') $false
Add-Mutant 'B02' 'sql/release_breaker.sql' 'attempts not decremented' '(?im)^([^\S\r\n]*)attempts(\s*=\s*attempts\s*-\s*)1' '${1}attempts${2}0' @('release_breaker') $false
Add-Mutant 'B03' 'sql/release_breaker.sql' 'total_attempts not decremented' '(?im)^([^\S\r\n]*)total_attempts(\s*=\s*total_attempts\s*-\s*)1' '${1}total_attempts${2}0' @('release_breaker') $false
Add-Mutant 'B04' 'sql/release_breaker.sql' 'next_attempt_at = now() (no +30s)' '(?i)(next_attempt_at\s*=\s*)now\(\)\s*\+\s*interval\s+''30\s+seconds''' '${1}now()' @('release_breaker') $false
Add-Mutant 'B05' 'sql/release_breaker.sql' 'status pending -> processing' '(?im)^([^\S\r\n]*)SET\s+status\s*=\s*''pending''' '${1}SET status = ''processing''' @('release_breaker') $false
Add-Mutant 'B06' 'sql/release_breaker.sql' 'lease_token not cleared' '(?i)(lease_token\s*=\s*)NULL' '${1}lease_token' @('release_breaker') $false
Add-Mutant 'B07' 'sql/release_breaker.sql' 'locked_until not cleared' '(?i)(locked_until\s*=\s*)NULL' '${1}locked_until' @('release_breaker') $false

# ---- sql/release_shutdown.sql ----
Add-Mutant 'S01' 'sql/release_shutdown.sql' 'remove lease_token fence' '(?im)(AND\s+)(?:\w+\.)?lease_token\s*=\s*(\$\d+)' '${1}(${2}::uuid IS NULL OR TRUE)' @('release_shutdown','claim_release_cycle') $false
Add-Mutant 'S02' 'sql/release_shutdown.sql' 'attempts not decremented' '(?im)^([^\S\r\n]*)attempts(\s*=\s*attempts\s*-\s*)1' '${1}attempts${2}0' @('release_shutdown') $false
Add-Mutant 'S03' 'sql/release_shutdown.sql' 'total_attempts not decremented' '(?im)^([^\S\r\n]*)total_attempts(\s*=\s*total_attempts\s*-\s*)1' '${1}total_attempts${2}0' @('release_shutdown') $false
Add-Mutant 'S04' 'sql/release_shutdown.sql' 'next_attempt_at now -> +1h' '(?i)(next_attempt_at\s*=\s*)now\(\)(?!\s*\+)' '${1}now() + interval ''1 hour''' @('release_shutdown') $false
Add-Mutant 'S05' 'sql/release_shutdown.sql' 'status pending -> processing' '(?im)^([^\S\r\n]*)SET\s+status\s*=\s*''pending''' '${1}SET status = ''processing''' @('release_shutdown') $false
Add-Mutant 'S06' 'sql/release_shutdown.sql' 'lease_token not cleared' '(?i)(lease_token\s*=\s*)NULL' '${1}lease_token' @('release_shutdown') $false

$mutants = @($script:MutantList.ToArray())

# MissingTestNotes doubles as the source of truth for "which gap suite is missing".
# Each note may contain "Test target: <suite>"; v6 parses these to derive
# $script:KnownGapSuites automatically. Updating a note updates the harness.
$script:MissingTestNotes = @{
    'C15' = 'No test puts a due paused row in the SAME tenant as a due pending row (separate tenants never reach the LATERAL filter). Test target: claim_basic_gaps.'
    'C16' = 'No test asserts that the 10 rows picked across tenants are the OLDEST ones. Test target: claim_basic_gaps.'
    'C17' = 'No test asserts that the 2 rows picked inside one tenant are the OLDEST ones. Test target: claim_basic_gaps.'
    'C19' = 'No test puts a not-yet-due pending row in the SAME tenant as a due one (active_tenants gates tenant selection).'
    'C20' = 'updated_at is not asserted anywhere.'
    'C21' = 'The RETURNING column list is not asserted; the dispatcher will depend on total_attempts, attempts and max_attempts.'
    'J05' = 'The janitor test never seeds a lease_token, so clearing it is unobservable. Test target: janitor_gaps.'
    'J08' = 'No test gives the janitor a PENDING row with an expired locked_until and exceeded counters. Test target: janitor_gaps.'
    'J09' = 'No test asserts that locked_until is cleared by the janitor.'
}

# Auto-derived gap suite list. Never hardcode again.
$script:KnownGapSuites = @(
    $script:MissingTestNotes.Values |
    ForEach-Object {
        $mm = [regex]::Match($_, 'Test target:\s*([a-z_][a-z0-9_]*)')
        if ($mm.Success) { $mm.Groups[1].Value }
    } |
    Select-Object -Unique
)
# ---------------------------------------------------------------------------
# Helpers: text and files
# ---------------------------------------------------------------------------

function ConvertTo-Ascii {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text -replace '[^\x20-\x7E]', '?')
}

function Read-Utf8File {
    param([string]$Path)
    $raw = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot $Path), [System.Text.Encoding]::UTF8)
    $raw = $raw.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    $raw = $raw.Replace([string][char]0x00A0, ' ')
    $raw = $raw.Replace([string][char]0x2007, ' ')
    $raw = $raw.Replace([string][char]0x202F, ' ')
    $raw = $raw.Replace([string][char]0x2003, ' ')
    $raw = $raw.Replace([string][char]0x2002, ' ')
    return $raw
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $full = Join-Path $PSScriptRoot $Path
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Sha256Hex {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $Path))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-GitHead {
    try {
        $out = & cmd.exe /c 'git rev-parse --short HEAD 2>nul'
        if ($LASTEXITCODE -eq 0 -and $out) { return ([string]($out | Select-Object -First 1)).Trim() }
    } catch { }
    return 'unknown'
}

function Get-CachedSource {
    param([string]$Path)
    if ($null -eq $script:CachedSources) {
        throw ('FATAL: $script:CachedSources is null (script-level corruption).')
    }
    if (-not $script:CachedSources.ContainsKey($Path)) {
        throw ('FATAL: no cached source for ''' + $Path + '''. Known keys: ' + (($script:CachedSources.Keys | Sort-Object) -join ', '))
    }
    $text = $script:CachedSources[$Path]
    if ($null -eq $text) {
        throw ('FATAL: cached source for ''' + $Path + ''' is null. Re-read the file.')
    }
    return [string]$text
}

function Test-OwnSourceAscii {
    if (-not $PSCommandPath) { return }
    $bytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    $line = 1
    $badLines = @()
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 10) { $line++ }
        elseif ($b -gt 127) { if ($badLines -notcontains $line) { $badLines += $line } }
    }
    if ($badLines.Count -gt 0) {
        Write-Host ('WARNING: non-ASCII bytes in this script at line(s): ' + (($badLines | Select-Object -First 10) -join ', '))
        Write-Host '         Re-copy the file; PowerShell 5.1 may misread it.'
    }
}

function Get-LineNumber {
    param([string]$Text, [int]$Index)
    $line = 1
    $cap = [Math]::Min($Index, $Text.Length)
    for ($i = 0; $i -lt $cap; $i++) { if ($Text[$i] -eq [char]10) { $line++ } }
    return $line
}

function Get-MatchLine {
    param([string]$Text, [int]$Index)
    if ($Index -lt 0 -or $Index -ge $Text.Length) { return '' }
    $ls = 0
    if ($Index -gt 0) { $ls = $Text.LastIndexOf([char]10, $Index - 1) + 1 }
    $le = $Text.IndexOf([char]10, $Index)
    if ($le -lt 0) { $le = $Text.Length }
    return $Text.Substring($ls, $le - $ls)
}

function Find-NearestLine {
    param([string]$Text, [string]$Pattern)
    $kw = [regex]::Match($Pattern, '[A-Za-z_]{4,}')
    if (-not $kw.Success) { return '' }
    $idx = $Text.IndexOf($kw.Value, [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -lt 0) { return '' }
    return (Get-MatchLine $Text $idx)
}

function Get-AnchorProblem {
    param($M, [string]$Source)
    $hits = [regex]::Matches($Source, $M.Pattern)
    if ($hits.Count -ne 1) { return ('match count = ' + $hits.Count + ' (expected exactly 1)') }
    $nl = $hits[0].Value.Split([char]10).Count - 1
    if ($nl -gt 1) { return ('match spans ' + ($nl + 1) + ' lines (maximum is 2)') }
    return ''
}

# Shared renderer for -Inspect and -ListOnly. Returns before, after, and no-op flag.
function Format-MutantMatch {
    param($Match, [string]$Replacement)
    $before = (ConvertTo-Ascii $Match.Value) -replace '\s+', ' '
    $after = (ConvertTo-Ascii ($Match.Result($Replacement))) -replace '\s+', ' '
    if ($after.Trim() -eq '') { $after = '(empty)' }
    $b = $before.Trim()
    $a = $after.Trim()
    return [pscustomobject]@{
        Before = $b
        After  = $a
        IsNoOp = ($b -eq $a)
    }
}

# ---------------------------------------------------------------------------
# Helpers: environment, database, jest
# ---------------------------------------------------------------------------

function Clear-MutantEnv {
    foreach ($n in $script:EnvNames) { [Environment]::SetEnvironmentVariable($n, $null, 'Process') }
}

function Set-MutantEnv {
    param([string]$SourceFile, [string]$RelMutant)
    Clear-MutantEnv
    $name = ''
    switch ($SourceFile) {
        'sql/claim.sql'            { $name = 'CLAIM_SQL_FILE' }
        'sql/janitor.sql'          { $name = 'JANITOR_SQL_FILE' }
        'sql/release_breaker.sql'  { $name = 'RELEASE_BREAKER_SQL_FILE' }
        'sql/release_shutdown.sql' { $name = 'RELEASE_SHUTDOWN_SQL_FILE' }
        default { throw ('Set-MutantEnv: unknown source file ' + $SourceFile) }
    }
    [Environment]::SetEnvironmentVariable($name, $RelMutant, 'Process')
    [Environment]::SetEnvironmentVariable('FORCE_COLOR', '0', 'Process')
}

function Test-PortOpen {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($ar)
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# v7 (F1, F5): $env:PGPORT overrides; otherwise only the candidates are probed (5433).
# Returns the port, or 0 after printing ONE clear message. The caller exits 5 on 0.
function Resolve-PgPort {
    param([string]$HostName, [int[]]$Candidates)
    if ($env:PGPORT) {
        $parsed = 0
        $okParse = [int]::TryParse($env:PGPORT, [ref]$parsed)
        if ((-not $okParse) -or $parsed -lt 1 -or $parsed -gt 65535) {
            Write-Host ('PGPORT is not a valid port number: ' + (ConvertTo-Ascii $env:PGPORT))
            return 0
        }
        Write-Host ('Postgres port: ' + $parsed + ' (from $env:PGPORT)')
        return $parsed
    }
    foreach ($cand in $Candidates) {
        if (Test-PortOpen $HostName $cand 1500) {
            Write-Host ('Postgres port: ' + $cand + ' (auto-detected; candidates tried: ' + ($Candidates -join ',') + ')')
            return $cand
        }
    }
    Write-Host ('No Postgres answered on ' + $HostName + ' port ' + ($Candidates -join ',') + '. Start it with: docker compose up -d --wait   (or set $env:PGPORT to the right port).')
    return 0
}

function Test-DockerAvailable {
    try { return ($null -ne (Get-Command 'docker' -ErrorAction SilentlyContinue)) } catch { return $false }
}

# v7 (F6): container health status through the docker CLI. Returns '' when docker is
# missing, the container does not exist, or it has no health status. Never throws.
function Get-ContainerHealth {
    param([string]$Name)
    try {
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$') { return '' }
        $out = & cmd.exe /c ('docker inspect --format {{.State.Health.Status}} ' + $Name + ' 2>nul')
        if ($LASTEXITCODE -ne 0) { return '' }
        $first = ($out | Select-Object -First 1)
        if ($null -eq $first) { return '' }
        return ([string]$first).Trim()
    } catch {
        return ''
    }
}

# v7 (F6): when docker reports a health status, only "healthy" is accepted (and the
# published port must also answer). Without a health status, the TCP check alone decides.
function Wait-Db {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $health = Get-ContainerHealth $ContainerName
        if ($health -eq '' -or $health -eq 'healthy') {
            if (Test-PortOpen $script:PgHost $script:PgPort 1500) { return $true }
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-CleanOrphans {
    Write-Host ('Listing leftover whtest_* databases through docker exec ' + $ContainerName + ' ...')
    $names = & docker exec $ContainerName psql -U postgres -d postgres -t -A -c "SELECT datname FROM pg_database WHERE datname LIKE 'whtest%'"
    if ($LASTEXITCODE -ne 0) { Write-Host 'docker exec failed; is the container running and is the name right (-ContainerName)?'; return }
    $dropped = 0
    foreach ($n in @($names)) {
        $name = ([string]$n).Trim()
        if ($name -match '^whtest_[0-9a-z_]+$') {
            & docker exec $ContainerName psql -U postgres -d postgres -c ('DROP DATABASE IF EXISTS ' + $name + ' WITH (FORCE)') | Out-Null
            Write-Host ('  dropped ' + $name)
            $dropped++
        }
    }
    Write-Host ('Dropped ' + $dropped + ' database(s).')
}

# v7 (F7): used once after every TIMEOUT. Reuses Invoke-CleanOrphans; a failure here never aborts the run.
function Invoke-CleanOrphansSafe {
    try {
        if (-not (Test-DockerAvailable)) { return }
        Invoke-CleanOrphans
    } catch {
        Write-Host ('  cleanup after TIMEOUT failed (ignored): ' + (ConvertTo-Ascii $_.Exception.Message))
    }
}

function Get-SuiteStem {
    param([string]$Path)
    $stem = $Path
    try { $stem = [System.IO.Path]::GetFileNameWithoutExtension($Path) } catch { }
    return ($stem -replace '\.test$', '')
}

function Get-DomainStems {
    $dir = Join-Path $PSScriptRoot 'tests\integration'
    $stems = @()
    foreach ($f in (Get-ChildItem -Path $dir -Filter '*.test.ts')) {
        $stem = $f.BaseName -replace '\.test$', ''
        foreach ($s in $script:DomainSuites) {
            if ($stem.Contains($s)) { $stems += $stem; break }
        }
    }
    return @($stems | Select-Object -Unique)
}

# v7 (F3): EXACT stem match only (ordinal, case-insensitive because Windows file names are).
# "claim_basic_gaps" is satisfied by the stem "claim_basic_gaps" and by nothing else:
# "claim_basic_gaps_v2" (or any other suffix or prefix) is NOT accepted.
function Get-MissingGapSuites {
    param([string[]]$Discovered, [string[]]$KnownGaps)
    $missing = @()
    foreach ($gap in $KnownGaps) {
        $hit = $false
        foreach ($d in $Discovered) {
            if ([string]::Equals($d, $gap, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true; break }
        }
        if (-not $hit) { $missing += $gap }
    }
    return @($missing)
}

function Invoke-Jest {
    param([string[]]$Patterns, [int]$Seconds)
    $tmp = [System.IO.Path]::GetTempFileName()
    $cmdLine = 'npx jest --ci --testTimeout=20000 ' + ($Patterns -join ' ') + ' > "' + $tmp + '" 2>&1'
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmdLine -WorkingDirectory $PSScriptRoot -PassThru -NoNewWindow
    $timedOut = $false
    if (-not $proc.WaitForExit($Seconds * 1000)) {
        $timedOut = $true
        try { [void](& cmd.exe /c ('taskkill /T /F /PID ' + $proc.Id + ' >nul 2>&1')) } catch { }
        try { [void]$proc.WaitForExit(5000) } catch { }
    }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) } catch { $text = '' }
    try { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue } catch { }
    return [pscustomobject]@{ Text = $text; TimedOut = $timedOut }
}

function Parse-Jest {
    param([string]$Text)
    $passStems = @()
    $failStems = @()
    foreach ($mm in [regex]::Matches($Text, '(?m)^[ \t]*PASS[ \t]+(\S+)')) { $passStems += (Get-SuiteStem $mm.Groups[1].Value) }
    foreach ($mm in [regex]::Matches($Text, '(?m)^[ \t]*FAIL[ \t]+(\S+)')) { $failStems += (Get-SuiteStem $mm.Groups[1].Value) }
    $passStems = @($passStems | Select-Object -Unique)
    $failStems = @($failStems | Select-Object -Unique)

    $summary = ''
    $sm = [regex]::Match($Text, '(?m)^Tests:[ \t]+(.+?)[ \t]*\r?$')
    if ($sm.Success) { $summary = $sm.Groups[1].Value.Trim() }
    $failedCount = 0
    $fm = [regex]::Match($summary, '(\d+)[ \t]+failed')
    if ($fm.Success) { $failedCount = [int]$fm.Groups[1].Value }

    $names = @()
    foreach ($mm in [regex]::Matches($Text, '(?m)^[ \t]*\u25CF[ \t]+(.+?)[ \t]*\r?$')) {
        $n = $mm.Groups[1].Value.Trim()
        if ($n -notlike 'Test suite failed to run*') { $names += (ConvertTo-Ascii $n) }
    }
    $names = @($names | Select-Object -Unique)

    return [pscustomobject]@{
        PassStems    = $passStems
        FailStems    = $failStems
        Summary      = $summary
        FailedCount  = $failedCount
        FailingNames = $names
        FailedToRun  = [bool]($Text -match 'Test suite failed to run')
        NoTests      = [bool]($Text -match 'No tests found')
        EnvError     = [bool]($Text -match 'ECONNREFUSED|the database system is starting up|terminating connection due to administrator command')
    }
}

function Classify-Gate {
    param($Parsed, [bool]$TimedOut)
    $res = [pscustomobject]@{ Result = ''; Note = '' }
    if ($TimedOut) { $res.Result = 'TIMEOUT'; $res.Note = 'gate (smoke) timed out; process tree killed'; return $res }
    if ($Parsed.EnvError) { $res.Result = 'ERROR'; $res.Note = 'gate: database unreachable or restarting'; return $res }
    if ($Parsed.NoTests -or $Parsed.FailedToRun) { $res.Result = 'ERROR'; $res.Note = 'gate: smoke failed to run (load or compile error)'; return $res }
    if ($Parsed.Summary -eq '') { $res.Result = 'ERROR'; $res.Note = 'gate: no Tests: summary in the jest output'; return $res }
    $ran = ($Parsed.PassStems -contains $script:GateSuite) -or ($Parsed.FailStems -contains $script:GateSuite)
    if (-not $ran) { $res.Result = 'ERROR'; $res.Note = 'gate: smoke suite was not executed'; return $res }
    if ($Parsed.FailStems -contains $script:GateSuite) {
        $res.Result = 'INVALID'
        $res.Note = 'gate: smoke failed (mutant breaks SQL syntax, binding or permissions); not a kill'
        return $res
    }
    $res.Result = 'PASS'
    return $res
}

function Classify-Domain {
    param($Parsed, [bool]$TimedOut)
    $res = [pscustomobject]@{ Result = ''; KilledBy = @(); Note = '' }
    if ($TimedOut) { $res.Result = 'TIMEOUT'; $res.Note = 'domain run timed out; process tree killed'; return $res }
    if ($Parsed.EnvError) { $res.Result = 'ERROR'; $res.Note = 'database unreachable or restarting during the run; not a kill'; return $res }
    if ($Parsed.NoTests -or $Parsed.FailedToRun) { $res.Result = 'ERROR'; $res.Note = 'a suite failed to run (load or compile error); not a kill'; return $res }
    if ($Parsed.Summary -eq '') { $res.Result = 'ERROR'; $res.Note = 'no Tests: summary in the jest output'; return $res }
    $seen = @($Parsed.PassStems + $Parsed.FailStems | Select-Object -Unique)
    $missing = @($script:DomainStems | Where-Object { $seen -notcontains $_ })
    if ($missing.Count -gt 0) {
        $res.Result = 'ERROR'
        $res.Note = 'incomplete run, missing suites: ' + ($missing -join ',')
        return $res
    }
    if ($Parsed.FailStems.Count -gt 0 -or $Parsed.FailedCount -gt 0) {
        $res.Result = 'KILLED'
        $res.KilledBy = @($Parsed.FailStems)
        if ($Parsed.FailStems.Count -eq 0) { $res.Note = 'killer suite not identified in the output' }
        return $res
    }
    $res.Result = 'ALLPASS'
    return $res
}

function Get-Verdict {
    param($Row)
    switch ($Row.Result) {
        'KILLED' {
            if ($Row.Probe) { return 'PROBE-KILLED' }
            if ($Row.Expected.Count -eq 0) { return 'OK' }
            foreach ($k in $Row.KilledBy) { if ($Row.Expected -contains $k) { return 'OK' } }
            return 'OK-OTHER-KILLER'
        }
        'SURVIVED' {
            if ($Row.Probe) { return 'PROBE-SURVIVED' }
            return 'GAP'
        }
        default { return 'NOT-EVALUATED' }
    }
}

# v7 (F4): the migrate/prisma/seed hints are gone; every test file creates and migrates its own database.
function Show-RunFailure {
    param($Parsed, [string]$Title)
    Write-Host $Title
    Write-Host ('Tests: ' + $Parsed.Summary)
    foreach ($s in $Parsed.FailStems) { Write-Host ('  FAIL ' + $s) }
    foreach ($n in ($Parsed.FailingNames | Select-Object -First 10)) { Write-Host ('  * ' + $n) }
    if ($Parsed.EnvError) {
        Write-Host 'Hint: database not ready. If running in Docker:'
        Write-Host ('      docker compose up -d --wait   (then verify port ' + $script:PgPort + ' responds)')
    }
}
# ---------------------------------------------------------------------------
# Self-test invariants (v7). Each function returns the list of failure reasons;
# an empty list means PASS. No DB, no jest, no file writes.
# ---------------------------------------------------------------------------

function Test-Expect {
    param([System.Collections.ArrayList]$Issues, [string]$Label, $Actual, $Expected)
    $a = [string]$Actual
    $e = [string]$Expected
    if ($a -cne $e) { [void]$Issues.Add($Label + ': expected ''' + $e + ''' got ''' + $a + '''') }
}

# Invariant 1: registry hygiene.
function Test-InvRegistry {
    $issues = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($m in $mutants) {
        $id = [string]$m.Id
        if ($id -cnotmatch '^[CJBS][0-9]{2}$') { [void]$issues.Add('bad id format: ''' + $id + '''') }
        if ($seen.ContainsKey($id)) { [void]$issues.Add('duplicate id: ' + $id) }
        $seen[$id] = $true
        if ($script:KnownSqlFiles -cnotcontains $m.File) { [void]$issues.Add($id + ': unknown source file ''' + $m.File + '''') }
        if ([string]$m.Pattern -eq '') {
            [void]$issues.Add($id + ': empty pattern')
        } else {
            try { [void](New-Object System.Text.RegularExpressions.Regex([string]$m.Pattern)) }
            catch { [void]$issues.Add($id + ': pattern does not compile: ' + (ConvertTo-Ascii $_.Exception.Message)) }
        }
        if ($m.Probe -isnot [bool]) { [void]$issues.Add($id + ': Probe is not a boolean') }
        if (-not $m.Probe -and $m.Expected.Count -eq 0) { [void]$issues.Add($id + ': non-probe mutant has no Expected stems') }
        foreach ($e in $m.Expected) {
            if (($e -isnot [string]) -or ($e.Trim() -eq '')) { [void]$issues.Add($id + ': Expected contains an empty or non-string stem') }
        }
    }
    return $issues
}

# Invariant 2: anchors (exactly once, at most 2 lines, real change) plus synthetic checks of Get-AnchorProblem itself.
function Test-InvAnchors {
    $issues = New-Object System.Collections.ArrayList
    $nl = [string][char]10
    $cases = @(
        @('zero matches', 'ab', 'xyz', $true),
        @('two matches', 'ab', 'ab ab', $true),
        @('one match', 'ab', 'xab', $false),
        @('spans 3 lines', 'a\s+b\s+c', ('a' + $nl + 'b' + $nl + 'c'), $true),
        @('spans 2 lines', 'a\s+b', ('a' + $nl + 'b'), $false)
    )
    foreach ($c in $cases) {
        $fake = [pscustomobject]@{ Pattern = $c[1] }
        $prob = Get-AnchorProblem $fake $c[2]
        $rejected = ($prob -ne '')
        if ($rejected -ne $c[3]) {
            [void]$issues.Add('Get-AnchorProblem synthetic (' + $c[0] + '): rejected=' + $rejected + ' expected=' + $c[3])
        }
    }
    foreach ($m in $mutants) {
        try {
            $sourceText = Get-CachedSource $m.File
        } catch {
            [void]$issues.Add('cache access failed for ' + $m.Id + ': ' + (ConvertTo-Ascii $_.Exception.Message))
            continue
        }
        $problem = Get-AnchorProblem $m $sourceText
        if ($problem -ne '') { [void]$issues.Add('anchor ' + $m.Id + ': ' + $problem) }
        $mutated = [regex]::Replace($sourceText, $m.Pattern, $m.Replacement)
        if ($mutated -ceq $sourceText) { [void]$issues.Add('no-op mutant ' + $m.Id) }
    }
    return $issues
}

# Invariant 3: golden check of the dollar escape (B01 and S01 on the cached sources).
function Test-InvGolden {
    $issues = New-Object System.Collections.ArrayList
    $golden = '($2::uuid IS NULL OR TRUE)'
    foreach ($id in @('B01','S01')) {
        $m = $mutants | Where-Object { $_.Id -ceq $id } | Select-Object -First 1
        if ($null -eq $m) { [void]$issues.Add($id + ': not found in the registry'); continue }
        try {
            $text = Get-CachedSource $m.File
            $mutated = [regex]::Replace($text, $m.Pattern, $m.Replacement)
            if (-not $mutated.Contains($golden)) { [void]$issues.Add($id + ': mutated source does not contain ' + $golden) }
        } catch {
            [void]$issues.Add($id + ': ' + (ConvertTo-Ascii $_.Exception.Message))
        }
    }
    return $issues
}

# Invariant 4: environment mapping (no jest involved).
function Test-InvEnvMapping {
    $issues = New-Object System.Collections.ArrayList
    $overrides = @('CLAIM_SQL_FILE','JANITOR_SQL_FILE','RELEASE_BREAKER_SQL_FILE','RELEASE_SHUTDOWN_SQL_FILE')
    $pairs = @(
        @('sql/claim.sql', 'CLAIM_SQL_FILE'),
        @('sql/janitor.sql', 'JANITOR_SQL_FILE'),
        @('sql/release_breaker.sql', 'RELEASE_BREAKER_SQL_FILE'),
        @('sql/release_shutdown.sql', 'RELEASE_SHUTDOWN_SQL_FILE')
    )
    $rel = 'sql/_mutants/ZZ99.sql'
    try {
        foreach ($pair in $pairs) {
            $file = $pair[0]
            $want = $pair[1]
            Set-MutantEnv $file $rel
            $setNames = @()
            foreach ($n in $overrides) {
                if ([Environment]::GetEnvironmentVariable($n, 'Process')) { $setNames += $n }
            }
            if ($setNames.Count -ne 1 -or $setNames[0] -cne $want) {
                [void]$issues.Add('env ' + $file + ': expected only ' + $want + ' set, found [' + ($setNames -join ',') + ']')
            } else {
                Test-Expect $issues ('env ' + $file + ' value') ([Environment]::GetEnvironmentVariable($want, 'Process')) $rel
            }
            Test-Expect $issues ('env ' + $file + ' FORCE_COLOR') ([Environment]::GetEnvironmentVariable('FORCE_COLOR', 'Process')) '0'
            Clear-MutantEnv
            $left = @()
            foreach ($n in ($overrides + @('FORCE_COLOR'))) {
                if ([Environment]::GetEnvironmentVariable($n, 'Process')) { $left += $n }
            }
            if ($left.Count -gt 0) { [void]$issues.Add('after Clear-MutantEnv (' + $file + ') still set: ' + ($left -join ',')) }
        }
        $threw = $false
        try { Set-MutantEnv 'sql/unknown.sql' $rel } catch { $threw = $true }
        if (-not $threw) { [void]$issues.Add('Set-MutantEnv accepted an unknown source file') }
    } finally {
        Clear-MutantEnv
    }
    return $issues
}

# Synthetic jest outputs (ASCII, single-quoted here-strings). {BUL} is replaced by U+25CF built from a char code.
function Get-SelfTestFixtures {
    $fx = @{}
    $fx['a'] = @'
 PASS  tests/integration/smoke.test.ts (5.1 s)

Test Suites: 1 passed, 1 total
Tests:       5 passed, 5 total
'@
    $fx['b'] = @'
 FAIL  tests/integration/smoke.test.ts (4.2 s)
  {BUL} smoke > select 1

Test Suites: 1 failed, 1 total
Tests:       1 failed, 4 passed, 5 total
'@
    $fx['c'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)

Test Suites: 1 passed, 1 total
Tests:       4 passed, 4 total
'@
    $fx['d'] = @'
 FAIL  tests/integration/smoke.test.ts
  {BUL} Test suite failed to run

    Cannot find module '../src/db' from 'tests/integration/smoke.test.ts'

Test Suites: 1 failed, 1 total
Tests:       0 total
'@
    $fx['e'] = @'
 PASS  tests/integration/smoke.test.ts (5.1 s)
'@
    $fx['f'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)
 PASS  tests/integration/claim_race.test.ts (9.5 s)
 PASS  tests/integration/janitor.test.ts (2.0 s)

Test Suites: 3 passed, 3 total
Tests:       12 passed, 12 total
'@
    $fx['g'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)
 FAIL  tests/integration/claim_race.test.ts (64.107 s)
 PASS  tests/integration/janitor.test.ts (2.0 s)

  {BUL} claim_race > INV-RC-1: lease fence holds

Test Suites: 1 failed, 10 passed, 11 total
Tests:       3 failed, 52 passed, 55 total
'@
    $fx['h'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)
 PASS  tests/integration/janitor.test.ts (2.0 s)

Test Suites: 2 passed, 2 total
Tests:       8 passed, 8 total
'@
    $fx['i'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)
 FAIL  tests/integration/claim_race.test.ts (9.5 s)
 PASS  tests/integration/janitor.test.ts (2.0 s)

  {BUL} claim_race > INV-RC-1: lease fence holds

    connect ECONNREFUSED 127.0.0.1:5433

Test Suites: 1 failed, 2 passed, 3 total
Tests:       1 failed, 11 passed, 12 total
'@
    $fx['j'] = @'
No tests found, exiting with code 1
'@
    $fx['k'] = @'
 PASS  tests/integration/claim_basic.test.ts (3.0 s)
 PASS  tests/integration/claim_race.test.ts (9.5 s)
 PASS  tests/integration/janitor.test.ts (2.0 s)

Test Suites: 3 passed, 3 total
Tests:       2 failed, 10 passed, 12 total
'@
    $bul = [string][char]0x25CF
    $keys = @($fx.Keys)
    foreach ($k in $keys) { $fx[$k] = ([string]$fx[$k]).Replace('{BUL}', $bul) }
    return $fx
}

# Invariant 5: classifier fixtures (Parse-Jest -> Classify-Gate / Classify-Domain).
function Test-InvClassifier {
    $issues = New-Object System.Collections.ArrayList
    $fx = Get-SelfTestFixtures
    $savedStems = $script:DomainStems
    try {
        $script:DomainStems = @('claim_basic','claim_race','janitor')

        $r = Classify-Gate (Parse-Jest $fx['a']) $false
        Test-Expect $issues 'fixture a (gate: smoke passes)' $r.Result 'PASS'

        $r = Classify-Gate (Parse-Jest $fx['b']) $false
        Test-Expect $issues 'fixture b (gate: smoke fails)' $r.Result 'INVALID'

        $r = Classify-Gate (Parse-Jest $fx['c']) $false
        Test-Expect $issues 'fixture c (gate: smoke absent)' $r.Result 'ERROR'

        $r = Classify-Gate (Parse-Jest $fx['d']) $false
        Test-Expect $issues 'fixture d (gate: failed to run)' $r.Result 'ERROR'

        $r = Classify-Gate (Parse-Jest $fx['e']) $true
        Test-Expect $issues 'fixture e (gate: timed out)' $r.Result 'TIMEOUT'

        $r = Classify-Domain (Parse-Jest $fx['f']) $false
        Test-Expect $issues 'fixture f (domain: all pass)' $r.Result 'ALLPASS'

        $pg = Parse-Jest $fx['g']
        $r = Classify-Domain $pg $false
        Test-Expect $issues 'fixture g (domain: claim_race fails)' $r.Result 'KILLED'
        Test-Expect $issues 'fixture g KilledBy' (@($r.KilledBy) -join ',') 'claim_race'
        Test-Expect $issues 'fixture g failing name' (@($pg.FailingNames) -join '|') 'claim_race > INV-RC-1: lease fence holds'

        $r = Classify-Domain (Parse-Jest $fx['h']) $false
        Test-Expect $issues 'fixture h (domain: expected suite missing)' $r.Result 'ERROR'
        if ($r.Note -notlike '*claim_race*') { [void]$issues.Add('fixture h note does not name the missing suite claim_race: ''' + $r.Note + '''') }

        $r = Classify-Domain (Parse-Jest $fx['i']) $false
        Test-Expect $issues 'fixture i (domain: ECONNREFUSED text)' $r.Result 'ERROR'

        $r = Classify-Domain (Parse-Jest $fx['j']) $false
        Test-Expect $issues 'fixture j (domain: No tests found)' $r.Result 'ERROR'

        $r = Classify-Domain (Parse-Jest $fx['k']) $false
        Test-Expect $issues 'fixture k (domain: failures without a FAIL line)' $r.Result 'KILLED'
        Test-Expect $issues 'fixture k KilledBy count' @($r.KilledBy).Count 0
        if ($r.Note -eq '') { [void]$issues.Add('fixture k: expected a non-empty note, got an empty one') }
    } finally {
        $script:DomainStems = $savedStems
    }
    return $issues
}

# Invariant 6: Get-SuiteStem.
function Test-InvSuiteStem {
    $issues = New-Object System.Collections.ArrayList
    Test-Expect $issues 'Get-SuiteStem forward-slash path' (Get-SuiteStem 'tests/integration/claim_race.test.ts') 'claim_race'
    Test-Expect $issues 'Get-SuiteStem windows path' (Get-SuiteStem 'C:\x\tests\integration\janitor.test.ts') 'janitor'
    Test-Expect $issues 'Get-SuiteStem path with spaces' (Get-SuiteStem 'C:\my proj\tests\integration\claim basic.test.ts') 'claim basic'
    Test-Expect $issues 'Get-SuiteStem bare file name' (Get-SuiteStem 'smoke.test.ts') 'smoke'
    return $issues
}

# Invariant 7: gap-suite matching (exact only).
function Test-InvGapMatching {
    $issues = New-Object System.Collections.ArrayList
    $cases = @(
        @('exact stem is accepted', @('claim_basic_gaps','janitor'), @('claim_basic_gaps'), ''),
        @('claim_basic_gaps_v2 rejected', @('claim_basic_gaps_v2'), @('claim_basic_gaps'), 'claim_basic_gaps'),
        @('claim_basic_gaps_extra rejected', @('claim_basic_gaps_extra'), @('claim_basic_gaps'), 'claim_basic_gaps'),
        @('claim_basic alone rejected', @('claim_basic'), @('claim_basic_gaps'), 'claim_basic_gaps'),
        @('xclaim_basic_gaps rejected', @('xclaim_basic_gaps'), @('claim_basic_gaps'), 'claim_basic_gaps'),
        @('no discovered suites', @(), @('a_gaps','b_gaps'), 'a_gaps,b_gaps'),
        @('only the second is missing', @('a_gaps'), @('a_gaps','b_gaps'), 'b_gaps')
    )
    foreach ($c in $cases) {
        $got = @(Get-MissingGapSuites $c[1] $c[2])
        Test-Expect $issues ('gap matching: ' + $c[0]) ($got -join ',') $c[3]
    }
    return $issues
}

# Invariant 8: every Expected stem is a discovered suite or a derived known gap suite; the notes parser works.
function Test-InvExpectedSuites {
    $issues = New-Object System.Collections.ArrayList
    $known = @($script:KnownGapSuites)
    foreach ($m in $mutants) {
        foreach ($exp in $m.Expected) {
            $found = $false
            foreach ($d in $script:DomainStems) {
                if ([string]::Equals($d, $exp, [System.StringComparison]::OrdinalIgnoreCase)) { $found = $true; break }
            }
            if (-not $found -and ($known -cnotcontains $exp)) {
                [void]$issues.Add($m.Id + ' expects suite ''' + $exp + ''' which is neither discovered nor a known gap suite')
            }
        }
    }
    $withTargets = @($script:MissingTestNotes.Values | Where-Object { $_ -match 'Test target:\s*[a-z_]' })
    if ($withTargets.Count -gt 0 -and $known.Count -eq 0) {
        [void]$issues.Add('MissingTestNotes has "Test target:" entries but KnownGapSuites is empty (parser failure)')
    }
    return $issues
}

# Invariant 9: source hygiene of this very file (ASCII, no $src shadow, no backtick continuation).
function Test-InvSourceHygiene {
    $issues = New-Object System.Collections.ArrayList
    if (-not $PSCommandPath) {
        [void]$issues.Add('PSCommandPath is empty; run the script directly (not dot-sourced)')
        return $issues
    }
    $bytes = [System.IO.File]::ReadAllBytes($PSCommandPath)
    $start = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
    $line = 1
    $badLines = @()
    for ($i = $start; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 10) { $line++ }
        elseif ($b -gt 127) { if ($badLines -notcontains $line) { $badLines += $line } }
    }
    if ($badLines.Count -gt 0) { [void]$issues.Add('non-ASCII bytes at line(s): ' + (($badLines | Select-Object -First 10) -join ',')) }
    $scriptText = [System.IO.File]::ReadAllText($PSCommandPath)
    if ($scriptText -match '(?im)^\s*\$(?:script:)?src\s*=') { [void]$issues.Add('unqualified or script-scoped $src assignment found (v3 shadowing regression)') }
    if ($scriptText -match '(?m)`[ \t]*\r?$') { [void]$issues.Add('backtick line continuation found') }
    return $issues
}

# ---------------------------------------------------------------------------
# Start-up: reject contradictory flag combinations
# ---------------------------------------------------------------------------

$flagError = $null
if ($CleanOrphans -and ($SelfTest -or $ListOnly -or $Inspect -or $GenerateOnly)) {
    $flagError = '-CleanOrphans is exclusive; do not combine with -SelfTest/-ListOnly/-Inspect/-GenerateOnly'
} elseif ($SelfTest -and ($ListOnly -or $Inspect -or $GenerateOnly)) {
    $flagError = '-SelfTest is exclusive; do not combine with -ListOnly/-Inspect/-GenerateOnly'
} elseif ($ListOnly -and ($Inspect -or $GenerateOnly)) {
    $flagError = '-ListOnly is exclusive; do not combine with -Inspect/-GenerateOnly'
} elseif ($Inspect -and $GenerateOnly) {
    $flagError = '-Inspect is exclusive; do not combine with -GenerateOnly'
}
if ($flagError) { Write-Host $flagError; exit 3 }

Test-OwnSourceAscii

foreach ($n in $script:EnvNames) {
    $v = [Environment]::GetEnvironmentVariable($n, 'Process')
    if ($v) { Write-Host ('Leftover environment variable ' + $n + '=' + $v + ' found and cleared.') }
}
Clear-MutantEnv

if ($CleanOrphans) { Invoke-CleanOrphans; exit 0 }

$onlyList = @()
if ($Only) { $onlyList += $Only }
if ($args -and $args.Count -gt 0) { $onlyList += $args }
$onlyList = @($onlyList | ForEach-Object { ([string]$_).ToUpper() -split '[,\s]+' } | Where-Object { $_ })

$sourceFiles = @($mutants | ForEach-Object { $_.File } | Select-Object -Unique)
foreach ($f in $sourceFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { Write-Host ('Missing source file: ' + $f); exit 3 }
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'tests\integration'))) { Write-Host 'Missing directory: tests\integration'; exit 3 }

$script:CachedSources = @{}
$script:OrigHashes = @{}
foreach ($f in $sourceFiles) {
    $script:CachedSources[$f] = Read-Utf8File $f
    $script:OrigHashes[$f] = Get-Sha256Hex $f
}
$script:DomainStems = @(Get-DomainStems)
$script:MissingGaps = @(Get-MissingGapSuites $script:DomainStems $script:KnownGapSuites)

# ---------------------------------------------------------------------------
# -SelfTest (harness invariants only; no DB, no jest, no writes)
#   The invariant count is computed from the list below, never hardcoded.
# ---------------------------------------------------------------------------

if ($SelfTest) {
    $invariants = @(
        @('registry hygiene', 'Test-InvRegistry'),
        @('anchors', 'Test-InvAnchors'),
        @('dollar-escape golden check', 'Test-InvGolden'),
        @('environment mapping', 'Test-InvEnvMapping'),
        @('classifier fixtures', 'Test-InvClassifier'),
        @('suite stem parsing', 'Test-InvSuiteStem'),
        @('gap-suite matching', 'Test-InvGapMatching'),
        @('expected suites resolvable', 'Test-InvExpectedSuites'),
        @('source hygiene', 'Test-InvSourceHygiene')
    )
    $total = $invariants.Count
    Write-Host ('Self-test: ' + $total + ' invariants ...')
    $failed = 0
    $idx = 0
    foreach ($inv in $invariants) {
        $idx++
        $label = $inv[0]
        $fn = $inv[1]
        $issues = @()
        try { $issues = @(& $fn) } catch { $issues = @('invariant crashed: ' + (ConvertTo-Ascii $_.Exception.Message)) }
        if ($issues.Count -eq 0) {
            Write-Host ('  PASS  [' + $idx + '/' + $total + '] ' + $label)
        } else {
            $failed++
            Write-Host ('  FAIL  [' + $idx + '/' + $total + '] ' + $label + ': ' + ($issues -join '; '))
        }
    }
    Clear-MutantEnv
    if ($script:MissingGaps.Count -gt 0) {
        Write-Host ('  NOTE: known gap suites still missing (expected until tests are added): ' + ($script:MissingGaps -join ', '))
    }
    Write-Host ('  Known gap suites (derived from notes): ' + $(if ($script:KnownGapSuites.Count -gt 0) { $script:KnownGapSuites -join ', ' } else { '(none)' }))
    if ($failed -eq 0) {
        Write-Host ('SELF-TEST PASSED: ' + $total + ' of ' + $total + ' invariants, ' + $mutants.Count + ' mutants checked.')
        exit 0
    }
    Write-Host ('SELF-TEST FAILED: ' + $failed + ' of ' + $total + ' invariants failed.')
    exit 2
}

$pool = @($mutants)
if ($NoProbes) { $pool = @($pool | Where-Object { -not $_.Probe }) }
if ($onlyList.Count -gt 0) {
    $unknown = @($onlyList | Where-Object { $mutants.Id -notcontains $_ })
    if ($unknown.Count -gt 0) { Write-Host ('Unknown mutant id(s): ' + ($unknown -join ', ')); exit 3 }
    $selected = @($pool | Where-Object { $onlyList -contains $_.Id })
} else {
    $selected = @($pool)
}
if ($selected.Count -eq 0) { Write-Host 'No mutants selected.'; exit 3 }

# ---------------------------------------------------------------------------
# -Inspect
# ---------------------------------------------------------------------------

if ($Inspect) {
    if ($onlyList.Count -ne 1) { Write-Host '-Inspect requires -Only with exactly one mutant id (for example: -Inspect -Only C02)'; exit 3 }
    $m = $mutants | Where-Object { $_.Id -eq $onlyList[0] } | Select-Object -First 1
    $sourceText = Get-CachedSource $m.File
    $hits = [regex]::Matches($sourceText, $m.Pattern)
    $kind = 'KILL'
    if ($m.Probe) { $kind = 'PROBE' }
    $exp = '(none)'
    if ($m.Expected.Count -gt 0) { $exp = ($m.Expected -join ',') }
    Write-Host ''
    Write-Host ('Mutant : ' + $m.Id + '   Kind: ' + $kind + '   File: ' + $m.File)
    Write-Host ('Intent : ' + $m.Intent)
    Write-Host ('Expect : ' + $exp)
    Write-Host ('Pattern: ' + $m.Pattern)
    Write-Host ('Repl   : ' + $m.Replacement)
    Write-Host ('Matches: ' + $hits.Count + '   anchor check: ' + $(if ((Get-AnchorProblem $m $sourceText) -eq '') { 'OK' } else { Get-AnchorProblem $m $sourceText }))
    Write-Host ''
    if ($hits.Count -eq 0) {
        $near = ConvertTo-Ascii (Find-NearestLine $sourceText $m.Pattern)
        if ($near) { Write-Host ('Nearest line with the first keyword: ' + $near.Trim()) }
        Write-Host 'Hints: case, whitespace, parameter index ($1/$2), table alias, CRLF.'
    }
    $k = 0
    foreach ($h in $hits) {
        $k++
        $fmt = Format-MutantMatch $h $m.Replacement
        Write-Host ('--- match ' + $k + ' at line ' + (Get-LineNumber $sourceText $h.Index) + ' ---')
        Write-Host ('  line  : ' + (ConvertTo-Ascii (Get-MatchLine $sourceText $h.Index)).Trim())
        Write-Host ('  before: ' + $fmt.Before)
        Write-Host ('  after : ' + $fmt.After)
        if ($fmt.IsNoOp) { Write-Host '  *** WARNING: replacement leaves identical visible text (no-op) ***' }
    }
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# -ListOnly
# ---------------------------------------------------------------------------

if ($ListOnly) {
    Write-Host ('Mutants selected: ' + $selected.Count + '   gate suite: ' + $script:GateSuite + '   domain suites found: ' + $script:DomainStems.Count)
    Write-Host ('Domain suites: ' + ($script:DomainStems -join ', '))
    if ($script:MissingGaps.Count -gt 0) {
        Write-Host ('Known gap suites missing (tests not yet created): ' + ($script:MissingGaps -join ', '))
    }
    $badCount = 0
    $noOps = 0
    foreach ($m in $selected) {
        $sourceText = Get-CachedSource $m.File
        $hits = [regex]::Matches($sourceText, $m.Pattern)
        $problem = Get-AnchorProblem $m $sourceText
        $mark = 'OK'
        if ($problem -ne '') { $mark = 'BAD'; $badCount++ }
        $kind = 'KILL'
        if ($m.Probe) { $kind = 'PROBE' }
        $exp = '(none)'
        if ($m.Expected.Count -gt 0) { $exp = ($m.Expected -join ',') }
        Write-Host ''
        Write-Host ($m.Id + '  ' + $kind + '  ' + $m.File + '  count=' + $hits.Count + '  [' + $mark + ']  expected=' + $exp)
        Write-Host ('  intent: ' + $m.Intent)
        if ($hits.Count -ge 1) {
            $h = $hits[0]
            $fmt = Format-MutantMatch $h $m.Replacement
            Write-Host ('  line  : ' + (Get-LineNumber $sourceText $h.Index))
            Write-Host ('  before: ' + $fmt.Before)
            Write-Host ('  after : ' + $fmt.After)
            if ($fmt.IsNoOp) { Write-Host '  *** WARNING: no-op (identical visible text) ***'; $noOps++ }
        } else {
            $near = ConvertTo-Ascii (Find-NearestLine $sourceText $m.Pattern)
            Write-Host '  before: n/a (no match)'
            if ($near) { Write-Host ('  near  : ' + $near.Trim()) }
        }
        if ($problem -ne '') { Write-Host ('  PROBLEM: ' + $problem) }
    }
    Write-Host ''
    Write-Host ('Bad anchors: ' + $badCount + '   potential no-ops: ' + $noOps)
    exit 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

$skipped = @()
$badIds = @()
foreach ($m in $selected) {
    $sourceText = Get-CachedSource $m.File
    $problem = Get-AnchorProblem $m $sourceText
    if ($problem -ne '') {
        $badIds += $m.Id
        Write-Host ('BAD ANCHOR: ' + $m.Id + ' in ' + $m.File + ': ' + $problem)
        $near = ConvertTo-Ascii (Find-NearestLine $sourceText $m.Pattern)
        if ($near) { Write-Host ('            near: ' + $near.Trim()) }
    }
}
if ($badIds.Count -gt 0) {
    if (-not $SkipBad) {
        Write-Host 'Fix the anchors, or re-run with -SkipBad. Tip: -Inspect -Only <ID> shows every match.'
        exit 2
    }
    $skipped = @($badIds)
    $selected = @($selected | Where-Object { $badIds -notcontains $_.Id })
    Write-Host ('Skipping ' + $badIds.Count + ' mutant(s) with bad anchors: ' + ($badIds -join ', '))
}

# ---------------------------------------------------------------------------
# Database port (v7, F1: resolved whenever the DB is needed, also with -SkipBaseline)
# ---------------------------------------------------------------------------

if (-not $GenerateOnly) {
    $script:PgPort = Resolve-PgPort $script:PgHost $script:PgPortCandidates
    if ($script:PgPort -eq 0) { exit 5 }
}

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------

$baselineSec = 0
if (-not $SkipBaseline -and -not $GenerateOnly) {
    if (-not (Wait-Db 60)) {
        Write-Host ('Database not reachable on ' + $script:PgHost + ':' + $script:PgPort + '.')
        $hs = Get-ContainerHealth $ContainerName
        if ($hs -eq '') { $hs = '(unknown: docker unavailable or no health status)' }
        Write-Host ('Container ' + $ContainerName + ' health: ' + $hs)
        Write-Host 'Run: docker compose up -d --wait'
        Write-Host 'If the DB is on a different port, set $env:PGPORT before invoking this script.'
        exit 5
    }
    Clear-MutantEnv
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host 'Baseline gate (smoke) ...'
    $g = Invoke-Jest @($script:GateSuite) $GateTimeoutSec
    $gp = Parse-Jest $g.Text
    $gc = Classify-Gate $gp $g.TimedOut
    if ($gc.Result -ne 'PASS') { Show-RunFailure $gp ('BASELINE GATE FAILED: ' + $gc.Result + ' ' + $gc.Note); exit 1 }
    Write-Host 'Baseline domain suites ...'
    $d = Invoke-Jest $script:DomainSuites $TimeoutSec
    $dp = Parse-Jest $d.Text
    $dc = Classify-Domain $dp $d.TimedOut
    $sw.Stop()
    if ($dc.Result -ne 'ALLPASS') { Show-RunFailure $dp ('BASELINE DOMAIN FAILED: ' + $dc.Result + ' ' + $dc.Note); exit 1 }
    $baselineSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host ('Baseline PASS in ' + $baselineSec + 's  (' + $dp.Summary + ')')
}

# ---------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'Generating mutants ...'
$generated = @()
foreach ($m in $selected) {
    $sourceText = Read-Utf8File $m.File
    $hashNow = Get-Sha256Hex $m.File
    if ($hashNow -ne $script:OrigHashes[$m.File]) {
        Write-Host ('ABORT: ' + $m.File + ' changed on disk since the harness started (sha256 mismatch).')
        exit 2
    }
    $problem = Get-AnchorProblem $m $sourceText
    if ($problem -ne '') { Write-Host ('ABORT: ' + $m.Id + ' anchor problem at generation: ' + $problem); exit 2 }
    $mutated = [regex]::Replace($sourceText, $m.Pattern, $m.Replacement)
    if ($mutated -ceq $sourceText) {
        Write-Host ('ABORT: ' + $m.Id + ' produced a no-op mutant (identical text).')
        Write-Host ('  file       : ' + $m.File)
        Write-Host ('  pattern    : ' + $m.Pattern)
        Write-Host ('  replacement: ' + $m.Replacement)
        Write-Host 'Run -Inspect -Only <ID> to see the match and the before/after text.'
        exit 2
    }
    $rel = 'sql/_mutants/' + $m.Id + '.sql'
    Write-Utf8File $rel $mutated
    $back = Read-Utf8File $rel
    if (-not ($back -ceq $mutated)) { Write-Host ('ABORT: ' + $m.Id + ' round-trip read of the mutant file differs from what was written.'); exit 2 }
    $sha = Get-Sha256Hex $rel
    if ($sha -eq $script:OrigHashes[$m.File]) { Write-Host ('ABORT: ' + $m.Id + ' mutant file hash equals the original hash.'); exit 2 }
    Write-Host ('  wrote ' + $rel + '  sha256=' + $sha.Substring(0, 12))
    $generated += $m
}

$changedAtGenerate = @()
foreach ($f in $sourceFiles) { if ((Get-Sha256Hex $f) -ne $script:OrigHashes[$f]) { $changedAtGenerate += $f } }
if ($GenerateOnly) {
    Write-Host ''
    if ($changedAtGenerate.Count -eq 0) { Write-Host 'Production SQL unchanged: yes' } else { Write-Host ('Production SQL CHANGED: ' + ($changedAtGenerate -join ', ')) }
    exit 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

$perRun = 35
if ($baselineSec -gt 0) { $perRun = [math]::Max(10, $baselineSec) }
Write-Host ''
Write-Host ('Running ' + $generated.Count + ' mutants; estimated ' + [math]::Round($generated.Count * $perRun / 60.0, 0) + ' minutes.')

$partial = Join-Path $PSScriptRoot 'mutation-report.partial.txt'
[System.IO.File]::WriteAllText($partial, ('partial results ' + (Get-Date -Format s) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

$results = @()
$total = $generated.Count
for ($i = 0; $i -lt $total; $i++) {
    $m = $generated[$i]
    $rel = 'sql/_mutants/' + $m.Id + '.sql'
    $kind = 'KILL'
    if ($m.Probe) { $kind = 'PROBE' }
    $row = [pscustomobject]@{
        Id = $m.Id; Kind = $kind; File = $m.File; Intent = $m.Intent
        Expected = $m.Expected; Probe = $m.Probe
        Result = ''; KilledBy = @(); Names = @(); Note = ''; Seconds = 0
    }
    if (-not (Wait-Db 60)) {
        Write-Host ('Database became unreachable before ' + $m.Id + '. Stopping; partial results are in mutation-report.partial.txt')
        exit 5
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $rel))) { throw ('mutant file missing: ' + $rel) }
        Set-MutantEnv $m.File $rel

        $g = Invoke-Jest @($script:GateSuite) $GateTimeoutSec
        $gp = Parse-Jest $g.Text
        $gc = Classify-Gate $gp $g.TimedOut
        if ($gc.Result -ne 'PASS') {
            $row.Result = $gc.Result
            $row.Note = $gc.Note
            $row.Names = @($gp.FailingNames | Select-Object -First 3)
        } else {
            $d = Invoke-Jest $script:DomainSuites $TimeoutSec
            $dp = Parse-Jest $d.Text
            $dc = Classify-Domain $dp $d.TimedOut
            if ($dc.Result -eq 'ALLPASS') { $row.Result = 'SURVIVED' } else { $row.Result = $dc.Result }
            $row.KilledBy = @($dc.KilledBy)
            $row.Note = $dc.Note
            $row.Names = @($dp.FailingNames | Select-Object -First 3)
        }
    } catch {
        $row.Result = 'ERROR'
        $row.Note = ConvertTo-Ascii $_.Exception.Message
    } finally {
        Clear-MutantEnv
        $sw.Stop()
    }
    $row.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $killers = ($row.KilledBy -join ',')
    Write-Host ('[{0}/{1}] {2} {3,-8} {4}s  {5}' -f ($i + 1), $total, $m.Id, $row.Result, $row.Seconds, $killers)
    [System.IO.File]::AppendAllText($partial, ($m.Id + ' ' + $row.Result + ' ' + $killers + ' ' + $row.Seconds + 's' + [Environment]::NewLine))
    if ($row.Result -eq 'TIMEOUT') { Invoke-CleanOrphansSafe }
    $results += $row
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

foreach ($row in $results) { $row | Add-Member -NotePropertyName Verdict -NotePropertyValue (Get-Verdict $row) -Force }

$lines = @()
$lines += ('mutation report  ' + (Get-Date -Format s) + '  git ' + (Get-GitHead))
$lines += ('baseline ' + $baselineSec + 's; mutants run: ' + $results.Count + '; skipped (bad anchors): ' + $(if ($skipped.Count -gt 0) { $skipped -join ',' } else { 'none' }))
$lines += ('gate suite: ' + $script:GateSuite + '; domain suites: ' + ($script:DomainStems -join ','))
if ($script:MissingGaps.Count -gt 0) {
    $lines += ('known gap suites missing: ' + ($script:MissingGaps -join ','))
}
$lines += ''
$lines += 'ID | Kind | File | Intent | Expected | Result | KilledBy | Verdict | Sec'
$lines += '---|---|---|---|---|---|---|---|---'
foreach ($row in $results) {
    $exp = '(none)'
    if ($row.Expected.Count -gt 0) { $exp = ($row.Expected -join ',') }
    $kill = '-'
    if ($row.KilledBy.Count -gt 0) { $kill = ($row.KilledBy -join ',') }
    $lines += ($row.Id + ' | ' + $row.Kind + ' | ' + $row.File + ' | ' + $row.Intent + ' | ' + $exp + ' | ' + $row.Result + ' | ' + $kill + ' | ' + $row.Verdict + ' | ' + $row.Seconds)
}

$killed = @($results | Where-Object { $_.Result -eq 'KILLED' })
$survived = @($results | Where-Object { $_.Result -eq 'SURVIVED' })
$invalid = @($results | Where-Object { $_.Result -eq 'INVALID' })
$errors = @($results | Where-Object { $_.Result -eq 'ERROR' })
$timeouts = @($results | Where-Object { $_.Result -eq 'TIMEOUT' })
$evaluated = $killed.Count + $survived.Count
$score = 'n/a'
if ($evaluated -gt 0) { $score = ([math]::Round(100.0 * $killed.Count / $evaluated, 1)).ToString() + '%' }
$nonProbe = @($results | Where-Object { -not $_.Probe -and ($_.Result -eq 'KILLED' -or $_.Result -eq 'SURVIVED') })
$nonProbeKilled = @($nonProbe | Where-Object { $_.Result -eq 'KILLED' })

$lines += ''
$lines += ('Totals: ' + $results.Count + ' mutants | KILLED=' + $killed.Count + ' SURVIVED=' + $survived.Count + ' INVALID=' + $invalid.Count + ' ERROR=' + $errors.Count + ' TIMEOUT=' + $timeouts.Count)
$lines += ('Mutation score (killed / evaluated): ' + $score + '   non-probe: ' + $nonProbeKilled.Count + '/' + $nonProbe.Count)

$lines += ''
$lines += 'GAP (non-probe mutants that survived):'
$gaps = @($results | Where-Object { $_.Verdict -eq 'GAP' })
if ($gaps.Count -eq 0) { $lines += '  (none)' }
foreach ($g2 in $gaps) {
    $note = $script:MissingTestNotes[$g2.Id]
    if (-not $note) { $note = 'No current test constrains this behaviour.' }
    $lines += ('  ' + $g2.Id + ': ' + $note)
}

$lines += ''
$lines += 'PROBES that survived (information):'
$ps = @($results | Where-Object { $_.Verdict -eq 'PROBE-SURVIVED' })
if ($ps.Count -eq 0) { $lines += '  (none)' }
foreach ($p in $ps) {
    $note = $script:MissingTestNotes[$p.Id]
    if (-not $note) { $note = 'No current test constrains this behaviour.' }
    $lines += ('  ' + $p.Id + ': ' + $note)
}

$lines += ''
$lines += 'NOT EVALUATED (INVALID / ERROR / TIMEOUT; these are NOT kills):'
$ne = @($results | Where-Object { $_.Verdict -eq 'NOT-EVALUATED' })
if ($ne.Count -eq 0) { $lines += '  (none)' }
foreach ($n2 in $ne) {
    $lines += ('  ' + $n2.Id + ' ' + $n2.Result + ': ' + $n2.Note)
    foreach ($nm in $n2.Names) { $lines += ('      ' + $(if ($nm.Length -gt 100) { $nm.Substring(0, 100) } else { $nm })) }
}

$lines += ''
$lines += 'Killed by an unexpected suite only (informational):'
$ok2 = @($results | Where-Object { $_.Verdict -eq 'OK-OTHER-KILLER' })
if ($ok2.Count -eq 0) { $lines += '  (none)' }
foreach ($o in $ok2) { $lines += ('  ' + $o.Id + ' killed by ' + ($o.KilledBy -join ',') + '; expected ' + ($o.Expected -join ',')) }

$lines += ''
$lines += 'Failing tests per KILLED mutant (first 3):'
foreach ($k2 in $killed) {
    if ($k2.Names.Count -eq 0) { $lines += ('  ' + $k2.Id + ': (names not captured)') }
    foreach ($nm in $k2.Names) {
        $short = $nm
        if ($short.Length -gt 100) { $short = $short.Substring(0, 100) }
        $lines += ('  ' + $k2.Id + ': ' + $short)
    }
}

$changed = @()
foreach ($f in $sourceFiles) { if ((Get-Sha256Hex $f) -ne $script:OrigHashes[$f]) { $changed += $f } }
$lines += ''
if ($changed.Count -eq 0) { $lines += 'Production SQL unchanged: yes (SHA-256 identical before and after).' }
else { $lines += ('Production SQL CHANGED: ' + ($changed -join ', ') + '  <-- do not trust this report') }
$lines += ('Total elapsed: ' + [math]::Round($script:Clock.Elapsed.TotalMinutes, 1) + ' minutes')

$enc = New-Object System.Text.UTF8Encoding($false)
$reportPath = Join-Path $PSScriptRoot 'mutation-report.txt'
[System.IO.File]::WriteAllText($reportPath, (($lines | ForEach-Object { ConvertTo-Ascii $_ }) -join [Environment]::NewLine) + [Environment]::NewLine, $enc)

$jsonRows = @()
foreach ($row in $results) {
    $jsonRows += [pscustomobject]@{
        id = $row.Id; kind = $row.Kind; file = $row.File; intent = (ConvertTo-Ascii $row.Intent)
        expected = @($row.Expected); result = $row.Result; killedBy = @($row.KilledBy)
        verdict = $row.Verdict; seconds = $row.Seconds; note = (ConvertTo-Ascii $row.Note)
    }
}
$jsonPath = Join-Path $PSScriptRoot 'mutation-report.json'
[System.IO.File]::WriteAllText($jsonPath, (ConvertTo-Json -InputObject @($jsonRows) -Depth 4), $enc)

Write-Host ''
Write-Host 'Report (also written to mutation-report.txt and mutation-report.json):'
foreach ($l in $lines) { Write-Host $l }
Write-Host ''
Write-Host 'Next: commit the report, write tests for every GAP, re-run.'

Clear-MutantEnv
if ($Strict -and ($gaps.Count -gt 0 -or $ne.Count -gt 0)) { exit 4 }
exit 0