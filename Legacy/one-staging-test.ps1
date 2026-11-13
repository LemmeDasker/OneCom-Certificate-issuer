#requires -Version 5.1

$ErrorActionPreference = 'Stop'

$domain = 'www.mydomain.com'
$contact = 'mail@box.com'
$credentialPath = Join-Path `
    $env:LOCALAPPDATA `
    'Posh-ACME\Secrets\OneComCredential.xml'

Write-Host ''
Write-Host '============================================================'
Write-Host ' one.com / Posh-ACME staging integration test'
Write-Host '============================================================'
Write-Host ''

try {

    # ------------------------------------------------------------
    # 1. Load Posh-ACME
    # ------------------------------------------------------------

    Write-Host '[1/8] Importing Posh-ACME...'

    $module = Import-Module Posh-ACME -PassThru -ErrorAction Stop

    Write-Host "      Module version: $($module.Version)"

    $plugin = Get-PAPlugin OneCom -ErrorAction Stop

    if ($null -eq $plugin) {
        throw 'Plugin OneCom was not discovered by Posh-ACME.'
    }

    $pluginType = $plugin.ChallengeType

    if ([string]::IsNullOrWhiteSpace($pluginType)) {
        $pluginType = $plugin.Type
    }

    Write-Host "      Plugin type   : $pluginType"

    if ($pluginType -ne 'dns-01') {
        throw "Unexpected plugin type: $pluginType"
    }

    # ------------------------------------------------------------
    # 2. Switch to Let's Encrypt staging
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[2/8] Selecting Let''s Encrypt staging...'

    Set-PAServer LE_STAGE -ErrorAction Stop

    $activeServer = Get-PAServer

    Write-Host "      Active server: $($activeServer.Name)"
    Write-Host "      Directory    : $($activeServer.DirectoryUrl)"

    # ------------------------------------------------------------
    # 3. Validate contact configuration
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[3/8] Validating ACME contact email...'

    if ([string]::IsNullOrWhiteSpace($contact)) {
        throw 'Set the $contact variable at the top of this script before running the staging test.'
    }

    Write-Host "      Contact: $contact"

    # ------------------------------------------------------------
    # 4. Load encrypted one.com credential
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[4/8] Loading encrypted one.com credential...'
    Write-Host "      Path: $credentialPath"

    if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
        throw "The one.com credential file was not found. Run save-onecom-credential.ps1 first. Expected path: $credentialPath"
    }

    $cred = Import-Clixml -LiteralPath $credentialPath

    if ($cred -isnot [System.Management.Automation.PSCredential]) {
        throw "The one.com credential file does not contain a valid PSCredential: $credentialPath"
    }

    Write-Host "      Credential loaded for: $($cred.UserName)"

    $pArgs = @{
        OneComCredential = $cred
        DiagnosticTag    = 'staging-test'
    }

    # ------------------------------------------------------------
    # 5. Request staging certificate
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[5/8] Requesting staging certificate...'
    Write-Host "      Domain: $domain"
    Write-Host '      NOTE  : This uses LE_STAGE, NOT production.'

    New-PACertificate `
        -Domain $domain `
        -Plugin 'OneCom' `
        -PluginArgs $pArgs `
        -AcceptTOS `
        -Contact $contact `
        -DnsSleep 120 `
        -ValidationTimeout 300 `
        -Verbose

    # ------------------------------------------------------------
    # 6. Read resulting certificate
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[6/8] Reading resulting certificate...'

    $certificate = Get-PACertificate -MainDomain $domain -ErrorAction Stop

    if ($null -eq $certificate) {
        throw 'Get-PACertificate did not return a certificate object.'
    }

    # ------------------------------------------------------------
    # 7. Display certificate details
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[7/8] Certificate details'
    Write-Host ''
    Write-Host "      Subject      : $($certificate.Subject)"
    Write-Host "      NotAfter     : $($certificate.NotAfter)"
    Write-Host "      CertFile     : $($certificate.CertFile)"
    Write-Host "      KeyFile      : $($certificate.KeyFile)"
    Write-Host "      FullChainFile: $($certificate.FullChainFile)"

    # ------------------------------------------------------------
    # 8. Result
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[8/8] Test result'
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULT: SUCCESS'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host 'Staging issuance succeeded for www.mydomain.com.'
    Write-Host 'Only after a clean staging issuance should you switch to:'
    Write-Host '  Set-PAServer LE_PROD'
    Write-Host ''
}
catch {

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULT: FAILED'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host $_.Exception.Message
    Write-Host ''
    Write-Host 'Fix the issue above before switching to LE_PROD.'
    Write-Host ''

    throw
}
