#requires -Version 5.1
<#
.SYNOPSIS
    Bestiller eller fornyer certifikatet via Let's Encrypt (one.com DNS-01).

.DESCRIPTION
    Køres af Opgavestyring (Task Scheduler) og af Install-Certificate.ps1.
    Kræver ingen interaktion. Indstillinger læses fra ..\config.json.

    Staging    : Test mod Let's Encrypt STAGING (certifikatet er ikke betroet).
                 Kopieres ikke til Certificates-mappen.
    Production : Rigtigt certifikat. Fornyes kun, når det er nødvendigt.
                 Kopieres til ..\Certificates\<domæne>\. Hvis certifikatet
                 er ændret, køres scripts i ..\Hooks\.

    Log        : ..\Logs\<miljø>_<tidspunkt>.log
    Status     : ..\STATUS.txt (produktion) og ..\Logs\status-staging.txt

    Exitkoder:
        0 = OK (fornyet eller ikke nødvendigt endnu)
        1 = Fejl - certifikatet blev ikke bestilt/fornyet
        2 = Certifikatet er OK, men et eller flere hooks fejlede

.PARAMETER Environment
    Staging eller Production.

.PARAMETER NewOrder
    Bestil altid et helt nyt certifikat (bruges af installationen til staging-testen).
    Pas på med Production: Let's Encrypt har rate limits.

.PARAMETER Force
    Forny, selvom certifikatet ikke er ved at udløbe. Pas på rate limits.

.PARAMETER RunHooks
    Kør hooks, selvom certifikatet ikke er ændret (kun Production).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Staging', 'Production')]
    [string]$Environment,

    [switch]$NewOrder,
    [switch]$Force,
    [switch]$RunHooks,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'

# $PSScriptRoot kan være tom i param-standardværdier under Windows PowerShell 5.1.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

. (Join-Path $scriptDir 'CertificateCommon.ps1')

$rootDir   = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $rootDir 'config.json' }
$logDir    = Join-Path $rootDir 'Logs'
$hookDir   = Join-Path $rootDir 'Hooks'
$isProd    = ($Environment -eq 'Production')
$server    = if ($isProd) { 'LE_PROD' } else { 'LE_STAGE' }
$label     = if ($isProd) { 'PRODUKTION' } else { 'STAGING (test)' }
$logPrefix = $Environment.ToLowerInvariant()

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$logFile = Join-Path $logDir ('{0}_{1:yyyyMMdd_HHmmss}.log' -f $logPrefix, (Get-Date))

$transcribing = $false
try {
    Start-Transcript -LiteralPath $logFile -Force | Out-Null
    $transcribing = $true
}
catch {
    Write-Warning "Kunne ikke starte logfil ($logFile): $($_.Exception.Message)"
}

$exitCode     = 0
$errorMessage = $null
$lock         = $null
$cfg          = $null
$certificate  = $null
$certDir      = $null
$hookFailures = 0
$renewed      = $false

Write-Log '============================================================'
Write-Log " Certifikat - $label"
Write-Log '============================================================'
Write-Log "Bruger: $((Get-CurrentUserInfo).Name)   Computer: $env:COMPUTERNAME"

