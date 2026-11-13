#requires -Version 5.1
<#
.SYNOPSIS
    Gemmer one.com-login krypteret (Windows DPAPI) og tester det mod one.com.

.DESCRIPTION
    Login gemmes i %LOCALAPPDATA%\Posh-ACME\Secrets\OneComCredential.xml og
    kan kun læses af den samme Windows-bruger på den samme PC. Kør derfor
    scriptet som den bruger, der kører certifikatopgaverne.

    Før login gemmes, testes det: der logges ind på one.com, og DNS-
    oplysningerne for one.com-domænet hentes. Forkert adgangskode eller et
    domæne, der ikke hører til kontoen, opdages dermed med det samme.

    Exitkoder: 0 = OK, 1 = fejl/afbrudt.

.PARAMETER OneComDomain
    Domænet (DNS-zonen) hos one.com, fx example.dk.

.PARAMETER VerifyOnly
    Gem ikke noget - test kun det allerede gemte login.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OneComDomain,

    [string]$CredentialPath,

    [switch]$VerifyOnly,

    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'CertificateCommon.ps1')

$pluginPath = Join-Path $PSScriptRoot 'OneCom.ps1'
if (-not $CredentialPath) { $CredentialPath = Get-DefaultCredentialPath }

function Test-OneComLogin {
    param(
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$Domain
    )

    if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
        throw "OneCom.ps1 blev ikke fundet: $pluginPath"
    }

    # Indlæs plugin'ets funktioner (Connect-OneCom m.fl.) i dette scope.
    . $pluginPath
    Set-OneComDomain -Domain $Domain

    $session = Connect-OneCom -OneComCredential $Credential

    try {
        $records = Get-OneComDnsRecords -Session $session
    }
    catch {
        throw ("Login lykkedes, men DNS for '$Domain' kunne ikke hentes. Kontrollér, at domænet " +
               "ligger på denne one.com-konto. Detaljer: $($_.Exception.Message)")
    }

    return @($records).Count
}

$zone = ConvertTo-AsciiDomain $OneComDomain
if ($null -eq $zone -or $zone.StartsWith('*.')) {
    Write-Log "Ugyldigt one.com-domæne: '$OneComDomain'" -Level Error
    exit 1
}

Enable-Tls12
$user = (Get-CurrentUserInfo).Name

Write-Log '------------------------------------------------------------'
Write-Log " one.com-login for $zone (Windows-bruger: $user)"
Write-Log '------------------------------------------------------------'

# ------------------------------------------------------------
# Test kun det gemte login
# ------------------------------------------------------------

if ($VerifyOnly) {
    try {
        $cred = Get-SavedOneComCredential -Path $CredentialPath
        Write-Log "Tester gemt login ($($cred.UserName)) mod one.com..."
        $count = Test-OneComLogin -Credential $cred -Domain $zone
        Write-Log "Gemt login virker. DNS-zonen $zone har $count poster." -Level Ok
        exit 0
    }
    catch {
        Write-Log $_.Exception.Message -Level Error
        exit 1
    }
}

# ------------------------------------------------------------
# Spørg, test og gem
# ------------------------------------------------------------

$previousUser = $null
if (Test-Path -LiteralPath $CredentialPath -PathType Leaf) {
    try { $previousUser = (Import-Clixml -LiteralPath $CredentialPath).UserName } catch { }
}

Write-Log 'Bemærk: To-faktor-login på one.com-kontoen understøttes ikke.'

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

    Write-Log "Indtast one.com-login (forsøg $attempt af $MaxAttempts). Der åbner et vindue."

    $getCredArgs = @{ Message = "one.com-login for $zone (e-mail og adgangskode)" }
    if ($previousUser) { $getCredArgs.UserName = $previousUser }

    $cred = $null
    try { $cred = Get-Credential @getCredArgs } catch { $cred = $null }

    if ($null -eq $cred) {
        Write-Log 'Indtastning annulleret. Intet blev gemt.' -Level Warn
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($cred.UserName) -or
        [string]::IsNullOrEmpty($cred.GetNetworkCredential().Password)) {
        Write-Log 'Brugernavn og adgangskode skal begge udfyldes.' -Level Warn
        continue
    }

    $previousUser = $cred.UserName

    try {
        Write-Log "Tester login ($($cred.UserName)) mod one.com..."
        $count = Test-OneComLogin -Credential $cred -Domain $zone
        Write-Log "Login virker. DNS-zonen $zone har $count poster." -Level Ok
    }
    catch {
        Write-Log $_.Exception.Message -Level Error
        Write-Log 'Kontrollér e-mail og adgangskode (log evt. ind på one.com i en browser for at teste).' -Level Warn
        continue
    }

    try {
        $dir = Split-Path -Parent $CredentialPath
        New-Item -ItemType Directory -Path $dir -Force | Out-Null

        $tmp = "$CredentialPath.tmp"
        $cred | Export-Clixml -LiteralPath $tmp -Force
        Move-FileWithRetry -Source $tmp -Destination $CredentialPath

        $check = Get-SavedOneComCredential -Path $CredentialPath
        if ($check.UserName -ne $cred.UserName) { throw 'Det gemte login kunne ikke genindlæses korrekt.' }

        Write-Log "one.com-login er gemt krypteret: $CredentialPath" -Level Ok
        exit 0
    }
    catch {
        Write-Log "Kunne ikke gemme login: $($_.Exception.Message)" -Level Error
        exit 1
    }
}

Write-Log "Login blev ikke godkendt efter $MaxAttempts forsøg. Intet blev gemt." -Level Error
exit 1
