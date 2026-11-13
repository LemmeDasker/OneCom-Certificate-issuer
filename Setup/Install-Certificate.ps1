#requires -Version 5.1
<#
.SYNOPSIS
    Installerer automatisk Let's Encrypt-certifikat (one.com DNS) på denne PC.

.DESCRIPTION
    Start normalt med et dobbeltklik på Install.cmd.

    Installationen:
      1. Beder om administratorrettigheder (UAC), hvis nødvendigt.
      2. Finder og kan deaktivere en tidligere manuel opsætning.
      3. Opretter C:\Certificate med Scripts, Certificates, Hooks og Logs.
      4. Spørger efter domæne(r), kontakt-e-mail og one.com-domæne.
      5. Installerer Posh-ACME (kun hvis det mangler).
      6. Installerer OneCom-plugin'et i Posh-ACME.
      7. Gemmer og tester one.com-login (krypteret med DPAPI).
      8. Tester mod Let's Encrypt STAGING og bestiller derefter PRODUKTION.
      9. Opretter planlagte opgaver til automatisk fornyelse og test.

    Kan køres igen når som helst - fx efter en Posh-ACME-opdatering, ved
    nyt one.com-password eller for at ændre domæner. Trin, der allerede er
    udført, springes over eller genbruges.

.PARAMETER InstallPath
    Hovedmappe. Standard: C:\Certificate

.PARAMETER Domain
    Domæne(r) til certifikatet, adskilt af komma. Det første er hoveddomænet.

.PARAMETER Contact
    E-mail til Let's Encrypt (advarsler om udløb m.m.).

.PARAMETER OneComDomain
    Domænet (DNS-zonen) hos one.com, fx example.dk.

.PARAMETER SkipScheduledTasks
    Opret ikke planlagte opgaver.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\Certificate',
    [string[]]$Domain,
    [string]$Contact,
    [string]$OneComDomain,
    [switch]$SkipScheduledTasks,

    # Interne parametre (sættes ved genstart med administratorrettigheder)
    [switch]$Elevated,
    [string]$LaunchedBy
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$packageRoot = $PSScriptRoot
$InstallPath = $InstallPath.Trim().TrimEnd('\')

# ============================================================
# Kontrollér pakken (fx at ZIP-filen er pakket ud)
# ============================================================

$requiredFiles = @(
    'Scripts\CertificateCommon.ps1'
    'Scripts\Invoke-Certificate.ps1'
    'Scripts\Save-OneComCredential.ps1'
    'Scripts\OneCom.ps1'
    'Hooks\README.txt'
    'README.txt'
)

$missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $packageRoot $_) -PathType Leaf) })
if ($missingFiles.Count -gt 0) {
    Write-Host ''
    Write-Host 'Installationspakken er ikke komplet. Disse filer mangler:' -ForegroundColor Red
    $missingFiles | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Hvis du har åbnet en ZIP-fil, så pak hele ZIP-filen ud først og start Install.cmd igen.'
    exit 1
}

. (Join-Path $packageRoot 'Scripts\CertificateCommon.ps1')

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'Denne installation virker kun på Windows.' -ForegroundColor Red
    exit 1
}

if ($InstallPath -notmatch '^[A-Za-z]:\\.+') {
    Write-Host "Installationsmappen skal være en fuld sti på et lokalt drev, fx C:\Certificate (fik: '$InstallPath')." -ForegroundColor Red
    exit 1
}

# ============================================================
# Hjælpefunktioner
# ============================================================

