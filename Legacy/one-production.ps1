#requires -Version 5.1
<#
.SYNOPSIS
    Ubetjent one.com / Posh-ACME certifikatkørsel mod Let's Encrypt PRODUKTION.

.DESCRIPTION
    Kan startes af Opgavestyring (Task Scheduler). Ingen interaktion kræves.
    Bruger altid LE_PROD. Output skrives til en logfil.
    Exitkode 0 = succes / ingen fornyelse nødvendig, exitkode 1 = fejl.

    Når certifikatet i Posh-ACME afviger fra det, Apache bruger, kopieres
    det til WAMP, Apache-konfigurationen valideres med 'httpd -t', og
    Apache-servicen genstartes. Fejler valideringen, gendannes de gamle filer.

    Genstart af servicen kræver administratorrettigheder. Opgaven i
    Task Scheduler skal derfor køre med "højeste rettigheder".

    Den manuelle variant (med bekræftelse) er one-production-test.ps1.

    Let's Encrypt produktion har rate limits
    (5 fejlede autorisationer pr. konto/værtsnavn/time).
    Scriptet fornyer derfor kun, når certifikatet er ved at udløbe.

.PARAMETER Force
    Gennemtving fornyelse, selvom certifikatet ikke er ved at udløbe.
    Brug med omtanke på grund af rate limits.

.PARAMETER WampSslDirectory
    Mappe som Apache læser certifikatet fra (se Apache/httpd-vhosts.conf).

.PARAMETER ApacheServiceName
    Navnet på Apache-servicen i WAMP.

.PARAMETER ApacheHttpdPath
    Sti til httpd.exe. Hvis tom, findes den nyeste version under C:\wamp64\bin\apache.

.PARAMETER SkipDeploy
    Spring kopiering til WAMP og genstart af Apache over.
#>
[CmdletBinding()]
param(
    [string]$Domain = 'www.mydomain.com',
    [string]$Contact = 'mail@box.com',
    [string]$CredentialPath = (Join-Path $env:LOCALAPPDATA 'Posh-ACME\Secrets\OneComCredential.xml'),
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'Posh-ACME\Logs'),
    [int]$LogRetentionDays = 30,
    [string]$WampSslDirectory = 'C:\wamp64\ssl\www.mydomain.com',
    [string]$ApacheServiceName = 'wampapache64',
    [string]$ApacheHttpdPath = '',
    [switch]$SkipDeploy,
    [switch]$Force
)

# Fast server for denne fil - PRODUKTION
$Server    = 'LE_PROD'
$LogPrefix = 'onecom-acme-prod'

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

function Test-FileDiffers {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { return $true }
    $a = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    return ($a -ne $b)
}

