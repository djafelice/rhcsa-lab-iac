#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configuração única do Windows para o backend VMware (rodar como administrador).

.DESCRIPTION
    1. Regra no firewall do Windows liberando a porta do servidor HTTP do
       Packer (entrega do kickstart) apenas para a rede do lab.
    2. Reservas DHCP no serviço DHCP do VMware (vmnetdhcp.conf) para a NIC de
       gerência de cada VM do lab: os MACs fixos de machines.yaml sempre
       recebem os IPs traduzidos por vmware\ip-map.yaml. Só esses MACs são
       afetados; as outras VMs da rede continuam recebendo IP normalmente.

    Idempotente: pode ser rodado de novo a qualquer momento. Rode de novo
    sempre que alterar machines.yaml/ip-map.yaml ou depois de clicar em
    OK/Apply nas configurações de DHCP do Virtual Network Editor (que pode
    regravar o vmnetdhcp.conf).
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\lib\LabCommon.ps1"

$s = Get-LabSettings
$m = Get-LabMachines
$ipMap = Get-IpMap

# ------------------------------------------------------------ firewall ---
Write-Step "Firewall: porta TCP $($s.PackerHttpPort) (Packer HTTP) a partir de $($ipMap.ToCidr)"
$ruleName = 'rhcsa-lab-iac: Packer HTTP'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $s.PackerHttpPort -RemoteAddress $ipMap.ToCidr `
    -Profile Any | Out-Null
Write-Ok $ruleName

# ------------------------------------------------------- reservas DHCP ---
$dhcpConf = Join-Path $env:ProgramData 'VMware\vmnetdhcp.conf'
if (-not (Test-Path $dhcpConf)) { throw "Não encontrei $dhcpConf. O serviço DHCP do VMware está instalado?" }

Write-Step "Reservas DHCP em $dhcpConf"
$backup = "$dhcpConf.bak-rhcsa-lab-iac"
if (-not (Test-Path $backup)) {
    Copy-Item $dhcpConf $backup
    Write-Ok "backup original em $backup"
}

$block = [System.Text.StringBuilder]::new()
[void]$block.AppendLine('# BEGIN rhcsa-lab-iac (gerado por vmware\setup-host.ps1; não edite à mão)')
foreach ($name in $m.machines.Keys) {
    $vm = $m.machines[$name]
    $mac = ([string]$vm.nics[0].mac).ToUpper()
    [void]$block.AppendLine("host rhcsa-lab-$name {")
    [void]$block.AppendLine("    hardware ethernet $mac;")
    [void]$block.AppendLine("    fixed-address $($vm.ip);")
    [void]$block.AppendLine('}')
    Write-Ok ("{0,-12} {1}  ->  {2}" -f $name, $mac, $vm.ip)
}
[void]$block.AppendLine('# END rhcsa-lab-iac')

$content = Get-Content $dhcpConf -Raw
$pattern = '(?s)\r?\n?# BEGIN rhcsa-lab-iac.*?# END rhcsa-lab-iac\r?\n?'
$content = [regex]::Replace($content, $pattern, "`r`n")
$content = $content.TrimEnd() + "`r`n`r`n" + ($block.ToString() -replace "(?<!`r)`n", "`r`n")
# O vmnetdhcp.conf é um arquivo do Windows (CRLF, sem BOM).
[System.IO.File]::WriteAllText($dhcpConf, $content, [System.Text.UTF8Encoding]::new($false))

Write-Step 'Reiniciando o serviço DHCP do VMware'
$svc = Get-Service -Name VMnetDHCP -ErrorAction SilentlyContinue
if ($svc) {
    Restart-Service -Name VMnetDHCP -Force
    Write-Ok 'VMnetDHCP reiniciado'
} else {
    Write-Warn 'serviço VMnetDHCP não encontrado; reinicie o Windows ou o serviço DHCP do VMware manualmente.'
}

Write-Host ''
Write-Host 'Host configurado. Confira com: .\vmware\lab.ps1 check' -ForegroundColor Green
