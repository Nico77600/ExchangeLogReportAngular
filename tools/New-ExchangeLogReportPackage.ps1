#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'),
    [string]$PowerShellArchive
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Build-Standalone.ps1') @PSBoundParameters
