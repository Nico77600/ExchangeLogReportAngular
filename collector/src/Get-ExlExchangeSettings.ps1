#Requires -Version 5.1
<#
.SYNOPSIS
    Exchange Log Report - reads the log settings of the Exchange organisation (internal helper).

.DESCRIPTION
    Run by Invoke-ExchangeLogReport.ps1 -Mode Discover in Windows PowerShell 5.1 (powershell.exe):
    the Exchange management cmdlets are supported in Windows PowerShell only. Not meant to be run
    directly.

    Only read-only Get-* cmdlets are used (View-Only Organization Management is enough); nothing
    is changed in Exchange.
      - On an Exchange server, without -ConnectTo: the Exchange Management Shell of the server
        (RemoteExchange.ps1 + Connect-ExchangeServer -Auto, as its Start menu shortcut).
      - On an Edge Transport server, without -ConnectTo: its local Exchange Management Shell
        (snap-in Microsoft.Exchange.Management.PowerShell.E2010, as bin\Exchange.ps1; no RBAC on an
        Edge, a local administrator or SYSTEM is enough). Only this server is returned, with
        Role = 'Edge': its SMTP protocol log folders (Edge) and message tracking.
      - Elsewhere, or with -ConnectTo: Exchange remote PowerShell (http://<server>/PowerShell/,
        Kerberos), on the first server of -ConnectTo that answers.

    The result (one entry per mailbox server, paths as Exchange returns them, and the names of the
    subscribed Edge Transport servers) is written as JSON to -OutFile. Errors are written to the
    error stream and the exit code is 1.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutFile,
    [string]$ConnectTo,       # comma-separated server names (FQDN or short names)
    [string]$CredentialFile   # Export-Clixml of a PSCredential (DPAPI: same account, same computer)
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

