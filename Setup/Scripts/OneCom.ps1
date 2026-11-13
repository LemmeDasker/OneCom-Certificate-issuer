#requires -Version 5.1

<#
.SYNOPSIS
    Posh-ACME DNS-01 plugin for one.com

.DESCRIPTION
    Manages DNS TXT records through the one.com DNS API.

    The one.com domain (DNS zone) defaults to mydomain.com and can be
    overridden with the optional -OneComDomain plugin argument, e.g.
        -PluginArgs @{ OneComCredential = $cred; OneComDomain = 'example.dk' }

    Supports:
        Add-DnsTxt
        Remove-DnsTxt
        Save-DnsTxt

    Authentication:
        one.com Keycloak web login using a
        -OneComCredential plugin argument.

.NOTES
    Tested with:
        Windows PowerShell 5.1
        one.com Keycloak login
        one.com DNS custom records API

    Verified end to end against Let's Encrypt staging (LE_STAGE)
    for www.mydomain.com.

    Known behaviour:
        Posh-ACME dot-sources this file in a fresh scope for each
        plugin call, so $script: scoped values (including the session
        cache below) do not survive between Add-DnsTxt and
        Remove-DnsTxt. The practical effect is two one.com logins per
        certificate order. This is harmless and intentionally left
        alone rather than redesigned.
#>

# ============================================================
# Configuration
# ============================================================

$script:OneComDomain = 'mydomain.com'
$script:OneComAdminUrl = 'https://www.one.com/admin/'
$script:OneComDnsApiUrl = 'https://www.one.com/admin/api/domains'
$script:OneComSession = $null
$script:OneComSessionCache = [hashtable]::Synchronized(@{})

# ============================================================
# Optional domain override (plugin argument -OneComDomain)
# ============================================================

function Set-OneComDomain {

    param (
        [string]
        $Domain
    )

    if (-not [string]::IsNullOrWhiteSpace($Domain)) {
        $script:OneComDomain = $Domain.Trim().TrimEnd('.').ToLowerInvariant()
    }
}

# ============================================================
# Posh-ACME plugin type
# ============================================================

function Get-CurrentPluginType {
    return 'dns-01'
}

# ============================================================
# one.com login
# ============================================================

