#Requires -Version 7.2
<#
.SYNOPSIS
    Configuração única do host para o provider escolhido em
    infra/settings.psd1 (rede do lab, DHCP, firewall...).

.DESCRIPTION
    O que é feito depende do provider (providers/<provider>.ps1, função
    Initialize-ProviderHost). Alguns exigem privilégio:
      Windows: sudo pwsh -NoProfile -File infra/setup-host.ps1
      Linux:   sudo pwsh -NoProfile -File infra/setup-host.ps1
    Idempotente: rode de novo sempre que mudar machines.yaml, o ip-map do
    provider ou a rede do hypervisor.
#>
[CmdletBinding()]
param()

. "$PSScriptRoot/lib/LabCommon.ps1"

$s = Get-LabSettings
. (Get-ProviderScript $s)
$m = Get-LabMachines
Write-Host "Provider: $script:ProviderLabel ($(Get-HostOs))" -ForegroundColor Cyan

if ((Test-ProviderHostNeedsElevation) -and -not (Test-Elevated)) {
    throw 'Este provider precisa de privilégio para configurar o host: sudo pwsh -NoProfile -File infra/setup-host.ps1'
}
if (-not (Test-ProviderTested $s.Provider)) {
    Write-Warn "o provider '$($s.Provider)' ainda não foi testado em $(Get-HostOs); relate o resultado (ver docs)."
}
Initialize-ProviderHost $s $m
Write-Host ''
Write-Host 'Host configurado. Confira com: ./infra/lab.ps1 check' -ForegroundColor Green
