#Requires -Version 7.2
<#
.SYNOPSIS
    Configuração única do host para o provider escolhido em
    infra/settings.psd1. Rode como ADMINISTRADOR (Windows) ou com sudo
    (Linux), quando o provider exigir.

.DESCRIPTION
    O que é feito depende do provider (ver providers/<provider>.ps1,
    função Initialize-ProviderHost). Idempotente: pode rodar de novo
    sempre que mudar machines.yaml, ip-map.yaml ou a rede do hypervisor.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/lib/LabCommon.ps1"

if ($IsWindows) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Rode este script como administrador (ex.: sudo pwsh -File infra/setup-host.ps1).' }
}

$s = Get-LabSettings
. (Get-ProviderScript $s)
$m = Get-LabMachines
Write-Host "Provider: $script:ProviderLabel" -ForegroundColor Cyan
Initialize-ProviderHost $s $m
Write-Host ''
Write-Host 'Host configurado. Confira com: ./infra/lab.ps1 check' -ForegroundColor Green
