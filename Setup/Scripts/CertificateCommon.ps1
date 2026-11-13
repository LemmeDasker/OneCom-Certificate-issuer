#requires -Version 5.1
<#
.SYNOPSIS
    Fælles funktioner til certifikat-scripts (one.com / Posh-ACME).

.DESCRIPTION
    Dot-sources af Install-Certificate.ps1, Invoke-Certificate.ps1 og
    Save-OneComCredential.ps1. Indeholder ingen kode, der kører af sig selv.
#>

# ============================================================
# Konstanter
# ============================================================

$script:CertMutexName        = 'Global\Certificate-OneCom-PoshACME'
$script:MinPoshAcmeVersion   = [version]'4.0.0'
$script:SidLocalSystem       = 'S-1-5-18'
$script:SidAdministrators    = 'S-1-5-32-544'

# ============================================================
# Logning og brugerdialog
# ============================================================

function Write-Log {
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [string]$Message = '',

        [ValidateSet('Info', 'Ok', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message

    switch ($Level) {
        'Ok'    { Write-Host $line -ForegroundColor Green }
        'Warn'  { Write-Host $line -ForegroundColor Yellow }
        'Error' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { '[J/n]' } else { '[j/N]' }

    while ($true) {
        $answer = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }

        switch -Regex ($answer.Trim()) {
            '^(j|ja|y|yes)$' { return $true }
            '^(n|nej|no)$'   { return $false }
        }

        Write-Host '  Svar venligst J (ja) eller N (nej).' -ForegroundColor Yellow
    }
}

# ============================================================
# System og bruger
# ============================================================

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CurrentUserInfo {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return [pscustomobject]@{
        Name = $id.Name
        Sid  = $id.User.Value
    }
}

function Get-WindowsPowerShellPath {
    # Plugin'et bruger Windows PowerShell 5.1-specifikke egenskaber
    # (BaseResponse.ResponseUri), så PowerShell 7 (pwsh) kan ikke bruges.
    $sysDir = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $sysDir = 'Sysnative'
    }

    $path = Join-Path $env:SystemRoot "$sysDir\WindowsPowerShell\v1.0\powershell.exe"

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell blev ikke fundet: $path"
    }

    return $path
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Log "Kunne ikke aktivere TLS 1.2: $($_.Exception.Message)" -Level Warn
    }
}

# ============================================================
# Domæner
# ============================================================

function ConvertTo-AsciiDomain {
    <#
        Normaliserer et domænenavn: små bogstaver, uden afsluttende punktum,
        og internationale navne (fx æøå) konverteres til punycode.
        Returnerer $null, hvis navnet ikke er gyldigt.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $n = $Name.Trim().TrimEnd('.').ToLowerInvariant()
    $wildcard = $false

    if ($n.StartsWith('*.')) {
        $wildcard = $true
        $n = $n.Substring(2)
    }

    try {
        $n = (New-Object System.Globalization.IdnMapping).GetAscii($n)
    }
    catch {
        return $null
    }

    $label = '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    if ($n -notmatch "^($label\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$") { return $null }
    if ($n.Length -gt 253) { return $null }

    if ($wildcard) { return "*.$n" }
    return $n
}

function Test-DomainInZone {
    param(
        [Parameter(Mandatory = $true)][string]$Domain,
        [Parameter(Mandatory = $true)][string]$Zone
    )

    $d = $Domain -replace '^\*\.', ''
    return ($d -eq $Zone -or $d.EndsWith(".$Zone"))
}

function Get-SafeFolderName {
    param([Parameter(Mandatory = $true)][string]$Domain)

    $name = $Domain -replace '^\*\.', 'wildcard.'
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$c, '_')
    }
    return $name
}

# ============================================================
# Konfiguration (config.json)
# ============================================================

function Get-ConfigValue {
    param($Config, [string]$Name, $Default)

    if ($null -ne $Config -and $Config.PSObject.Properties[$Name] -and
        $null -ne $Config.$Name -and "$($Config.$Name)" -ne '') {
        return $Config.$Name
    }
    return $Default
}