function ConvertTo-QuotedArgument {
    param([string]$Value)

    if ($Value -notmatch '[\s"]' -and $Value -ne '') { return $Value }
    # Afsluttende backslash før " ville ellers escape anførselstegnet.
    return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Join-Arguments {
    param([string[]]$Arguments)
    return (@($Arguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' ')
}

function Test-IsNetworkPath {
    param([string]$Path)

    if ($Path.StartsWith('\\')) { return $true }
    try {
        $root = [IO.Path]::GetPathRoot($Path)
        return ((New-Object IO.DriveInfo $root).DriveType -eq [IO.DriveType]::Network)
    }
    catch {
        return $false
    }
}

function Invoke-SelfElevation {
    <#
        Starter installationen igen med administratorrettigheder.
        Netværksdrev (fx Z:) er ikke synlige for den forhøjede proces,
        så i så fald kopieres pakken midlertidigt til %TEMP%.
    #>
    $launchRoot = $packageRoot
    $tempCopy = $null

    if (Test-IsNetworkPath $packageRoot) {
        $tempCopy = Join-Path $env:TEMP ('CertificateSetup_' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $packageRoot -Destination $tempCopy -Recurse -Force
        $launchRoot = $tempCopy
        Write-Host "Pakken ligger på et netværksdrev og er kopieret midlertidigt til $tempCopy"
    }

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $launchRoot 'Install-Certificate.ps1'),
        '-Elevated',
        '-LaunchedBy', (Get-CurrentUserInfo).Name,
        '-InstallPath', $InstallPath
    )
    if ($Domain)             { $argList += '-Domain', ($Domain -join ',') }
    if ($Contact)            { $argList += '-Contact', $Contact }
    if ($OneComDomain)       { $argList += '-OneComDomain', $OneComDomain }
    if ($SkipScheduledTasks) { $argList += '-SkipScheduledTasks' }

    Write-Host ''
    Write-Host 'Installationen kræver administratorrettigheder.'
    Write-Host 'Godkend venligst Windows-dialogen (UAC). Installationen fortsætter i et nyt vindue.'

    try {
        $proc = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList (Join-Arguments $argList) -Verb RunAs -PassThru
        $null = $proc.Handle
        $proc.WaitForExit()
        $code = $proc.ExitCode
        if ($null -eq $code) { $code = 0 }
        return [int]$code
    }
    catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        if ($ex -is [ComponentModel.Win32Exception] -and $ex.NativeErrorCode -eq 1223) {
            Write-Host 'Du afviste administratorrettigheder. Installationen blev ikke udført.' -ForegroundColor Yellow
        }
        else {
            Write-Host "Kunne ikke starte med administratorrettigheder: $($ex.Message)" -ForegroundColor Red
        }
        return 1
    }
    finally {
        if ($tempCopy) { Remove-Item -LiteralPath $tempCopy -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Stop-Install {
    param([string]$Message)
    throw (New-Object System.OperationCanceledException $Message)
}

function Invoke-ChildScript {
    <#
        Kører et af scripts i <InstallPath>\Scripts i en separat Windows
        PowerShell-proces i samme konsolvindue og returnerer exitkoden.
    #>
    param([string]$Script, [string[]]$Arguments = @())

    $path = Join-Path $scriptsDir $Script
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path) + $Arguments

    $proc = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList (Join-Arguments $argList) `
        -WorkingDirectory $scriptsDir -NoNewWindow -Wait -PassThru
    return [int]$proc.ExitCode
}

function Read-Domains {
    param([string[]]$Default)

    while ($true) {
        $defText = if ($Default) { " [$($Default -join ', ')]" } else { '' }
        $answer = Read-Host "Domæne(r) til certifikatet, adskilt af komma$defText"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($Default) { return $Default }
            continue
        }

        $result = @()
        $bad = @()
        foreach ($d in ($answer -split '[,;\s]+' | Where-Object { $_ })) {
            $ascii = ConvertTo-AsciiDomain $d
            if ($null -eq $ascii) { $bad += $d } elseif ($result -notcontains $ascii) { $result += $ascii }
        }

        if ($bad.Count -gt 0) {
            Write-Host "  Ugyldigt domænenavn: $($bad -join ', ')" -ForegroundColor Yellow
            continue
        }
        if ($result.Count -gt 0) { return $result }
    }
}

function Read-Contact {
    param([string]$Default)

    while ($true) {
        $defText = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "Kontakt-e-mail til Let's Encrypt$defText"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        if (Test-EmailAddress $answer) { return $answer.Trim() }
        Write-Host '  Indtast en gyldig e-mailadresse.' -ForegroundColor Yellow
    }
}

function Read-OneComDomain {
    param([string]$Default, [string[]]$Domains)

    while ($true) {
        $defText = if ($Default) { " [$Default]" } else { '' }
        $answer = Read-Host "Domænet hos one.com (DNS-zonen)$defText"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }

        $zone = ConvertTo-AsciiDomain $answer
        if ($null -eq $zone -or $zone.StartsWith('*.')) {
            Write-Host '  Ugyldigt domæne.' -ForegroundColor Yellow
            continue
        }

        $outside = @($Domains | Where-Object { -not (Test-DomainInZone -Domain $_ -Zone $zone) })
        if ($outside.Count -gt 0) {
            Write-Host "  Disse domæner ligger ikke under $($zone): $($outside -join ', ')" -ForegroundColor Yellow
            continue
        }
        return $zone
    }
}

function Get-DefaultZone {
    param([string]$Domain)
    $labels = ($Domain -replace '^\*\.', '').Split('.')
    if ($labels.Count -le 2) { return ($labels -join '.') }
    return ($labels[-2..-1] -join '.')
}

function Test-ZoneCoversDomains {
    param([string]$Zone, [string[]]$Domains)
    if (-not $Zone) { return $false }
    return (@($Domains | Where-Object { -not (Test-DomainInZone -Domain $_ -Zone $Zone) }).Count -eq 0)
}

function Install-PoshAcme {
    Enable-Tls12

    Write-Log 'Kontrollerer forbindelse til PowerShell Gallery...'
    try {
        $null = Invoke-WebRequest -Uri 'https://www.powershellgallery.com/api/v2' -UseBasicParsing -TimeoutSec 30
    }
    catch {
        Stop-Install ("Kan ikke nå PowerShell Gallery (www.powershellgallery.com). Kontrollér " +
                      "internetforbindelse/proxy. Detaljer: $($_.Exception.Message)")
    }

    $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'2.8.5.201' }
    if (-not $nuget) {
        Write-Log 'Installerer NuGet-pakkeudbyder...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force | Out-Null
    }

    Write-Log 'Installerer Posh-ACME fra PowerShell Gallery (for alle brugere)...'
    Install-Module -Name Posh-ACME -Repository PSGallery -Scope AllUsers -Force -ErrorAction Stop
}

function Get-PlainText {
    param([Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$script:TaskPath           = '\Certificate\'
$script:ProductionTaskName = 'Fornyelse (produktion)'
$script:StagingTaskName    = 'Test (staging)'

function Register-CertificateTasks {
    param([string]$User)

    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $scriptsDir 'Invoke-Certificate.ps1'

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RunOnlyIfNetworkAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $tasks = @(
        [pscustomobject]@{
            Name        = $script:ProductionTaskName
            Environment = 'Production'
            Trigger     = (New-ScheduledTaskTrigger -Daily -At '03:00' -RandomDelay (New-TimeSpan -Minutes 60))
            Description = "Fornyer Let's Encrypt-certifikatet, når det er nødvendigt, og kopierer det til $certsDir."
        }
        [pscustomobject]@{
            Name        = $script:StagingTaskName
            Environment = 'Staging'
            Trigger     = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:30' -RandomDelay (New-TimeSpan -Minutes 60))
            Description = "Ugentligt sundhedstjek mod Let's Encrypt STAGING. Ændrer ikke certifikatet i $certsDir."
        }
    )

    Write-Host ''
    Write-Host "Opgaverne skal køre som $User - også når du ikke er logget på."
    Write-Host 'Det kræver Windows-adgangskoden til denne konto (ikke PIN-koden).'
    Write-Host 'Bruger du en Microsoft-konto, er det adgangskoden til Microsoft-kontoen.'
    Write-Host 'Lader du feltet stå tomt, kører opgaverne kun, når du er logget på.'

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $secure = Read-Host "Windows-adgangskode for $User" -AsSecureString
        $interactive = ($secure.Length -eq 0)

        try {
            foreach ($t in $tasks) {
                $action = New-ScheduledTaskAction -Execute $ps -WorkingDirectory $scriptsDir `
                    -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Environment $($t.Environment)")

                $common = @{
                    TaskName    = $t.Name
                    TaskPath    = $script:TaskPath
                    Action      = $action
                    Trigger     = $t.Trigger
                    Settings    = $settings
                    Description = $t.Description
                    Force       = $true
                    ErrorAction = 'Stop'
                }

                if ($interactive) {
                    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
                    Register-ScheduledTask @common -Principal $principal | Out-Null
                }
                else {
                    Register-ScheduledTask @common -User $User -Password (Get-PlainText $secure) -RunLevel Highest | Out-Null
                }

                Write-Log "Opgave oprettet: $($script:TaskPath)$($t.Name)" -Level Ok
            }

            if ($interactive) {
                Write-Log 'Opgaverne kører kun, når du er logget på. Kør Install.cmd igen for at ændre det.' -Level Warn
            }
            return
        }
        catch {
            Write-Log "Kunne ikke oprette opgaven: $($_.Exception.Message)" -Level Error
            if ($interactive) { throw }
            Write-Log 'Adgangskoden er sandsynligvis forkert. Prøv igen.' -Level Warn
        }
        finally {
            $secure.Dispose()
        }
    }

    Stop-Install 'De planlagte opgaver kunne ikke oprettes. Kør Install.cmd igen.'
}

