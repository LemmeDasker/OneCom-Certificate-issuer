#requires -Version 5.1
<#
.SYNOPSIS
    Ubetjent one.com / Posh-ACME certifikatkørsel mod Let's Encrypt STAGING.

.DESCRIPTION
    Kan startes af Opgavestyring (Task Scheduler). Ingen interaktion kræves.
    Bruger altid LE_STAGE. Output skrives til en logfil.
    Exitkode 0 = succes / ingen fornyelse nødvendig, exitkode 1 = fejl.

    Den manuelle variant er one-staging-test.ps1.

.PARAMETER Force
    Gennemtving fornyelse, selvom certifikatet ikke er ved at udløbe.
#>
[CmdletBinding()]
param(
    [string]$Domain = 'www.mydomain.com',
    [string]$Contact = 'mail@box.com',
    [string]$CredentialPath = (Join-Path $env:LOCALAPPDATA 'Posh-ACME\Secrets\OneComCredential.xml'),
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'Posh-ACME\Logs'),
    [int]$LogRetentionDays = 30,
    [switch]$Force
)

# Fast server for denne fil - STAGING
$Server    = 'LE_STAGE'
$LogPrefix = 'onecom-acme-staging'

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'

# ------------------------------------------------------------
# Logning
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$logFile = Join-Path $LogDirectory ("{0}_{1:yyyyMMdd_HHmmss}.log" -f $LogPrefix, (Get-Date))
Start-Transcript -LiteralPath $logFile -Force | Out-Null

function Write-Log {
    param([string]$Message)
    Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

$exitCode = 0

Write-Log '============================================================'
Write-Log ' one.com / Posh-ACME STAGING automatiseret kørsel'
Write-Log '============================================================'

try {

    # ------------------------------------------------------------
    # 1. Indlæs Posh-ACME og verificér OneCom-plugin
    # ------------------------------------------------------------

    Write-Log '[1/8] Importerer Posh-ACME...'

    $module = Import-Module Posh-ACME -PassThru -ErrorAction Stop
    Write-Log "      Modulversion: $($module.Version)"

    $plugin = Get-PAPlugin OneCom -ErrorAction Stop
    if ($null -eq $plugin) {
        throw 'Plugin OneCom blev ikke fundet af Posh-ACME.'
    }

    $pluginType = $plugin.ChallengeType
    if ([string]::IsNullOrWhiteSpace($pluginType)) {
        $pluginType = $plugin.Type
    }

    Write-Log "      Plugintype  : $pluginType"

    if ($pluginType -ne 'dns-01') {
        throw "Uventet plugintype: $pluginType"
    }

    # ------------------------------------------------------------
    # 2. Vælg Let's Encrypt STAGING
    # ------------------------------------------------------------

    Write-Log '[2/8] Vælger Let''s Encrypt STAGING...'

    Set-PAServer $Server -ErrorAction Stop
    $activeServer = Get-PAServer

    Write-Log "      Aktiv server: $($activeServer.Name)"
    Write-Log "      Directory   : $($activeServer.DirectoryUrl)"

    if ($activeServer.Name -ne $Server) {
        throw "Forventede $Server, men aktiv server er $($activeServer.Name)."
    }

    # ------------------------------------------------------------
    # 3. Validér kontakt-e-mail
    # ------------------------------------------------------------

    Write-Log '[3/8] Validerer ACME-kontakt-e-mail...'

    if ([string]::IsNullOrWhiteSpace($Contact)) {
        throw 'Parameteren -Contact er tom.'
    }

    Write-Log "      Kontakt: $Contact"

    # ------------------------------------------------------------
    # 4. Indlæs krypteret one.com-legitimation
    # ------------------------------------------------------------

    Write-Log '[4/8] Indlæser krypteret one.com-legitimation...'
    Write-Log "      Sti: $CredentialPath"

    if (-not (Test-Path -LiteralPath $CredentialPath -PathType Leaf)) {
        throw "Legitimationsfilen blev ikke fundet. Kør save-onecom-credential.ps1 som samme bruger, som opgaven kører under. Forventet sti: $CredentialPath"
    }

    $cred = Import-Clixml -LiteralPath $CredentialPath

    if ($cred -isnot [System.Management.Automation.PSCredential]) {
        throw "Legitimationsfilen indeholder ikke en gyldig PSCredential: $CredentialPath"
    }

    Write-Log "      Legitimation indlæst for: $($cred.UserName)"

    $pArgs = @{
        OneComCredential = $cred
        DiagnosticTag    = 'scheduled-staging'
    }

    # ------------------------------------------------------------
    # 5. Bestil nyt certifikat eller forny eksisterende
    # ------------------------------------------------------------

    Write-Log "[5/8] Behandler STAGING-certifikat for $Domain..."

    $existingOrder = Get-PAOrder -MainDomain $Domain -ErrorAction SilentlyContinue

    if ($null -eq $existingOrder) {
        Write-Log '      Ingen eksisterende ordre - bestiller nyt certifikat.'

        New-PACertificate `
            -Domain $Domain `
            -Plugin 'OneCom' `
            -PluginArgs $pArgs `
            -AcceptTOS `
            -Contact $Contact `
            -DnsSleep 120 `
            -ValidationTimeout 300 `
            -Force | Out-Null
    }
    else {
        Write-Log "      Eksisterende ordre fundet (RenewAfter: $($existingOrder.RenewAfter))."

        $renewArgs = @{ MainDomain = $Domain; ErrorAction = 'Stop' }
        if ($Force) { $renewArgs.Force = $true }

        $renewed = Submit-Renewal @renewArgs

        if ($null -eq $renewed) {
            Write-Log '      Fornyelse ikke nødvendig endnu.'
        }
        else {
            Write-Log '      Certifikatet blev fornyet.'
        }
    }

    # ------------------------------------------------------------
    # 6. Læs resulterende certifikat
    # ------------------------------------------------------------

    Write-Log '[6/8] Læser resulterende certifikat...'

    $certificate = Get-PACertificate -MainDomain $Domain -ErrorAction Stop
    if ($null -eq $certificate) {
        throw 'Get-PACertificate returnerede ikke et certifikatobjekt.'
    }

    # ------------------------------------------------------------
    # 7. Log certifikatdetaljer
    # ------------------------------------------------------------

    Write-Log '[7/8] Certifikatdetaljer'
    Write-Log "      Subject      : $($certificate.Subject)"
    Write-Log "      NotAfter     : $($certificate.NotAfter)"
    Write-Log "      CertFile     : $($certificate.CertFile)"
    Write-Log "      KeyFile      : $($certificate.KeyFile)"
    Write-Log "      FullChainFile: $($certificate.FullChainFile)"

    # ------------------------------------------------------------
    # 8. Resultat
    # ------------------------------------------------------------

    Write-Log '[8/8] RESULTAT (STAGING): SUCCESS'
}
catch {
    $exitCode = 1
    Write-Log '[!] RESULTAT (STAGING): FAILED'
    Write-Log "    $($_.Exception.Message)"
    Write-Log "    $($_.ScriptStackTrace)"
}
finally {
    Get-ChildItem -LiteralPath $LogDirectory -Filter "$($LogPrefix)_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Stop-Transcript | Out-Null
}

exit $exitCode