function Find-ApacheHttpd {
    $root = 'C:\wamp64\bin\apache'
    if (-not (Test-Path -LiteralPath $root)) { return $null }

    $candidate = Get-ChildItem -LiteralPath $root -Directory -Filter 'apache*' |
        ForEach-Object {
            $v = $null
            if ([version]::TryParse(($_.Name -replace '^apache', ''), [ref]$v)) {
                [pscustomobject]@{ Version = $v; Path = (Join-Path $_.FullName 'bin\httpd.exe') }
            }
        } |
        Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($candidate) { return $candidate.Path }
    return $null
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$exitCode = 0

Write-Log '============================================================'
Write-Log ' one.com / Posh-ACME PRODUKTION automatiseret kørsel'
Write-Log '============================================================'

try {

    # ------------------------------------------------------------
    # 1. Indlæs Posh-ACME og verificér OneCom-plugin
    # ------------------------------------------------------------

    Write-Log '[1/10] Importerer Posh-ACME...'

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
    # 2. Vælg Let's Encrypt PRODUKTION
    # ------------------------------------------------------------

    Write-Log '[2/10] Vælger Let''s Encrypt PRODUKTION...'

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

    Write-Log '[3/10] Validerer ACME-kontakt-e-mail...'

    if ([string]::IsNullOrWhiteSpace($Contact)) {
        throw 'Parameteren -Contact er tom.'
    }

    Write-Log "      Kontakt: $Contact"

    # ------------------------------------------------------------
    # 4. Indlæs krypteret one.com-legitimation
    # ------------------------------------------------------------

    Write-Log '[4/10] Indlæser krypteret one.com-legitimation...'
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
    }

    # ------------------------------------------------------------
    # 5. Bestil nyt certifikat eller forny eksisterende
    #    one.com TTL er 3600, så DNS-propagering er langsom.
    #    Hvis valideringen timer ud, så hæv -DnsSleep.
    # ------------------------------------------------------------

    Write-Log "[5/10] Behandler PRODUKTIONS-certifikat for $Domain..."

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

    Write-Log '[6/10] Læser resulterende certifikat...'

    $certificate = Get-PACertificate -MainDomain $Domain -ErrorAction Stop
    if ($null -eq $certificate) {
        throw 'Get-PACertificate returnerede ikke et certifikatobjekt.'
    }

    # ------------------------------------------------------------
    # 7. Log certifikatdetaljer
    # ------------------------------------------------------------

    Write-Log '[7/10] Certifikatdetaljer'
    Write-Log "      Subject      : $($certificate.Subject)"
    Write-Log "      NotAfter     : $($certificate.NotAfter)"
    Write-Log "      CertFile     : $($certificate.CertFile)"
    Write-Log "      KeyFile      : $($certificate.KeyFile)"
    Write-Log "      FullChainFile: $($certificate.FullChainFile)"

    # ------------------------------------------------------------
    # 8. Kopiér certifikatet til WAMP, hvis det er ændret
    #    Apache/WAMP: SSLCertificateFile    -> fullchain.cer
    #                 SSLCertificateKeyFile -> cert.key
    # ------------------------------------------------------------

    Write-Log '[8/10] Kontrollerer certifikat i WAMP...'

    $restartNeeded = $false

    if ($SkipDeploy) {
        Write-Log '      -SkipDeploy angivet - springer kopiering og genstart over.'
    }
    else {
        $dstFull = Join-Path $WampSslDirectory 'fullchain.cer'
        $dstKey  = Join-Path $WampSslDirectory 'cert.key'

        Write-Log "      Mål: $WampSslDirectory"

        $fullDiffers = Test-FileDiffers -Source $certificate.FullChainFile -Destination $dstFull
        $keyDiffers  = Test-FileDiffers -Source $certificate.KeyFile       -Destination $dstKey

        if (-not ($fullDiffers -or $keyDiffers)) {
            Write-Log '      WAMP bruger allerede det aktuelle certifikat. Ingen kopiering.'
        }
        else {
            $httpd = $ApacheHttpdPath
            if ([string]::IsNullOrWhiteSpace($httpd)) { $httpd = Find-ApacheHttpd }
            if ([string]::IsNullOrWhiteSpace($httpd) -or -not (Test-Path -LiteralPath $httpd -PathType Leaf)) {
                throw 'httpd.exe blev ikke fundet. Angiv -ApacheHttpdPath.'
            }
            Write-Log "      httpd.exe: $httpd"

            if (-not (Test-IsAdministrator)) {
                throw 'Scriptet kører ikke med administratorrettigheder, så Apache kan ikke genstartes. Sæt opgaven til "Kør med højeste rettigheder".'
            }

            New-Item -ItemType Directory -Path $WampSslDirectory -Force | Out-Null

            # Backup af eksisterende filer
            $stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
            $backups = @()
            foreach ($f in @($dstFull, $dstKey)) {
                if (Test-Path -LiteralPath $f -PathType Leaf) {
                    $bak = "$f.$stamp.bak"
                    Copy-Item -LiteralPath $f -Destination $bak -Force
                    $backups += [pscustomobject]@{ Original = $f; Backup = $bak }
                    Write-Log "      Backup: $bak"
                }
            }

            Copy-Item -LiteralPath $certificate.FullChainFile -Destination $dstFull -Force
            Copy-Item -LiteralPath $certificate.KeyFile       -Destination $dstKey  -Force
            Write-Log '      Nyt certifikat kopieret til WAMP.'

            # Validér Apache-konfiguration
            Write-Log '      Validerer Apache-konfiguration (httpd -t)...'
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $testOutput = & $httpd -t 2>&1 | ForEach-Object { "$_" }
            $testExit = $LASTEXITCODE
            $ErrorActionPreference = $prevEap

            foreach ($line in $testOutput) { Write-Log "        $line" }

            if ($testExit -ne 0) {
                Write-Log '      Konfigurationstest fejlede - gendanner tidligere filer.'
                foreach ($b in $backups) {
                    Copy-Item -LiteralPath $b.Backup -Destination $b.Original -Force
                }
                throw "httpd -t fejlede (exitkode $testExit). Apache blev ikke genstartet, og de tidligere certifikatfiler er gendannet."
            }

            # Ryd gamle backups op
            Get-ChildItem -LiteralPath $WampSslDirectory -Filter '*.bak' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
                Remove-Item -Force -ErrorAction SilentlyContinue

            $restartNeeded = $true
        }
    }

    # ------------------------------------------------------------
    # 9. Genstart Apache
    # ------------------------------------------------------------

    Write-Log '[9/10] Apache-genstart...'

    if (-not $restartNeeded) {
        Write-Log '      Ikke nødvendig.'
    }
    else {
        $svc = Get-Service -Name $ApacheServiceName -ErrorAction Stop
        Write-Log "      Service: $($svc.Name) (status: $($svc.Status))"

        Restart-Service -Name $ApacheServiceName -Force -ErrorAction Stop

        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(60))
        $svc.Refresh()

        if ($svc.Status -ne 'Running') {
            throw "Apache-servicen $ApacheServiceName kører ikke efter genstart (status: $($svc.Status))."
        }

        Write-Log '      Apache genstartet og kører.'
    }

    # ------------------------------------------------------------
    # 10. Resultat
    # ------------------------------------------------------------

    Write-Log '[10/10] RESULTAT (PRODUKTION): SUCCESS'
}
catch {
    $exitCode = 1
    Write-Log '[!] RESULTAT (PRODUKTION): FAILED'
    Write-Log "    $($_.Exception.Message)"
    Write-Log "    $($_.ScriptStackTrace)"
    Write-Log '    Husk: Let''s Encrypt produktion har rate limits. Undersøg årsagen før nyt forsøg.'
}
finally {
    Get-ChildItem -LiteralPath $LogDirectory -Filter "$($LogPrefix)_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Stop-Transcript | Out-Null
}

exit $exitCode
