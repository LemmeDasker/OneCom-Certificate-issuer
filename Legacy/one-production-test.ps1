#requires -Version 5.1

# ============================================================
# one-production-test.ps1 - Let's Encrypt PRODUCTION certificate
# via OneCom plugin (manual run)
#
# Run one-staging-test.ps1 FIRST and only continue here
# after it reported RESULT: SUCCESS.
#
# Let's Encrypt production enforces rate limits
# (5 failed authorisations per account/hostname/hour).
# Do not run this script repeatedly "just to be sure".
# ============================================================

$ErrorActionPreference = 'Stop'

$domain = 'www.mydomain.com'
$contact = 'mail@box.com'
$credentialPath = Join-Path `
    $env:LOCALAPPDATA `
    'Posh-ACME\Secrets\OneComCredential.xml'

Write-Host ''
Write-Host '============================================================'
Write-Host ' one.com / Posh-ACME PRODUCTION certificate'
Write-Host '============================================================'
Write-Host ''

try {

    # ------------------------------------------------------------
    # 1. Load Posh-ACME
    # ------------------------------------------------------------

    Write-Host '[1/9] Importing Posh-ACME...'

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
    # 2. Confirm staging succeeded first
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[2/9] Checking for a previous staging certificate...'

    Set-PAServer LE_STAGE -ErrorAction Stop

    $stagingCert = Get-PACertificate -MainDomain $domain -ErrorAction SilentlyContinue

    if ($null -eq $stagingCert) {
        throw "No staging certificate found for $domain. Run one-staging-test.ps1 before requesting a production certificate."
    }

    Write-Host "      Staging certificate found (NotAfter: $($stagingCert.NotAfter))."

    # ------------------------------------------------------------
    # 3. Switch to Let's Encrypt production
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[3/9] Selecting Let''s Encrypt PRODUCTION...'

    Set-PAServer LE_PROD -ErrorAction Stop

    $activeServer = Get-PAServer

    Write-Host "      Active server: $($activeServer.Name)"
    Write-Host "      Directory    : $($activeServer.DirectoryUrl)"

    if ($activeServer.Name -ne 'LE_PROD') {
        throw "Expected LE_PROD but the active server is $($activeServer.Name)."
    }

    # ------------------------------------------------------------
    # 4. Validate contact configuration
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[4/9] Validating ACME contact email...'

    if ([string]::IsNullOrWhiteSpace($contact)) {
        throw 'Set the $contact variable at the top of this script before running.'
    }

    Write-Host "      Contact: $contact"

    # ------------------------------------------------------------
    # 5. Explicit confirmation
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[5/9] Confirmation required'
    Write-Host ''
    Write-Host '      This will request a REAL, rate-limited certificate'
    Write-Host "      from Let's Encrypt production for:"
    Write-Host ''
    Write-Host "        $domain"
    Write-Host ''

    $answer = Read-Host '      Type PROD to continue'

    if ($answer -cne 'PROD') {
        throw 'Aborted by user. No production certificate was requested.'
    }

    # ------------------------------------------------------------
    # 6. Load encrypted one.com credential
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[6/9] Loading encrypted one.com credential...'
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
    }

    # ------------------------------------------------------------
    # 7. Request production certificate
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[7/9] Requesting PRODUCTION certificate...'
    Write-Host "      Domain: $domain"
    Write-Host '      NOTE  : one.com TTL is 3600, so DNS propagation is slow.'
    Write-Host '              If validation times out, raise -DnsSleep.'
    Write-Host '              Do NOT change the plugin.'

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
    # 8. Read resulting certificate
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[8/9] Reading resulting certificate...'

    $certificate = Get-PACertificate -MainDomain $domain -ErrorAction Stop

    if ($null -eq $certificate) {
        throw 'Get-PACertificate did not return a certificate object.'
    }

    Write-Host ''
    Write-Host "      Subject      : $($certificate.Subject)"
    Write-Host "      NotAfter     : $($certificate.NotAfter)"
    Write-Host "      CertFile     : $($certificate.CertFile)"
    Write-Host "      KeyFile      : $($certificate.KeyFile)"
    Write-Host "      FullChainFile: $($certificate.FullChainFile)"

    # ------------------------------------------------------------
    # 9. Result
    # ------------------------------------------------------------

    Write-Host ''
    Write-Host '[9/9] Result'
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULT: SUCCESS'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host 'A production certificate has been issued.'
    Write-Host ''
    Write-Host 'Next steps for Apache/WAMP:'
    Write-Host ''
    Write-Host '  SSLCertificateFile    -> FullChainFile shown above'
    Write-Host '  SSLCertificateKeyFile -> KeyFile shown above'
    Write-Host ''
    Write-Host 'Also verify before testing https://' -NoNewline
    Write-Host $domain
    Write-Host ''
    Write-Host '  - A public A record for the hostname points to your WAN IP'
    Write-Host '  - Port 443 is open and forwarded to the WAMP machine'
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
    Write-Host 'Remember that Let''s Encrypt production is rate limited.'
    Write-Host 'Investigate the cause before retrying.'
    Write-Host ''

    throw
}