function Read-CertConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Konfigurationsfilen blev ikke fundet: $Path. Kør Install.cmd igen."
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Konfigurationsfilen kunne ikke læses ($Path): $($_.Exception.Message)"
    }

    $domains = @()
    foreach ($d in @(Get-ConfigValue $cfg 'Domains' @())) {
        $ascii = ConvertTo-AsciiDomain $d
        if ($null -eq $ascii) { throw "Ugyldigt domænenavn i $($Path): '$d'" }
        if ($domains -notcontains $ascii) { $domains += $ascii }
    }

    if ($domains.Count -eq 0) { throw "Ingen domæner angivet i $Path." }

    $zone = ConvertTo-AsciiDomain (Get-ConfigValue $cfg 'OneComDomain' '')
    if ($null -eq $zone -or $zone.StartsWith('*.')) {
        throw "OneComDomain mangler eller er ugyldigt i $Path."
    }

    foreach ($d in $domains) {
        if (-not (Test-DomainInZone -Domain $d -Zone $zone)) {
            throw "Domænet '$d' ligger ikke under one.com-domænet '$zone'."
        }
    }

    $contact = [string](Get-ConfigValue $cfg 'Contact' '')
    if (-not (Test-EmailAddress $contact)) {
        throw "Kontakt-e-mail mangler eller er ugyldig i $Path."
    }

    return [pscustomobject]@{
        Domains            = $domains
        MainDomain         = $domains[0]
        OneComDomain       = $zone
        Contact            = $contact.Trim()
        DnsSleep           = [int](Get-ConfigValue $cfg 'DnsSleep' 120)
        ValidationTimeout  = [int](Get-ConfigValue $cfg 'ValidationTimeout' 300)
        LogRetentionDays   = [int](Get-ConfigValue $cfg 'LogRetentionDays' 30)
        HookTimeoutSeconds = [int](Get-ConfigValue $cfg 'HookTimeoutSeconds' 300)
        CertificateUser    = [string](Get-ConfigValue $cfg 'CertificateUser' '')
        CertificateUserSid = [string](Get-ConfigValue $cfg 'CertificateUserSid' '')
    }
}

function Test-EmailAddress {
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }

    try {
        $m = New-Object System.Net.Mail.MailAddress($Address.Trim())
        return ($m.Address -eq $Address.Trim() -and $m.Host.Contains('.'))
    }
    catch {
        return $false
    }
}

# ============================================================
# Filrettigheder
# ============================================================

function Set-RestrictedAcl {
    <#
        Begrænser adgang til mappen (og alt indhold) til SYSTEM,
        Administratorer og certifikatbrugeren. Bruger SID'er, så det
        virker på danske/andre sprogversioner af Windows.
        Mappen indeholder private nøgler og scripts, der kører med
        administratorrettigheder; ellers kunne almindelige brugere
        (der som standard har skriveadgang til nye mapper i C:\)
        placere et hook og få administratorrettigheder.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$UserSid
    )

    $grants = @(
        "*$($script:SidLocalSystem):(OI)(CI)F",
        "*$($script:SidAdministrators):(OI)(CI)F",
        "*$($UserSid):(OI)(CI)F"
    )

    $out = & icacls.exe $Path /inheritance:r /grant:r @grants /Q 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Kunne ikke sætte rettigheder på $Path (icacls exitkode $LASTEXITCODE): $out"
    }

    if (@(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        $out = & icacls.exe (Join-Path $Path '*') /reset /T /C /Q 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Kunne ikke nulstille rettigheder under $Path (icacls exitkode $LASTEXITCODE): $out"
        }
    }
}

# ============================================================
# Posh-ACME og OneCom-plugin
# ============================================================