function Get-Prop($Object, [string]$Name) {
    # Property of a (deserialized) object, $null when it does not exist.
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-PathText($Value) {
    # Exchange paths are LocalLongFullPath objects; through remote PowerShell they arrive as strings or objects with PathName.
    if ($null -eq $Value) { return $null }
    $text = if ($Value -is [string]) { $Value } elseif (Get-Prop $Value 'PathName') { [string](Get-Prop $Value 'PathName') } else { "$Value" }
    $text = $text.Trim()
    if ($text) { return $text }
    return $null
}

function Get-Leaf($Value) {
    # Last part of an AD object name (contoso.com/Configuration/Sites/Paris -> PARIS).
    if ($null -eq $Value) { return $null }
    $text = if (Get-Prop $Value 'Name') { [string](Get-Prop $Value 'Name') } else { [string]$Value }
    return $text.Split([char[]]@('/', '\'))[-1].ToUpperInvariant()
}

function Get-VersionText($Value) {
    # AdminDisplayVersion "Version 15.2 (Build 2562.17)" -> "15.2.2562.17".
    $text = "$Value".Trim()
    if ($text -match '^Version (\d+\.\d+) \(Build (\d+)\.(\d+)\)$') { return '{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3] }
    return $text
}

$session = $null
$exitCode = 0
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'This helper must run in Windows PowerShell 5.1 (powershell.exe).' }
    $credential = $null
    if ($CredentialFile) { $credential = Import-Clixml -LiteralPath $CredentialFile }
    $candidates = @(if ($ConnectTo) { $ConnectTo.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $install = $env:ExchangeInstallPath
    $commands = 'Get-ExchangeServer', 'Get-TransportService', 'Get-FrontEndTransportService', 'Get-MailboxTransportService', 'Get-ImapSettings', 'Get-PopSettings', 'Get-ReceiveConnector', 'Get-SendConnector'
    $edge = -not $candidates.Count -and -not $credential -and (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole')

    if ($edge) {
        # ---- Edge Transport server: local Exchange Management Shell (no remote PowerShell, no RBAC) ----
        $method = 'Exchange Management Shell (Edge Transport)'
        try { Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010 -ErrorAction Stop }
        catch { throw ("The Exchange Management Shell of the Edge Transport server {0} could not be loaded as {1} (Add-PSSnapin Microsoft.Exchange.Management.PowerShell.E2010): the account must be a local administrator of the server. {2}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $_.Exception.Message.Trim()) }
        $via = $env:COMPUTERNAME
    } elseif (-not $candidates.Count -and -not $credential -and $install -and (Test-Path -LiteralPath (Join-Path $install 'bin\RemoteExchange.ps1'))) {
        # ---- Exchange Management Shell of this server ----
        $method = 'Exchange Management Shell'
        . (Join-Path $install 'bin\RemoteExchange.ps1') *> $null
        $reason = $null
        try { Connect-ExchangeServer -Auto -ClientApplication:ManagementShell *> $null } catch { $reason = $_.Exception.Message.Trim() }
        if (-not (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue)) {
            throw ("The Exchange Management Shell of {0} could not connect as {1} (Connect-ExchangeServer -Auto). The account needs View-Only Organization Management (or above).{2}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $(if ($reason) { ' ' + $reason } else { '' }))
        }
        $via = @(Get-PSSession | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' } | ForEach-Object ComputerName | Select-Object -First 1)
        $via = if ($via.Count) { [string]$via[0] } else { $env:COMPUTERNAME }
    } else {
        # ---- Exchange remote PowerShell (Kerberos) ----
        $method = 'Exchange remote PowerShell (Kerberos)'
        if (-not $candidates.Count) { throw 'No Exchange server to connect to: use -ConnectTo.' }
        $failures = @()
        foreach ($c in $candidates) {
            $p = @{ ConfigurationName = 'Microsoft.Exchange'; ConnectionUri = "http://$c/PowerShell/"; Authentication = 'Kerberos'; ErrorAction = 'Stop' }
            if ($credential) { $p.Credential = $credential }
            try { $session = New-PSSession @p; $via = $c; break }
            catch { $failures += ('{0}: {1}' -f $c, $_.Exception.Message.Trim()) }
        }
        if (-not $session) {
            throw ("Exchange remote PowerShell could not be opened (http://<server>/PowerShell/, Kerberos). Check the server name, HTTP (port 80) to the server, and that the account is a member of View-Only Organization Management (or above).`n" + ($failures -join "`n"))
        }
        Import-PSSession -Session $session -CommandName $commands -DisableNameChecking -AllowClobber *> $null
    }

    # ---- organisation-wide settings ----
    $all = @(Get-ExchangeServer)
    $index = {
        param($Items)
        $h = @{}
        foreach ($i in @($Items)) { $h[([string](Get-Prop $i 'Name')).ToUpperInvariant()] = $i }
        $h
    }
    $servers = @()
    $edgeServers = @()

    if ($edge) {
        # ---- this Edge Transport server only (the mailbox servers seen here are copies made by EdgeSync) ----
        $name = $env:COMPUTERNAME.ToUpperInvariant()
        $x = @($all | Where-Object { ([string](Get-Prop $_ 'Name')).ToUpperInvariant() -eq $name }) | Select-Object -First 1
        $transport = @(Get-TransportService | Where-Object { ([string](Get-Prop $_ 'Name')).ToUpperInvariant() -eq $name }) | Select-Object -First 1
        if (-not $transport) { throw "Get-TransportService returned no transport service for $name." }
        # Receive connectors of this server; every send connector of an Edge is used by it (EdgeSync copies only those of its subscription).
        $off = @()
        foreach ($c in @(Get-ReceiveConnector)) {
            if ((Get-Leaf (Get-Prop $c 'Server')) -eq $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "receive connector '$(Get-Prop $c 'Name')'" }
        }
        foreach ($c in @(Get-SendConnector)) {
            if ("$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "send connector '$(Get-Prop $c 'Name')'" }
        }
        $servers += New-Object PSObject -Property ([ordered]@{
                Name                   = $name
                Role                   = 'Edge'
                Version                = Get-VersionText (Get-Prop $x 'AdminDisplayVersion')
                Site                   = Get-Leaf (Get-Prop $x 'Site')
                InstallPath            = $(if ($install) { $install.TrimEnd('\') } else { $null })
                EdgeReceivePath        = Get-PathText (Get-Prop $transport 'ReceiveProtocolLogPath')
                EdgeSendPath           = Get-PathText (Get-Prop $transport 'SendProtocolLogPath')
                MessageTrackingPath    = Get-PathText (Get-Prop $transport 'MessageTrackingLogPath')
                MessageTrackingEnabled = (Get-Prop $transport 'MessageTrackingLogEnabled') -ne $false
                LoggingOff             = @($off)
                Warnings               = @()
            })
    }
    else {
        $hub = & $index (Get-TransportService)
        $frontEnd = & $index (Get-FrontEndTransportService)
        $mailbox = & $index (Get-MailboxTransportService)
        $receive = @(Get-ReceiveConnector)
        $send = @(Get-SendConnector)

        # ---- one entry per mailbox server ----
        foreach ($x in $all) {
            if ((Get-Prop $x 'IsEdgeServer') -eq $true) { $edgeServers += ([string]$x.Name).ToUpperInvariant(); continue }
            if (-not ((Get-Prop $x 'IsMailboxServer') -eq $true -or "$(Get-Prop $x 'ServerRole')" -match 'Mailbox')) { continue }
            $name = ([string]$x.Name).ToUpperInvariant()
            $warnings = @()
            $imap = $null; $pop = $null
            try { $imap = @(Get-ImapSettings -Server $name)[0] } catch { $warnings += "IMAP4 settings not read ($($_.Exception.Message.Trim()))." }
            try { $pop = @(Get-PopSettings -Server $name)[0] } catch { $warnings += "POP3 settings not read ($($_.Exception.Message.Trim()))." }

            # SMTP connectors of this server whose protocol logging is off.
            $off = @()
            foreach ($c in $receive) {
                if ((Get-Leaf (Get-Prop $c 'Server')) -eq $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "receive connector '$(Get-Prop $c 'Name')'" }
            }
            foreach ($c in $send) {
                $sources = @(Get-Prop $c 'SourceTransportServers' | ForEach-Object { Get-Leaf $_ })
                if ($sources -contains $name -and "$(Get-Prop $c 'ProtocolLoggingLevel')" -eq 'None') { $off += "send connector '$(Get-Prop $c 'Name')'" }
            }
            foreach ($check in @(@($hub[$name], 'IntraOrgConnectorProtocolLoggingLevel', 'Hub intra-organization connector'),
                    @($frontEnd[$name], 'IntraOrgConnectorProtocolLoggingLevel', 'FrontEnd intra-organization connector'),
                    @($mailbox[$name], 'MailboxDeliveryConnectorProtocolLoggingLevel', 'Mailbox delivery connector'),
                    @($mailbox[$name], 'MailboxSubmissionConnectorProtocolLoggingLevel', 'Mailbox submission connector'))) {
                if ("$(Get-Prop $check[0] $check[1])" -eq 'None') { $off += $check[2] }
            }

            $servers += New-Object PSObject -Property ([ordered]@{
                    Name                   = $name
                    Role                   = 'Mailbox'
                    Version                = Get-VersionText (Get-Prop $x 'AdminDisplayVersion')
                    Site                   = Get-Leaf (Get-Prop $x 'Site')
                    DataPath               = Get-PathText (Get-Prop $x 'DataPath')
                    ImapLogPath            = Get-PathText (Get-Prop $imap 'LogFileLocation')
                    ImapProtocolLog        = (Get-Prop $imap 'ProtocolLogEnabled') -eq $true
                    PopLogPath             = Get-PathText (Get-Prop $pop 'LogFileLocation')
                    PopProtocolLog         = (Get-Prop $pop 'ProtocolLogEnabled') -eq $true
                    FrontEndReceivePath    = Get-PathText (Get-Prop $frontEnd[$name] 'ReceiveProtocolLogPath')
                    FrontEndSendPath       = Get-PathText (Get-Prop $frontEnd[$name] 'SendProtocolLogPath')
                    HubReceivePath         = Get-PathText (Get-Prop $hub[$name] 'ReceiveProtocolLogPath')
                    HubSendPath            = Get-PathText (Get-Prop $hub[$name] 'SendProtocolLogPath')
                    MailboxReceivePath     = Get-PathText (Get-Prop $mailbox[$name] 'ReceiveProtocolLogPath')
                    MailboxSendPath        = Get-PathText (Get-Prop $mailbox[$name] 'SendProtocolLogPath')
                    MessageTrackingPath    = Get-PathText (Get-Prop $hub[$name] 'MessageTrackingLogPath')
                    MessageTrackingEnabled = (Get-Prop $hub[$name] 'MessageTrackingLogEnabled') -ne $false
                    LoggingOff             = @($off)
                    Warnings               = @($warnings)
                })
        }
    }

    $result = New-Object PSObject -Property ([ordered]@{
            Method        = $method
            Via           = $via
            Account       = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            ExchangeCount = $all.Count
            Servers       = @($servers)
            EdgeServers   = @($edgeServers)
        })
    [IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $result -Depth 6), (New-Object Text.UTF8Encoding $false))
    if ($edge) { Write-Output ('{0} on {1}: Edge Transport server {2}.' -f $method, $via, $env:COMPUTERNAME.ToUpperInvariant()) }
    else { Write-Output ('{0} on {1}: {2} Exchange server(s), {3} mailbox server(s), {4} Edge Transport server(s).' -f $method, $via, $all.Count, $servers.Count, $edgeServers.Count) }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    Get-PSSession -ErrorAction SilentlyContinue | Where-Object { $_.ConfigurationName -eq 'Microsoft.Exchange' } | Remove-PSSession -ErrorAction SilentlyContinue
}
exit $exitCode

# SIG # Begin signature block
# MIIghAYJKoZIhvcNAQcCoIIgdTCCIHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC6xzzJyGUFXpeT
# zXiXcd3ODujjW2ky2YUdVwyPy4ztP6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYISazCCEmcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBVm0N1bcz4
# iRJZ9Fqn/mJMtVIa4cK4BdakvobKkH04UTANBgkqhkiG9w0BAQEFAASCAgCWP7yV
# uMiJE4y6ML7dV2pUFHHJSUujHv0GBTSnK3M2nzg8iJ61dTF4f4cQPMiy1HsdwciD
# TOMzmcFxUDeB2dydLqOpg5TvCFgmXdYiZE8tepTcnjxbFcRDRYZOxefHE5f89DfV
# FtpyifCEYCaPyTi65+gkCoIvpEWs9o3qblULoZQpT2nnl8Si+6z7uOFemHmKe2FW
# xcsVLjP4b2PGL55nxoEl5XziQfqhAcPqSTCYddM2pwT71tUvPipDDqEILXacsWh7
# miST4rvyglS/khg5Bq5l78A+mV5V8XRJO9niF5lccjzBYzaA/SHvVbJyifimLH9f
# FZlJmeITkQNG/akYuzwlGuRi5UxK/70E3AJCskHiMFiddMaoQhzMMnnFXqJAeIYn
# iHTYPwXyCJLAVDDzctH2+sarhhAryKJa9EYblCLLzIJ/noyffEk4dceaihDIu3kH
# EWDyBFUKyeUq6B9Ew56ozP3PzhDMeFO2WThrT0NxC+HbDQcjsc1hsuXqcN70uVNB
# khvAJVOgheg/GGSbIYw5BKXAfaydGYYg9P2fajoNYiANxjmT1yCDtVQdATRl/W5F
# pCXmcLbZ91m+yXEHSyD9TgFCMs1TfvGZtisjagsrI1tIJFYj6PAFOyY9UipQ7a65
# Xrz5WX/k4uFjt5TlhbFqd0VlfMRh6uFGNFPeiaGCDygwgg8kBgorBgEEAYI3AwMB
# MYIPFDCCDxAGCSqGSIb3DQEHAqCCDwEwgg79AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIMnnirW4K15w5tWSR2gDvwLoC4+jcgeaL7TPvJmhn4+0Aghedk4OnynH
# NBgPMjAyNjEwMjgxMTQ2MzdaMAMCAQECEF/TPb6plNzafzsrhPc6rd6gggwAMIIE
# /DCCAuSgAwIBAgIQH2sWYtIuG2xd8cDBoGAOODANBgkqhkiG9w0BAQsFADBzMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSBSMTAeFw0yNTAyMTgxNjMyMDJaFw0zNDExMTIxODUwMDVa
# MG4xCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3Rv
# bjERMA8GA1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1w
# aW5nIFVuaXQgMjAyNSBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBv7UVHH
# b+ZVluxPXlfE3M6tg0Xnq8dic+O3vPOCRpalUM1vO9A+GRzSVVjyygHhYrBw62XL
# Fh1kv7e+yRd/aTajggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9
# gZD0zzBRBggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNz
# bC5jb20vU1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARK
# MEgwPAYMKwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNz
# bC5jb20vcmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwRgYDVR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29t
# LXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFM582cAEgMUkEGoJ
# 6hyrJT0R/ajSMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAgHN1
# JIW9ZlNip07FfY9r1LJwLKTl1h/y9r1BjDgHMEz7U7J7mAy32JxA1KLyjCCJqNku
# RfhDHGFEfZtjTOru7AQMDSDiUDvCCc3jaz5py9jGvwIe5npkLbXqXhA+SqCzG719
# USigwhHkYr7v8NiXoaY0Xu03p0BiZZreZlpngmGB9+86N94FqIFx2I5Z5iuu7d4j
# 7aAOZBNxfU9jFDIIGDtWfWeCpF0Q8rLE/3DHDlzJKs5Il3i/VoOl7rTU938oSrxM
# www6GDBlKX8rGHxvkjgIb9MXkVglJSDHsNAZDeCS/inaxKHA+ChuB8K4OxIxa6k1
# e+eHBypakAY3wuN7w7PlPmhN6k5IdqZn3HZHs2VjoR841Z9wmVPFdGDdkBZ7XOmb
# 5OZUaKufsvtER0VbY2DkzaqAaItt1kc+I+FUz7PiVz2PUzpegkftRRxvrPyIL08b
# lJTnbMQ0XrqDN0rEfuTLv4XhhnKyJaXhxCUdjO/cRumMzZ35QTUMItBWy1xGp0iy
# oFVnAya2pPsVMuAI+sy1zxlOS9l5iSxvKJ8gpnpOgjqYTa7u1eyZo+4JlcGoiiR1
# 7LthMTrF1q62tO5xOpI8txUZ6gtKGtkJV6wdj+vZLcwKZ2M93GqVpOo6UBlGjx1s
# KsVZ7AIUzJZli4NJ0M2KYcrfNnlebkYKpDnSqWwwggb8MIIE5KADAgECAhBtUhhw
# h+gjTYVgANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# URAT0vk8IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+
# wmOiqBj9ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UN
# zQS7vWZMDJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6
# YctMcQUF2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OE
# Vgo8ebz/B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlL
# La6WK1aO6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPO
# Cc1/CCdaJSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4
# azAWUOO1Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6E
# CxWnlWi7OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9a
# qoZPnjVMjvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN
# 9qqNO83r3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTCBgwYIKwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJT
# QS5jcnQwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYq
# aHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1Ud
# DgQWBBQMnRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cP
# xPtybVfLuqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzX
# aXJYWACDS47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBA
# EDVe6lyZ+FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQG
# swXEAGpHuaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbX
# YRGgdEdx8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMM
# maJ9i+4qGJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rw
# qBUe0BaMqTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32F
# daAvJgTfe9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUk
# TIUBX3HgymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlu
# jHl3r1hgV76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYIC
# VzCCAlMCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAyODExNDYzN1owKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIH6mP4OMeIoG
# ej/HRu3su3siVNfV9QqGr0lok+ezgpD8MIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEYwRAIgBByQ1fyrAG6H6B6gdlCEGPkhCOYFqMyJf7iQYOCfAMsCIANrxgkWnRer
# PpgGMbv4084BwgZZFAkjwo02S0H7MFhG
# SIG # End signature block