try {
    # ------------------------------------------------------------
    Write-Log '[1/7] Læser indstillinger...'
    # ------------------------------------------------------------

    $cfg = Read-CertConfig -Path $ConfigPath
    Write-Log "      Domæner     : $($cfg.Domains -join ', ')"
    Write-Log "      one.com-zone: $($cfg.OneComDomain)"
    Write-Log "      Kontakt     : $($cfg.Contact)"

    $me = Get-CurrentUserInfo
    if ($cfg.CertificateUserSid -and $cfg.CertificateUserSid -ne $me.Sid) {
        throw ("Scriptet kører som $($me.Name), men certifikatet er sat op til $($cfg.CertificateUser). " +
               "one.com-login kan kun læses af den bruger, der gemte det. Ret opgaven i Opgavestyring " +
               "eller kør Install.cmd igen som den rigtige bruger.")
    }

    # ------------------------------------------------------------
    Write-Log '[2/7] Venter på eventuelle andre certifikatkørsler...'
    # ------------------------------------------------------------

    $lock = Enter-CertificateLock -TimeoutMinutes 30

    # ------------------------------------------------------------
    Write-Log '[3/7] Indlæser Posh-ACME og OneCom-plugin...'
    # ------------------------------------------------------------

    Enable-Tls12
    $module = Import-PoshAcmeWithPlugin -PluginSource (Join-Path $scriptDir 'OneCom.ps1')
    Write-Log "      Posh-ACME $($module.Version), OneCom-plugin fundet."

    # ------------------------------------------------------------
    Write-Log "[4/7] Vælger Let's Encrypt-server $server..."
    # ------------------------------------------------------------

    Set-PAServer $server -ErrorAction Stop
    $active = Get-PAServer
    if ($null -eq $active -or $active.Name -ne $server) {
        throw "Forventede server $server, men den aktive er '$($active.Name)'."
    }
    Write-Log "      Aktiv server: $($active.Name)"

    # ------------------------------------------------------------
    Write-Log '[5/7] Indlæser one.com-login...'
    # ------------------------------------------------------------

    $cred = Get-SavedOneComCredential -Path (Get-DefaultCredentialPath)
    Write-Log "      Login: $($cred.UserName)"

    $pluginArgs = @{
        OneComCredential = $cred
        OneComDomain     = $cfg.OneComDomain
    }

    # ------------------------------------------------------------
    Write-Log '[6/7] Bestiller/fornyer certifikat...'
    # ------------------------------------------------------------

    $order = $null
    try { $order = Get-PAOrder -MainDomain $cfg.MainDomain -ErrorAction Stop } catch { $order = $null }

    $existing = $null
    if ($order) {
        try { $existing = Get-PACertificate -MainDomain $cfg.MainDomain -ErrorAction Stop } catch { $existing = $null }
    }

    $reason = $null
    if ($NewOrder)                                               { $reason = 'nyt certifikat ønsket (-NewOrder)' }
    elseif ($null -eq $order)                                    { $reason = 'ingen tidligere ordre' }
    elseif ($null -eq $existing)                                 { $reason = 'tidligere ordre gav intet certifikat' }
    elseif (-not (Test-OrderMatchesDomains $order $cfg.Domains)) { $reason = 'domænelisten er ændret' }

    if ($reason) {
        Write-Log "      Bestiller nyt certifikat: $reason."
        Write-Log "      Dette tager typisk $([math]::Ceiling($cfg.DnsSleep / 60) + 1)-5 minutter (venter på DNS)."

        New-PACertificate `
            -Domain $cfg.Domains `
            -Plugin 'OneCom' `
            -PluginArgs $pluginArgs `
            -AcceptTOS `
            -Contact $cfg.Contact `
            -DnsSleep $cfg.DnsSleep `
            -ValidationTimeout $cfg.ValidationTimeout `
            -Force `
            -Verbose | Out-Null

        $renewed = $true
    }
    else {
        Write-Log "      Eksisterende certifikat udløber $($existing.NotAfter). Fornyes efter $($order.RenewAfter)."

        # Opdatér gemte plugin-argumenter, så et nyt one.com-password
        # (gemt med Install.cmd) også bruges ved fornyelse.
        $setOrder = Get-Command Set-PAOrder -ErrorAction SilentlyContinue
        if ($setOrder -and $setOrder.Parameters.ContainsKey('PluginArgs')) {
            try {
                Set-PAOrder -MainDomain $cfg.MainDomain -Plugin 'OneCom' -PluginArgs $pluginArgs `
                    -DnsSleep $cfg.DnsSleep -ValidationTimeout $cfg.ValidationTimeout -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "      Kunne ikke opdatere ordrens plugin-argumenter: $($_.Exception.Message)" -Level Warn
            }
        }

        $renewArgs = @{ MainDomain = $cfg.MainDomain; ErrorAction = 'Stop' }
        if ($Force) { $renewArgs.Force = $true }

        $result = Submit-Renewal @renewArgs -Verbose
        if ($null -ne $result) {
            $renewed = $true
            Write-Log '      Certifikatet blev fornyet.' -Level Ok
        }
        else {
            Write-Log '      Fornyelse er ikke nødvendig endnu.'
        }
    }

    # ------------------------------------------------------------
    Write-Log '[7/7] Kontrollerer certifikatet...'
    # ------------------------------------------------------------

    $certificate = Get-PACertificate -MainDomain $cfg.MainDomain -ErrorAction Stop
    if ($null -eq $certificate) { throw 'Posh-ACME returnerede intet certifikat.' }

    Write-Log "      Subject   : $($certificate.Subject)"
    Write-Log "      Domæner   : $(@($certificate.AllSANs) -join ', ')"
    Write-Log "      Udløber   : $($certificate.NotAfter)"
    Write-Log "      Thumbprint: $($certificate.Thumbprint)"

    if ($certificate.NotAfter -le (Get-Date)) {
        throw "Certifikatet er udløbet ($($certificate.NotAfter))."
    }

    $daysLeft = [int][math]::Floor(($certificate.NotAfter - (Get-Date)).TotalDays)
    if ($daysLeft -lt 14) {
        Write-Log "      ADVARSEL: Certifikatet udløber om $daysLeft dage, og fornyelse er ikke lykkedes." -Level Warn
    }

    $missing = @($cfg.Domains | Where-Object { @($certificate.AllSANs) -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Certifikatet dækker ikke: $($missing -join ', ')"
    }

    if ($isProd) {
        $certDir = Join-Path $rootDir ("Certificates\" + (Get-SafeFolderName $cfg.MainDomain))
        Write-Log "      Kopierer til $certDir ..."

        $changed = Export-CertificateFiles -Certificate $certificate -Destination $certDir
        if ($changed -or -not (Test-Path -LiteralPath (Join-Path $certDir 'info.txt'))) {
            Write-CertificateInfo -Certificate $certificate -Destination $certDir -Domains $cfg.Domains
        }

        if ($changed) { Write-Log '      Certifikatfilerne er opdateret.' -Level Ok }
        else          { Write-Log '      Certifikatfilerne er allerede opdaterede.' }

        if ($changed -or $RunHooks) {
            Write-Log '      Kører hooks...'
            $hookEnv = @{
                CERT_DOMAIN     = $cfg.MainDomain
                CERT_DOMAINS    = ($cfg.Domains -join ',')
                CERT_DIR        = $certDir
                CERT_FULLCHAIN  = (Join-Path $certDir 'fullchain.cer')
                CERT_KEY        = (Join-Path $certDir 'cert.key')
                CERT_CERT       = (Join-Path $certDir 'cert.cer')
                CERT_CHAIN      = (Join-Path $certDir 'chain.cer')
                CERT_PFX        = (Join-Path $certDir 'cert.pfx')
                CERT_PFX_FULL   = (Join-Path $certDir 'fullchain.pfx')
                CERT_THUMBPRINT = [string]$certificate.Thumbprint
                CERT_NOTAFTER   = $certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')
            }
            $hookFailures = Invoke-CertificateHooks -HookDirectory $hookDir -Environment $hookEnv `
                -TimeoutSeconds $cfg.HookTimeoutSeconds
            if ($hookFailures -gt 0) { $exitCode = 2 }
        }
    }

    if ($exitCode -eq 0) {
        Write-Log "RESULTAT ($label): SUCCESS" -Level Ok
    }
    else {
        Write-Log "RESULTAT ($label): Certifikat OK, men $hookFailures hook(s) fejlede." -Level Warn
    }
}
catch {
    $exitCode = 1
    $errorMessage = $_.Exception.Message
    Write-Log "RESULTAT ($label): FAILED" -Level Error
    Write-Log "    $errorMessage" -Level Error
    if ($_.ScriptStackTrace) { Write-Log "    $($_.ScriptStackTrace -replace "`r?`n", ' <- ')" }
    if ($isProd) {
        Write-Log '    Husk: Let''s Encrypt har rate limits. Find årsagen, før du prøver igen.'
    }
}
finally {
    Exit-CertificateLock $lock

    try {
        $statusFile = if ($isProd) { Join-Path $rootDir 'STATUS.txt' } else { Join-Path $logDir 'status-staging.txt' }
        $resultText = switch ($exitCode) {
            0       { 'OK' }
            2       { 'OK - men et eller flere hooks fejlede (se loggen)' }
            default { 'FEJL (se loggen)' }
        }
        $status = @(
            "Certifikat - $label"
            ''
            "Seneste kørsel : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)
            "Resultat       : $resultText"
        )
        if ($cfg)          { $status += "Domæner        : $($cfg.Domains -join ', ')" }
        if ($certificate)  { $status += "Udløber        : $($certificate.NotAfter)" }
        if ($renewed)      { $status += 'Fornyet        : Ja (denne kørsel)' }
        if ($certDir)      { $status += "Certifikatmappe: $certDir" }
        if ($errorMessage) { $status += "Fejl           : $errorMessage" }
        $status += "Log            : $logFile"

        Set-Content -LiteralPath $statusFile -Value $status -Encoding UTF8
    }
    catch {
        Write-Warning "Kunne ikke skrive statusfil: $($_.Exception.Message)"
    }

    $retention = 30
    if ($cfg) { $retention = $cfg.LogRetentionDays }
    Remove-OldFiles -Directory $logDir -Filter "$($logPrefix)_*.log" -Days $retention

    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }
}

exit $exitCode