function Install-OneComPlugin {
    <#
        Kopierer OneCom.ps1 ind i Plugins-mappen i ALLE installerede
        Posh-ACME-versioner, hvis filen mangler eller er forældet.
        Returnerer antallet af opdaterede kopier.
    #>
    param([Parameter(Mandatory = $true)][string]$PluginSource)

    if (-not (Test-Path -LiteralPath $PluginSource -PathType Leaf)) {
        throw "Plugin-filen blev ikke fundet: $PluginSource"
    }

    $modules = @(Get-Module -ListAvailable -Name Posh-ACME)
    if ($modules.Count -eq 0) { throw 'Posh-ACME er ikke installeret.' }

    $srcHash = (Get-FileHash -LiteralPath $PluginSource -Algorithm SHA256).Hash
    $updated = 0

    foreach ($m in $modules) {
        $pluginDir = Join-Path $m.ModuleBase 'Plugins'

        if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) {
            Write-Log "  Posh-ACME $($m.Version) har ingen Plugins-mappe ($pluginDir) - springes over." -Level Warn
            continue
        }

        $dest = Join-Path $pluginDir 'OneCom.ps1'

        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and
            (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $srcHash) {
            continue
        }

        Copy-Item -LiteralPath $PluginSource -Destination $dest -Force -ErrorAction Stop
        Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
        Write-Log "  OneCom-plugin kopieret til Posh-ACME $($m.Version): $dest"
        $updated++
    }

    return $updated
}

function Import-PoshAcmeWithPlugin {
    <#
        Indlæser Posh-ACME og sikrer, at OneCom-plugin'et kan findes.
        Kører scriptet som administrator, og er -PluginSource angivet,
        repareres/opdateres plugin'et automatisk (fx efter en
        Posh-ACME-opdatering, der har lagt en ny version i en ny mappe).
    #>
    param([string]$PluginSource)

    if (@(Get-Module -ListAvailable -Name Posh-ACME).Count -eq 0) {
        throw 'Posh-ACME er ikke installeret. Kør Install.cmd.'
    }

    if ($PluginSource -and (Test-IsAdministrator)) {
        try {
            $null = Install-OneComPlugin -PluginSource $PluginSource
        }
        catch {
            Write-Log "  Kunne ikke opdatere OneCom-plugin: $($_.Exception.Message)" -Level Warn
        }
    }

    Remove-Module Posh-ACME -Force -ErrorAction SilentlyContinue
    $module = Import-Module Posh-ACME -PassThru -Force -ErrorAction Stop

    if ($module.Version -lt $script:MinPoshAcmeVersion) {
        throw "Posh-ACME $($module.Version) er for gammel. Version $($script:MinPoshAcmeVersion) eller nyere kræves."
    }

    $plugin = $null
    try { $plugin = Get-PAPlugin OneCom -ErrorAction Stop } catch { $plugin = $null }

    if ($null -eq $plugin) {
        $hint = 'Kør Install.cmd igen (som administrator), så plugin''et kopieres ind.'
        if ($PluginSource -and -not (Test-IsAdministrator)) {
            $hint = 'Scriptet kører ikke som administrator og kan derfor ikke reparere det. ' + $hint
        }
        throw "OneCom-plugin blev ikke fundet af Posh-ACME $($module.Version). $hint"
    }

    $pluginType = $null
    if ($plugin.PSObject.Properties['ChallengeType']) { $pluginType = $plugin.ChallengeType }
    if ([string]::IsNullOrWhiteSpace($pluginType) -and $plugin.PSObject.Properties['Type']) { $pluginType = $plugin.Type }

    if ($pluginType -ne 'dns-01') {
        throw "OneCom-plugin har uventet type: '$pluginType' (forventet dns-01)."
    }

    return $module
}

# ============================================================
# one.com-login (DPAPI)
# ============================================================

function Get-DefaultCredentialPath {
    return (Join-Path $env:LOCALAPPDATA 'Posh-ACME\Secrets\OneComCredential.xml')
}

