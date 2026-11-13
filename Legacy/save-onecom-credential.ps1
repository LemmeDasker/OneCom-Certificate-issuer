#requires -Version 5.1

<#+
.SYNOPSIS
    Stores the one.com credential for unattended Posh-ACME scripts.

.DESCRIPTION
    Prompts once for the one.com username and password and stores the
    resulting PSCredential with Export-Clixml.

    On Windows PowerShell, the password is protected by Windows DPAPI.
    The saved credential can normally only be decrypted by the same
    Windows user on the same computer.

    Run this script as the Windows user that will run certificate
    issuance and renewal tasks. Do not commit the generated XML file.
#>

$ErrorActionPreference = 'Stop'

$credentialDirectory = Join-Path $env:LOCALAPPDATA 'Posh-ACME\Secrets'
$credentialPath = Join-Path $credentialDirectory 'OneComCredential.xml'

Write-Host ''
Write-Host '============================================================'
Write-Host ' Store encrypted one.com credential'
Write-Host '============================================================'
Write-Host ''

try {
    Write-Host '[1/5] Checking credential location...'
    Write-Host "      Path: $credentialPath"

    New-Item `
        -ItemType Directory `
        -Path $credentialDirectory `
        -Force | Out-Null

    if (Test-Path -LiteralPath $credentialPath -PathType Leaf) {
        Write-Host ''
        Write-Host '      A credential file already exists.'
        $answer = Read-Host '      Type OVERWRITE to replace it'

        if ($answer -cne 'OVERWRITE') {
            throw 'Aborted by user. The existing credential file was not changed.'
        }
    }

    Write-Host ''
    Write-Host '[2/5] Prompting for one.com credentials...'

    $credential = Get-Credential -Message 'Enter your one.com credentials'

    if ($null -eq $credential) {
        throw 'No one.com credentials were supplied.'
    }

    if ([string]::IsNullOrWhiteSpace($credential.UserName)) {
        throw 'The one.com username is empty.'
    }

    if ([string]::IsNullOrEmpty($credential.GetNetworkCredential().Password)) {
        throw 'The one.com password is empty.'
    }

    Write-Host ''
    Write-Host '[3/5] Saving encrypted credential...'

    $credential | Export-Clixml -LiteralPath $credentialPath -Force

    Write-Host ''
    Write-Host '[4/5] Verifying saved credential...'

    $savedCredential = Import-Clixml -LiteralPath $credentialPath

    if ($savedCredential -isnot [System.Management.Automation.PSCredential]) {
        throw 'The saved file does not contain a valid PSCredential.'
    }

    if ($savedCredential.UserName -ne $credential.UserName) {
        throw 'The username read from the saved credential does not match.'
    }

    Write-Host "      Credential verified for: $($savedCredential.UserName)"

    Write-Host ''
    Write-Host '[5/5] Result'
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' RESULT: SUCCESS'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host 'The encrypted credential is ready for the certificate scripts.'
    Write-Host ''
    Write-Host 'Important:'
    Write-Host '  - Run scheduled tasks as this same Windows user.'
    Write-Host '  - Re-run this script if the one.com password changes.'
    Write-Host '  - Do not copy the XML file to another PC or commit it to Git.'
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

    throw
}