function Test-ProductionTask {
    Write-Log 'Starter produktionsopgaven én gang for at teste den (fornyer kun, hvis det er nødvendigt)...'

    $before = Get-Date
    Start-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:ProductionTaskName

    $deadline = (Get-Date).AddMinutes(15)
    Start-Sleep -Seconds 5
    while ((Get-Date) -lt $deadline) {
        $task = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:ProductionTaskName
        $info = Get-ScheduledTaskInfo -TaskPath $script:TaskPath -TaskName $script:ProductionTaskName

        if ($task.State -ne 'Running' -and $info.LastRunTime -ge $before.AddSeconds(-5)) {
            switch ($info.LastTaskResult) {
                0 { Write-Log 'Opgaven kørte uden fejl.' -Level Ok; return $true }
                2 { Write-Log 'Opgaven kørte, men et hook fejlede. Se loggen i Logs-mappen.' -Level Warn; return $true }
                default {
                    Write-Log ("Opgaven fejlede (resultat 0x{0:X}). Se STATUS.txt og Logs-mappen." -f $info.LastTaskResult) -Level Error
                    return $false
                }
            }
        }
        Start-Sleep -Seconds 3
    }

    Write-Log 'Opgaven blev ikke færdig inden for 15 minutter. Se Logs-mappen senere.' -Level Warn
    return $false
}