function Get-SavedOneComCredential {
    param([Parameter(Mandatory = $true)][string]$Path)

    $user = (Get-CurrentUserInfo).Name

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "one.com-login er ikke gemt for Windows-brugeren $user ($Path). Kør Install.cmd igen."
    }

    try {
        $cred = Import-Clixml -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw ("one.com-login kunne ikke læses/dekrypteres ($Path). Filen er sandsynligvis gemt af en " +
               "anden Windows-bruger eller på en anden PC. Gem den igen som $user (kør Install.cmd). " +
               "Detaljer: $($_.Exception.Message)")
    }

    if ($cred -isnot [System.Management.Automation.PSCredential]) {
        throw "Filen indeholder ikke et gyldigt one.com-login: $Path"
    }

    return $cred
}

# ============================================================
# Ordre og certifikat
# ============================================================

function Test-OrderMatchesDomains {
    param($Order, [string[]]$Domains)

    if ($null -eq $Order) { return $false }

    $have = @(@($Order.MainDomain) + @($Order.SANs) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    $want = @($Domains | Sort-Object -Unique)

    return ($null -eq (Compare-Object -ReferenceObject $have -DifferenceObject $want))
}

function Move-FileWithRetry {
    param([string]$Source, [string]$Destination, [int]$Attempts = 5)

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return
        }
        catch {
            if ($i -eq $Attempts) {
                throw "Kunne ikke erstatte $Destination (filen er måske i brug): $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Export-CertificateFiles {
    <#
        Kopierer certifikatfilerne fra Posh-ACME til $Destination med
        faste, letforståelige navne. Kopierer kun, hvis indholdet er ændret.
        Returnerer $true, hvis noget blev opdateret.
    #>
    param(
        [Parameter(Mandatory = $true)]$Certificate,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $map = [ordered]@{
        'fullchain.cer' = 'FullChainFile'
        'cert.key'      = 'KeyFile'
        'cert.cer'      = 'CertFile'
        'chain.cer'     = 'ChainFile'
        'cert.pfx'      = 'PfxFile'
        'fullchain.pfx' = 'PfxFullChain'
    }
    $required = @('fullchain.cer', 'cert.key', 'cert.cer')

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $pending = @()

    foreach ($name in $map.Keys) {
        $prop = $map[$name]
        $src = $null
        if ($Certificate.PSObject.Properties[$prop]) { $src = [string]$Certificate.$prop }

        if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
            if ($required -contains $name) { throw "Certifikatfilen ($prop) mangler i Posh-ACME: '$src'" }
            continue
        }

        $dst = Join-Path $Destination $name

        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and
            (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash) {
            continue
        }

        $pending += [pscustomobject]@{ Source = $src; Destination = $dst; Temp = "$dst.tmp" }
    }

    if ($pending.Count -eq 0) { return $false }

    # Kopiér alt til .tmp først og erstat derefter filerne lige efter hinanden,
    # så certifikat og nøgle kun er ude af trit i et meget kort øjeblik.
    try {
        foreach ($p in $pending) { Copy-Item -LiteralPath $p.Source -Destination $p.Temp -Force -ErrorAction Stop }
        foreach ($p in $pending) { Move-FileWithRetry -Source $p.Temp -Destination $p.Destination }
    }
    finally {
        foreach ($p in $pending) { Remove-Item -LiteralPath $p.Temp -Force -ErrorAction SilentlyContinue }
    }

    return $true
}

function Write-CertificateInfo {
    param($Certificate, [string]$Destination, [string[]]$Domains)

    $lines = @(
        'Certifikat'
        '=========='
        ''
        "Opdateret     : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)
        "Domæner       : $($Domains -join ', ')"
        "Gyldigt fra   : $($Certificate.NotBefore)"
        "Udløber       : $($Certificate.NotAfter)"
        "Thumbprint    : $($Certificate.Thumbprint)"
        ''
        'Filer'
        '-----'
        'fullchain.cer : Certifikat + mellemcertifikat(er). Bruges af de fleste webservere'
        '                (Apache SSLCertificateFile, nginx ssl_certificate).'
        'cert.key      : Privat nøgle (Apache SSLCertificateKeyFile, nginx ssl_certificate_key).'
        '                HOLD DENNE FIL HEMMELIG.'
        'cert.cer      : Kun selve certifikatet.'
        'chain.cer     : Kun mellemcertifikat(er).'
        'cert.pfx      : Certifikat + nøgle i PFX-format (Windows/IIS).'
        'fullchain.pfx : Som cert.pfx, inkl. mellemcertifikater.'
        '                PFX-adgangskoden er Posh-ACME-standarden: poshacme'
    )

    Set-Content -LiteralPath (Join-Path $Destination 'info.txt') -Value $lines -Encoding UTF8
}

# ============================================================
# Hooks
# ============================================================

function Invoke-CertificateHooks {
    <#
        Kører alle *.ps1 i hooks-mappen (alfabetisk) i hver sin
        PowerShell-proces med tidsgrænse. Oplysninger om certifikatet
        gives via miljøvariabler (CERT_*). Returnerer antal fejlede hooks.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$HookDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $HookDirectory -PathType Container)) {
        Write-Log '  Ingen Hooks-mappe - intet at køre.'
        return 0
    }

    # Ekstra tjek på Extension, fordi -Filter '*.ps1' også kan ramme fx '*.ps1x'.
    $hooks = @(Get-ChildItem -LiteralPath $HookDirectory -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.ps1' } | Sort-Object Name)

    if ($hooks.Count -eq 0) {
        Write-Log '  Ingen hooks fundet.'
        return 0
    }

    $ps = Get-WindowsPowerShellPath

    foreach ($key in $Environment.Keys) {
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }

    $failed = 0

    foreach ($hook in $hooks) {
        Write-Log "  Kører hook: $($hook.Name)"
        Unblock-File -LiteralPath $hook.FullName -ErrorAction SilentlyContinue

        $outFile = [IO.Path]::GetTempFileName()
        $errFile = [IO.Path]::GetTempFileName()

        try {
            $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$($hook.FullName)`"")
            $proc = Start-Process -FilePath $ps -ArgumentList $argList -WorkingDirectory $HookDirectory `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
            $null = $proc.Handle

            if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
                try { $proc.Kill() } catch { }
                Write-Log "  Hook $($hook.Name) blev stoppet efter $TimeoutSeconds sekunder." -Level Error
                $failed++
            }
            elseif ($proc.ExitCode -ne 0) {
                Write-Log "  Hook $($hook.Name) fejlede (exitkode $($proc.ExitCode))." -Level Error
                $failed++
            }
            else {
                Write-Log "  Hook $($hook.Name) OK." -Level Ok
            }

            foreach ($f in @($outFile, $errFile)) {
                Get-Content -LiteralPath $f -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Log "    | $_" }
            }
        }
        catch {
            Write-Log "  Hook $($hook.Name) kunne ikke køres: $($_.Exception.Message)" -Level Error
            $failed++
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $failed
}

# ============================================================
# Lås, så to kørsler ikke ændrer Posh-ACME samtidig
# ============================================================

function Enter-CertificateLock {
    param([int]$TimeoutMinutes = 30)

    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:CertMutexName)
    }
    catch {
        Write-Log "  Kunne ikke oprette lås ($($_.Exception.Message)) - fortsætter uden." -Level Warn
        return $null
    }

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes($TimeoutMinutes))
    }
    catch {
        # En tidligere kørsel blev afbrudt uden at frigive låsen. Vi ejer den nu.
        $ex = $_.Exception
        while ($ex -and $ex -isnot [System.Threading.AbandonedMutexException]) { $ex = $ex.InnerException }
        if ($null -eq $ex) { $mutex.Dispose(); throw }
        $acquired = $true
    }

    if (-not $acquired) {
        $mutex.Dispose()
        throw "En anden certifikatkørsel har været i gang i over $TimeoutMinutes minutter. Prøv igen senere."
    }

    return $mutex
}

function Exit-CertificateLock {
    param($Mutex)

    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    $Mutex.Dispose()
}

# ============================================================
# Diverse
# ============================================================

function Remove-OldFiles {
    param([string]$Directory, [string]$Filter, [int]$Days)

    if ($Days -le 0 -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }

    Get-ChildItem -LiteralPath $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Days) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