function Connect-OneCom {

    param (
        [Parameter(Mandatory = $true)]
        [pscredential]
        $OneComCredential
    )

    $username = $OneComCredential.UserName
    $password = $OneComCredential.GetNetworkCredential().Password

    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'The one.com username is empty.'
    }

    if ([string]::IsNullOrEmpty($password)) {
        throw 'The one.com password is empty.'
    }

    if ($null -ne [System.Management.Automation.Runspaces.Runspace]::DefaultRunspace) {
        $runspaceId =
            [string][System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId
    }
    else {
        $runspaceId = 'default'
    }

    $cacheKey = "$runspaceId|$username"

    $cacheSyncRoot = $script:OneComSessionCache.SyncRoot
    $cachedSession = $null

    [System.Threading.Monitor]::Enter($cacheSyncRoot)

    try {
        if ($script:OneComSessionCache.ContainsKey($cacheKey)) {
            $cachedSession = $script:OneComSessionCache[$cacheKey]
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($cacheSyncRoot)
    }

    if ($null -ne $cachedSession) {

        try {
            $cachedAdminResponse = Invoke-WebRequest `
                -Uri $script:OneComAdminUrl `
                -WebSession $cachedSession `
                -UseBasicParsing `
                -ErrorAction Stop

            $cachedAdminFinalUrl =
                $cachedAdminResponse.BaseResponse.ResponseUri.AbsoluteUri

            if ($cachedAdminFinalUrl -like 'https://www.one.com/admin/frontpage.do*') {
                $script:OneComSession = $cachedSession
                Write-Verbose 'Reusing cached one.com session.'
                return $script:OneComSession
            }
        }
        catch {
        }

        Write-Verbose 'Cached one.com session is no longer valid. Re-authenticating.'

        [System.Threading.Monitor]::Enter($cacheSyncRoot)

        try {
            if ($script:OneComSessionCache.ContainsKey($cacheKey)) {
                $script:OneComSessionCache.Remove($cacheKey) | Out-Null
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($cacheSyncRoot)
        }
    }

    Write-Verbose 'Connecting to one.com...'

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    # --------------------------------------------------------
    # Open one.com login page
    # --------------------------------------------------------

    Write-Verbose 'Opening one.com login page...'

    $loginPage = Invoke-WebRequest `
        -Uri $script:OneComAdminUrl `
        -WebSession $session `
        -UseBasicParsing `
        -ErrorAction Stop

    # --------------------------------------------------------
    # Find Keycloak login form
    # --------------------------------------------------------

    $match = [regex]::Match(
        $loginPage.Content,
        '<form[^>]+id="kc-form-login"[^>]+action="([^"]+)"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $match.Success) {
        throw 'Could not find the one.com Keycloak login form.'
    }

    $loginUri = $match.Groups[1].Value -replace '&amp;', '&'

    Write-Verbose "Keycloak login URL found."

    # --------------------------------------------------------
    # Submit login
    #
    # Verified one.com form fields:
    #
    #   username
    #   password
    #   credentialId = empty
    # --------------------------------------------------------

    $loginBody = @{
        username     = $username
        password     = $password
        credentialId = ''
    }

    Write-Verbose 'Submitting one.com credentials...'

    $loginResponse = Invoke-WebRequest `
        -Uri $loginUri `
        -Method Post `
        -WebSession $session `
        -Body $loginBody `
        -MaximumRedirection 10 `
        -UseBasicParsing `
        -ErrorAction Stop

    $finalUrl = $loginResponse.BaseResponse.ResponseUri.AbsoluteUri

    Write-Verbose "Login final URL: $finalUrl"

    # --------------------------------------------------------
    # Verify authenticated session
    # --------------------------------------------------------

    Write-Verbose 'Verifying authenticated one.com session...'

    $adminResponse = Invoke-WebRequest `
        -Uri $script:OneComAdminUrl `
        -WebSession $session `
        -UseBasicParsing `
        -ErrorAction Stop

    $adminFinalUrl = $adminResponse.BaseResponse.ResponseUri.AbsoluteUri

    if ($adminFinalUrl -notlike 'https://www.one.com/admin/frontpage.do*') {
        throw "one.com authentication failed. Final URL was: $adminFinalUrl"
    }

    Write-Verbose 'one.com authentication successful.'

    $script:OneComSession = $session

    [System.Threading.Monitor]::Enter($cacheSyncRoot)

    try {
        $script:OneComSessionCache[$cacheKey] = $script:OneComSession
    }
    finally {
        [System.Threading.Monitor]::Exit($cacheSyncRoot)
    }

    return $script:OneComSession
}

# ============================================================
# Get DNS records
# ============================================================

function Get-OneComDnsRecords {

    param (
        [Parameter(Mandatory = $true)]
        [Microsoft.PowerShell.Commands.WebRequestSession]
        $Session
    )

    $uri = "$($script:OneComDnsApiUrl)/$($script:OneComDomain)/dns/custom_records"

    Write-Verbose "GET $uri"

    $response = Invoke-WebRequest `
        -Uri $uri `
        -Method Get `
        -WebSession $Session `
        -Headers @{
            Accept = 'application/json'
        } `
        -UseBasicParsing `
        -ErrorAction Stop

    $contentType = $response.Headers['Content-Type']

    if ($contentType -notlike '*application/json*') {
        throw "one.com DNS API returned unexpected content type: $contentType"
    }

    try {
        $json = $response.Content | ConvertFrom-Json
    }
    catch {
        throw 'one.com DNS API returned invalid JSON.'
    }

    # --------------------------------------------------------
    # one.com API structure:
    #
    # result
    #   └── data
    #       └── records
    #
    # Return the data array directly so the rest of the
    # plugin can work with the actual DNS record objects.
    # --------------------------------------------------------

    if ($null -eq $json.result) {
        throw 'one.com DNS API response does not contain result.'
    }

    if ($null -eq $json.result.data) {
        throw 'one.com DNS API response does not contain result.data.'
    }

    return @($json.result.data)
}

# ============================================================
# Convert FQDN to one.com DNS prefix
# ============================================================

function Get-OneComZoneFromRecordName {

    param (
        [Parameter(Mandatory = $true)]
        [string]
        $RecordName
    )

    $recordName = $RecordName.TrimEnd('.')
    $domain = $script:OneComDomain.TrimEnd('.')

    $suffix = ".$domain"

    if (-not $recordName.EndsWith(
        $suffix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Record name '$RecordName' is not inside supported domain '$domain'."
    }

    $prefix = $recordName.Substring(
        0,
        $recordName.Length - $suffix.Length
    )

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return '@'
    }

    return $prefix
}

# ============================================================
# Validate extra plugin args
#
# Call this with -ExtraParams, NOT by splatting @ExtraParams.
# Posh-ACME may pass no extra arguments at all, in which case
# $ExtraParams is $null and splatting a null variable fails.
# ============================================================

function Assert-OneComExtraParams {

    param (
        $ExtraParams
    )

    if ($null -eq $ExtraParams) {
        return
    }

    if (@($ExtraParams).Count -eq 0) {
        return
    }

    Write-Verbose 'Ignoring additional plugin arguments.'
}

# ============================================================
# Add DNS TXT record
# ============================================================

function Add-DnsTxt {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        $RecordName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]
        $TxtValue,

        [Parameter(Mandatory = $true)]
        [pscredential]
        $OneComCredential,

        [string]
        $OneComDomain,

        [Parameter(ValueFromRemainingArguments = $true)]
        $ExtraParams
    )

    Set-OneComDomain -Domain $OneComDomain

    $Session = Connect-OneCom -OneComCredential $OneComCredential

    Assert-OneComExtraParams -ExtraParams $ExtraParams

    $prefix = Get-OneComZoneFromRecordName -RecordName $RecordName

    Write-Verbose "Adding TXT record:"
    Write-Verbose "  Prefix : $prefix"
    Write-Verbose "  Value  : $TxtValue"

    $records = Get-OneComDnsRecords -Session $Session

    # --------------------------------------------------------
    # Idempotency guard.
    #
    # one.com returns HTTP 409 when an identical record already
    # exists, which happens if an order is retried. ACME tokens
    # are base64url and case sensitive, so use -ceq.
    # --------------------------------------------------------

    $existingRecords = @(
        $records | Where-Object {
            $_.attributes.prefix -eq $prefix -and
            $_.attributes.type -eq 'TXT' -and
            $_.attributes.content -ceq $TxtValue
        }
    )

    if ($existingRecords.Count -gt 0) {
        Write-Verbose 'Matching TXT record already exists. Skipping create.'
        return
    }

    $uri = "$($script:OneComDnsApiUrl)/$($script:OneComDomain)/dns/custom_records"

    $body = @{
        type = 'dns_custom_records'
        attributes = @{
            prefix   = $prefix
            content  = $TxtValue
            priority = 0
            type     = 'TXT'
            ttl      = 3600
        }
    }

    $jsonBody = $body | ConvertTo-Json -Depth 5

    $response = Invoke-WebRequest `
        -Uri $uri `
        -Method Post `
        -WebSession $Session `
        -Headers @{
            Accept = 'application/json'
        } `
        -ContentType 'application/json' `
        -Body $jsonBody `
        -UseBasicParsing `
        -ErrorAction Stop

    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "one.com DNS API returned HTTP $($response.StatusCode) while creating TXT record."
    }

    try {
        $null = $response.Content | ConvertFrom-Json
    }
    catch {
        throw 'one.com DNS API returned invalid JSON after creating TXT record.'
    }

    # --------------------------------------------------------
    # Deliberately no return value.
    #
    # Posh-ACME does not expect output from a DNS plugin. Any
    # object emitted here leaks into the pipeline and is printed
    # during New-PACertificate.
    # --------------------------------------------------------

    Write-Verbose 'TXT record successfully created.'
}

# ============================================================
# Remove DNS TXT record
# ============================================================

function Remove-DnsTxt {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        $RecordName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]
        $TxtValue,

        [Parameter(Mandatory = $true)]
        [pscredential]
        $OneComCredential,

        [string]
        $OneComDomain,

        [Parameter(ValueFromRemainingArguments = $true)]
        $ExtraParams
    )

    Set-OneComDomain -Domain $OneComDomain

    $Session = Connect-OneCom -OneComCredential $OneComCredential

    Assert-OneComExtraParams -ExtraParams $ExtraParams

    $prefix = Get-OneComZoneFromRecordName -RecordName $RecordName

    Write-Verbose "Looking for TXT record to remove:"
    Write-Verbose "  Prefix : $prefix"
    Write-Verbose "  Value  : $TxtValue"

    $records = Get-OneComDnsRecords -Session $Session

    $matchingRecords = @(
        $records | Where-Object {

            $_.attributes.prefix -eq $prefix -and
            $_.attributes.type -eq 'TXT' -and
            $_.attributes.content -ceq $TxtValue
        }
    )

    if ($matchingRecords.Count -eq 0) {

        Write-Verbose 'No matching TXT record found.'
        return
    }

    foreach ($record in $matchingRecords) {

        $recordId = $record.id

        if ([string]::IsNullOrWhiteSpace($recordId)) {
            throw 'Matching one.com DNS record has no ID.'
        }

        $deleteUri =
            "$($script:OneComDnsApiUrl)/$($script:OneComDomain)/dns/custom_records/$recordId"

        Write-Verbose "Deleting one.com DNS record ID $recordId"

        $response = Invoke-WebRequest `
            -Uri $deleteUri `
            -Method Delete `
            -WebSession $Session `
            -Headers @{
                Accept = 'application/json'
            } `
            -UseBasicParsing `
            -ErrorAction Stop

        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "one.com DNS API returned HTTP $($response.StatusCode) while deleting record ID $recordId."
        }

        Write-Verbose "Deleted TXT record ID $recordId."
    }
}

# ============================================================
# Save DNS TXT
# ============================================================

function Save-DnsTxt {

    [CmdletBinding()]
    param (
        [Parameter(ValueFromRemainingArguments = $true)]
        $ExtraParams
    )

    Assert-OneComExtraParams -ExtraParams $ExtraParams

    # one.com commits DNS changes immediately.
    Write-Verbose 'Save-DnsTxt called; one.com commits DNS changes immediately.'
}

# ============================================================
# End of plugin
# ============================================================