# ============================================================
# Administratorrettigheder (UAC) og Windows PowerShell 5.1
# ============================================================

if (-not (Test-IsAdministrator) -or $PSVersionTable.PSEdition -eq 'Core') {
    if ($Elevated) {
        Write-Host 'Installationen kører stadig ikke som administrator. Log ind med en administratorkonto og prøv igen.' -ForegroundColor Red
        Read-Host 'Tryk Enter for at lukke vinduet' | Out-Null
        exit 1
    }
    exit (Invoke-SelfElevation)
}

# ============================================================
# Selve installationen
# ============================================================

$exitCode     = 0
$transcribing = $false
$doProduction = $false
$me           = Get-CurrentUserInfo
$scriptsDir   = Join-Path $InstallPath 'Scripts'
$certsDir     = Join-Path $InstallPath 'Certificates'
$hooksDir     = Join-Path $InstallPath 'Hooks'
$logsDir      = Join-Path $InstallPath 'Logs'
$configPath   = Join-Path $InstallPath 'config.json'

try { $Host.UI.RawUI.WindowTitle = 'Certifikat - installation' } catch { }

try {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host " Let's Encrypt-certifikat via one.com - installation" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan

    # --------------------------------------------------------
    Write-Step '1/9 Bruger og system'
    # --------------------------------------------------------

    Write-Host "Computer          : $env:COMPUTERNAME"
    Write-Host "Windows-bruger    : $($me.Name)"
    Write-Host "Installationsmappe: $InstallPath"
    Write-Host ''
    Write-Host 'one.com-login, certifikater og planlagte opgaver tilknyttes denne Windows-bruger.'

    if ($LaunchedBy -and $LaunchedBy -ne $me.Name) {
        Write-Host ''
        Write-Host "BEMÆRK: Du startede installationen som $LaunchedBy, men godkendte UAC med kontoen $($me.Name)." -ForegroundColor Yellow
        Write-Host "Opsætningen tilknyttes derfor $($me.Name). Certifikatopgaverne kører som $($me.Name)," -ForegroundColor Yellow
        Write-Host "og det er den kontos Windows-adgangskode, der skal bruges senere." -ForegroundColor Yellow
    }

    if (-not (Read-YesNo 'Fortsæt?' $true)) { Stop-Install 'Afbrudt af brugeren.' }

    # --------------------------------------------------------
    Write-Step '2/9 Tidligere opsætning'
    # --------------------------------------------------------

    $legacyTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
        $_.TaskPath -ne $script:TaskPath -and
        ((@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match 'one-(production|staging)(-test)?\.ps1'
    })

    $legacyTasksActive = $false
    if ($legacyTasks.Count -gt 0) {
        Write-Host 'Der findes planlagte opgaver fra den tidligere, manuelle opsætning:' -ForegroundColor Yellow
        $legacyTasks | ForEach-Object { Write-Host "  $($_.TaskPath)$($_.TaskName)  [$($_.State)]" }
        Write-Host 'De bør deaktiveres, så de ikke kører samtidig med den nye opsætning.'
        Write-Host 'OBS: one-production.ps1 kopierede også certifikatet til WAMP/Apache. Det gør den nye'
        Write-Host '     opsætning ikke af sig selv - brug et hook (se Hooks\README.txt).'

        if (Read-YesNo 'Deaktivér de gamle opgaver?' $true) {
            foreach ($t in $legacyTasks) {
                Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName | Out-Null
                Write-Log "Deaktiveret: $($t.TaskPath)$($t.TaskName)" -Level Ok
            }
        }
        else {
            $legacyTasksActive = @($legacyTasks | Where-Object { $_.State -ne 'Disabled' }).Count -gt 0
        }
    }
    else {
        Write-Log 'Ingen gamle planlagte opgaver fundet.'
    }

    $legacyNames = @('one-production.ps1', 'one-staging.ps1', 'one-production-test.ps1',
                     'one-staging-test.ps1', 'save-onecom-credential.ps1', 'OneCom.ps1')
    $legacyFiles = @($legacyNames | ForEach-Object { Join-Path $InstallPath $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })

    if ($legacyFiles.Count -gt 0) {
        if ($legacyTasksActive) {
            Write-Log "Gamle scripts i $InstallPath bliver liggende, fordi gamle opgaver stadig er aktive." -Level Warn
        }
        else {
            Write-Host "Der ligger gamle scripts direkte i $($InstallPath):"
            $legacyFiles | ForEach-Object { Write-Host "  $(Split-Path -Leaf $_)" }
            if (Read-YesNo 'Flyt dem til en Arkiv-mappe, så de ikke forveksles med de nye?' $true) {
                $archive = Join-Path $InstallPath ('Arkiv\{0:yyyyMMdd_HHmmss}' -f (Get-Date))
                New-Item -ItemType Directory -Path $archive -Force | Out-Null
                $legacyFiles | ForEach-Object { Move-Item -LiteralPath $_ -Destination $archive -Force }
                Write-Log "Flyttet til $archive" -Level Ok
            }
        }
    }

    # --------------------------------------------------------
    Write-Step "3/9 Mapper og filer i $InstallPath"
    # --------------------------------------------------------

    $parent = Split-Path -Parent $InstallPath
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        Stop-Install "Mappen $parent findes ikke. Vælg en anden installationsmappe."
    }

    $packageFull = (Resolve-Path -LiteralPath $packageRoot).ProviderPath.TrimEnd('\')
    if ($packageFull -ieq $InstallPath -or $packageFull.StartsWith("$InstallPath\", [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Install "Installationspakken må ikke ligge i $InstallPath. Flyt pakken (fx til Overførsler/Downloads) og start Install.cmd igen."
    }

    foreach ($d in @($InstallPath, $scriptsDir, $certsDir, $hooksDir, $logsDir)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    try {
        Start-Transcript -LiteralPath (Join-Path $logsDir ('install_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))) -Force | Out-Null
        $transcribing = $true
    }
    catch {
        Write-Log "Kunne ikke starte installationslog: $($_.Exception.Message)" -Level Warn
    }

    # Scripts overskrives altid med pakkens version.
    Get-ChildItem -LiteralPath (Join-Path $packageRoot 'Scripts') -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $scriptsDir -Force
    }

    # Hooks: README og eksempler opdateres; brugerens egne *.ps1-hooks røres aldrig.
    Get-ChildItem -LiteralPath (Join-Path $packageRoot 'Hooks') -File |
        Where-Object { $_.Extension -ne '.ps1' } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $hooksDir -Force
        }

    Copy-Item -LiteralPath (Join-Path $packageRoot 'README.txt') -Destination $InstallPath -Force

    Get-ChildItem -LiteralPath $InstallPath -Recurse -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    Write-Log 'Begrænser adgang til mappen (SYSTEM, Administratorer og dig)...'
    Set-RestrictedAcl -Path $InstallPath -UserSid $me.Sid
    Write-Log "Mappestruktur klar: $InstallPath" -Level Ok

    # --------------------------------------------------------
    Write-Step '4/9 Indstillinger'
    # --------------------------------------------------------

    $old = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $old = Read-CertConfig -Path $configPath
            Write-Log 'Eksisterende indstillinger fundet - tryk Enter for at beholde værdien i [ ].'
        }
        catch {
            Write-Log "Eksisterende config.json kunne ikke bruges: $($_.Exception.Message)" -Level Warn
        }
    }

    $domains = $null
    if ($Domain) {
        $parsed = @($Domain | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { ConvertTo-AsciiDomain $_ })
        if ($parsed.Count -gt 0 -and -not ($parsed -contains $null)) { $domains = @($parsed | Select-Object -Unique) }
        else { Write-Log "Ugyldigt domæne angivet med -Domain: $($Domain -join ', ')" -Level Warn }
    }
    if (-not $domains) { $domains = @(Read-Domains -Default $(if ($old) { $old.Domains } else { $null })) }

    if ($Contact -and (Test-EmailAddress $Contact)) { $contactValue = $Contact.Trim() }
    else { $contactValue = Read-Contact -Default $(if ($old) { $old.Contact } else { '' }) }

    $zoneInput = ConvertTo-AsciiDomain $OneComDomain
    if ($zoneInput -and -not $zoneInput.StartsWith('*.') -and (Test-ZoneCoversDomains $zoneInput $domains)) {
        $zone = $zoneInput
    }
    else {
        $zoneDefault = if ($old -and (Test-ZoneCoversDomains $old.OneComDomain $domains)) { $old.OneComDomain } else { Get-DefaultZone $domains[0] }
        $zone = Read-OneComDomain -Default $zoneDefault -Domains $domains
    }

    Write-Host ''
    Write-Host "  Domæner        : $($domains -join ', ')  (hoveddomæne: $($domains[0]))"
    Write-Host "  Kontakt-e-mail : $contactValue"
    Write-Host "  one.com-domæne : $zone"
    if (-not (Read-YesNo 'Er det korrekt?' $true)) { Stop-Install 'Afbrudt. Kør Install.cmd igen for at indtaste nye værdier.' }

    $configObject = [ordered]@{
        Domains            = @($domains)
        Contact            = $contactValue
        OneComDomain       = $zone
        DnsSleep           = $(if ($old) { $old.DnsSleep } else { 120 })
        ValidationTimeout  = $(if ($old) { $old.ValidationTimeout } else { 300 })
        LogRetentionDays   = $(if ($old) { $old.LogRetentionDays } else { 30 })
        HookTimeoutSeconds = $(if ($old) { $old.HookTimeoutSeconds } else { 300 })
        CertificateUser    = $me.Name
        CertificateUserSid = $me.Sid
    }
    $configObject | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $cfg = Read-CertConfig -Path $configPath
    Write-Log "Gemt: $configPath" -Level Ok

    if ($old -and $old.MainDomain -ne $cfg.MainDomain) {
        Write-Log "Hoveddomænet er ændret fra $($old.MainDomain). Den gamle mappe under Certificates fornyes ikke længere." -Level Warn
    }

    # --------------------------------------------------------
    Write-Step '5/9 Posh-ACME'
    # --------------------------------------------------------

    $installed = @(Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending)
    if ($installed.Count -gt 0 -and $installed[0].Version -ge $script:MinPoshAcmeVersion) {
        Write-Log "Posh-ACME $($installed[0].Version) er allerede installeret - opdateres ikke." -Level Ok
    }
    else {
        if ($installed.Count -gt 0) {
            Write-Log "Posh-ACME $($installed[0].Version) er for gammel - installerer nyeste version." -Level Warn
        }
        Install-PoshAcme
        $installed = @(Get-Module -ListAvailable -Name Posh-ACME | Sort-Object Version -Descending)
        if ($installed.Count -eq 0) { Stop-Install 'Posh-ACME blev ikke installeret korrekt.' }
        Write-Log "Posh-ACME $($installed[0].Version) installeret." -Level Ok
    }

    # --------------------------------------------------------
    Write-Step '6/9 OneCom-plugin'
    # --------------------------------------------------------

    $pluginSource = Join-Path $scriptsDir 'OneCom.ps1'
    $n = Install-OneComPlugin -PluginSource $pluginSource
    if ($n -eq 0) { Write-Log 'Plugin''et er allerede opdateret.' }
    $module = Import-PoshAcmeWithPlugin -PluginSource $pluginSource
    Write-Log "Posh-ACME $($module.Version) finder OneCom-plugin'et." -Level Ok

    # --------------------------------------------------------
    Write-Step '7/9 one.com-login'
    # --------------------------------------------------------

    $credOk = $false
    if (Test-Path -LiteralPath (Get-DefaultCredentialPath) -PathType Leaf) {
        $rc = Invoke-ChildScript 'Save-OneComCredential.ps1' @('-OneComDomain', $zone, '-VerifyOnly')
        if ($rc -eq 0) {
            $credOk = Read-YesNo 'Behold det gemte one.com-login?' $true
        }
        else {
            Write-Log 'Det gemte login virker ikke og skal indtastes igen.' -Level Warn
        }
    }

    if (-not $credOk) {
        $rc = Invoke-ChildScript 'Save-OneComCredential.ps1' @('-OneComDomain', $zone)
        if ($rc -ne 0) { Stop-Install 'one.com-login blev ikke gemt. Kør Install.cmd igen, når du har det rigtige login.' }
    }

    # --------------------------------------------------------
    Write-Step '8/9 Certifikat: test (staging) og derefter produktion'
    # --------------------------------------------------------

    Write-Log "Test mod Let's Encrypt STAGING. Det tager typisk 3-5 minutter - luk ikke vinduet."
    $rc = Invoke-ChildScript 'Invoke-Certificate.ps1' @('-Environment', 'Staging', '-NewOrder')
    if ($rc -ne 0) {
        Stop-Install ("Staging-testen fejlede, så der bestilles IKKE et rigtigt certifikat. " +
                      "Se fejlen ovenfor og loggen i $logsDir. Ret fejlen og kør Install.cmd igen.")
    }
    Write-Log 'Staging-testen lykkedes.' -Level Ok

    # Findes der allerede et gyldigt produktionscertifikat for de samme domæner?
    $existingProd = $null
    try {
        Set-PAServer LE_PROD -ErrorAction Stop
        $o = Get-PAOrder -MainDomain $cfg.MainDomain -ErrorAction Stop
        if (Test-OrderMatchesDomains $o $cfg.Domains) {
            $c = Get-PACertificate -MainDomain $cfg.MainDomain -ErrorAction Stop
            if ($c -and $c.NotAfter -gt (Get-Date)) { $existingProd = $c }
        }
    }
    catch { $existingProd = $null }

    $doProduction = $true
    if ($existingProd) {
        Write-Log "Der findes allerede et gyldigt produktionscertifikat (udløber $($existingProd.NotAfter)). Det genbruges." -Level Ok
    }
    else {
        Write-Host ''
        Write-Host "Nu bestilles et RIGTIGT certifikat hos Let's Encrypt for: $($cfg.Domains -join ', ')" -ForegroundColor Yellow
        Write-Host "Let's Encrypt begrænser antallet af forsøg. Staging-testen er OK, så det er sikkert at fortsætte."
        $answer = Read-Host 'Skriv PROD for at fortsætte (eller tryk Enter for at stoppe her)'
        $doProduction = ($answer.Trim() -ceq 'PROD')
    }

    if (-not $doProduction) {
        Write-Log 'Produktionscertifikat blev ikke bestilt. Kør Install.cmd igen, når du er klar.' -Level Warn
        Write-Log 'Planlagte opgaver oprettes først, når der er et produktionscertifikat.' -Level Warn
    }
    else {
        $rc = Invoke-ChildScript 'Invoke-Certificate.ps1' @('-Environment', 'Production')
        if ($rc -eq 1) {
            Stop-Install "Produktionscertifikatet kunne ikke bestilles/fornyes. Se fejlen ovenfor og loggen i $logsDir."
        }
        if ($rc -eq 2) {
            Write-Log 'Certifikatet er OK, men et hook fejlede. Se loggen i Logs-mappen.' -Level Warn
        }
        Write-Log "Certifikatet ligger i $certsDir\$(Get-SafeFolderName $cfg.MainDomain)" -Level Ok

        # ----------------------------------------------------
        Write-Step '9/9 Automatisk fornyelse (Opgavestyring)'
        # ----------------------------------------------------

        if ($SkipScheduledTasks) {
            Write-Log 'Springer planlagte opgaver over (-SkipScheduledTasks).' -Level Warn
        }
        else {
            Register-CertificateTasks -User $me.Name
            if (-not (Test-ProductionTask)) {
                $exitCode = 1
                Write-Log 'Opgaven er oprettet, men testkørslen lykkedes ikke. Se STATUS.txt og Logs-mappen.' -Level Warn
            }
        }
    }

    # --------------------------------------------------------
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ' Installationen er færdig' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Certifikater : $certsDir"
    Write-Host "  Status       : $(Join-Path $InstallPath 'STATUS.txt')"
    Write-Host "  Hooks        : $hooksDir  (se README.txt der)"
    Write-Host "  Logfiler     : $logsDir"
    Write-Host "  Vejledning   : $(Join-Path $InstallPath 'README.txt')"
    Write-Host ''

    if ($doProduction -and (Read-YesNo 'Åbn certifikatmappen nu?' $true)) {
        Start-Process explorer.exe -ArgumentList (ConvertTo-QuotedArgument $certsDir)
    }
}
catch [System.OperationCanceledException] {
    $exitCode = 1
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Yellow
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host 'Installationen fejlede:' -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host "  $(($_.InvocationInfo.PositionMessage -split "`r?`n")[0])"
    }
    Write-Host ''
    Write-Host 'Ret fejlen og kør Install.cmd igen. Trin, der allerede er udført, genbruges.'
}
finally {
    if ($transcribing) { try { Stop-Transcript | Out-Null } catch { } }

    if ($Elevated) {
        Write-Host ''
        Read-Host 'Tryk Enter for at lukke vinduet' | Out-Null
    }
}

exit $exitCode
