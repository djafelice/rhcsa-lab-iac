# Provider: Hyper-V (Windows 10/11 Pro, Enterprise ou Education).
# Testado: não (escrito sobre o mesmo contrato do provider vmware, testado).
# Implementa o contrato de providers/README.md com o módulo Hyper-V do
# PowerShell, discos diferenciais (VHDX) e checkpoints.
#
# Rede: um switch INTERNO dedicado ao lab ("rhcsa-lab"), com o Windows no
# gateway (192.168.56.1) e NAT do Windows (New-NetNat) para a internet. É o
# mesmo papel que o host libvirt tem no backend original: gateway que
# responde ping e roteia. O switch interno não tem DHCP, então a golden do
# Hyper-V traz um perfil de rede por MAC de gerência de machines.yaml, já com
# o IP de cada VM (o role common apaga esses perfis e cria o ens18).
#
# settings.psd1:
#   HyperV = @{
#       SwitchName = 'rhcsa-lab'         # switch interno do lab
#       NatName    = 'rhcsa-lab'         # NAT do Windows para o switch
#       GoldenIp   = '192.168.56.250'    # IP só da VM de build da golden
#   }
#   HostIp (seção comum) é ignorado: o Windows é o gateway do lab.

$script:ProviderLabel = 'Hyper-V'

function Get-HyperVSettings([hashtable]$Settings, $Machines) {
    $p = $Settings.P
    $prefix = ([string]$Machines.network.gateway) -replace '\.\d+$', ''
    [pscustomobject]@{
        SwitchName = $(if ($p.ContainsKey('SwitchName')) { $p.SwitchName } else { 'rhcsa-lab' })
        NatName    = $(if ($p.ContainsKey('NatName')) { $p.NatName } else { 'rhcsa-lab' })
        GoldenIp   = $(if ($p.ContainsKey('GoldenIp')) { $p.GoldenIp } else { "$prefix.250" })
        Gateway    = [string]$Machines.network.gateway
        Cidr       = [string]$Machines.network.cidr
        Prefix     = [int](([string]$Machines.network.cidr -split '/')[1])
    }
}

function Get-HyperVVmName([string]$Name) { "rhcsa-lab-$Name" }

# /24 -> 255.255.255.0
function ConvertTo-Netmask([int]$Prefix) {
    (0..3 | ForEach-Object { $bits = [math]::Max(0, [math]::Min(8, $Prefix - 8 * $_)); 256 - [math]::Pow(2, 8 - $bits) }) -join '.'
}
function Get-HyperVVmDir([hashtable]$Settings, [string]$Name) { Join-Path $Settings.LabDir $Name }

function Get-HyperVGoldenVhdx([hashtable]$Settings, $Machines) {
    Join-Path (Join-Path (Join-Path $Settings.GoldenDir $Machines.image) 'Virtual Hard Disks') "$($Machines.image).vhdx"
}

function Get-HyperVVm([string]$Name) { Get-VM -Name (Get-HyperVVmName $Name) -ErrorAction SilentlyContinue }

function Get-HyperVFirewallRules {
    @('rhcsa-lab-iac: Packer HTTP', 'rhcsa-lab-iac: ping no gateway', 'rhcsa-lab-iac: DNS no gateway')
}

# Rede de primeiro boot embutida na golden: [{name; mac; ip}] + gateway/DNS.
# Guardada ao lado da golden para detectar golden velha após mudar
# machines.yaml.
function Get-HyperVNetSpec($Machines) {
    $spec = [ordered]@{
        gateway = [string]$Machines.network.gateway
        prefix  = [int](([string]$Machines.network.cidr -split '/')[1])
        dns     = @($Machines.network.dns | ForEach-Object { [string]$_ })
        hosts   = @($Machines.machines.Keys | ForEach-Object {
                [ordered]@{ name = $_; mac = ([string]$Machines.machines[$_].nics[0].mac).ToUpper(); ip = [string]$Machines.machines[$_].ip }
            })
    }
    return ($spec | ConvertTo-Json -Depth 5 -Compress)
}

function Get-HyperVNetSpecFile([hashtable]$Settings, $Machines) {
    Join-Path (Join-Path $Settings.GoldenDir $Machines.image) 'rhcsa-netspec.json'
}

function Test-HyperVGoldenNetSpec([hashtable]$Settings, $Machines) {
    $f = Get-HyperVNetSpecFile $Settings $Machines
    return ((Test-Path $f) -and ((Get-Content $f -Raw).Trim() -eq (Get-HyperVNetSpec $Machines)))
}

# Script rodado pelo Packer no fim do build da golden (depois do
# finalize.sh): grava um keyfile NM por MAC de gerência e apaga o perfil
# da instalação (IP fixo de build) SEM recarregar o NetworkManager, para
# não derrubar a sessão SSH do próprio Packer.
function New-HyperVGoldenNetScript([hashtable]$Settings, $Machines) {
    $paths = Get-LabPaths
    $net = Get-HyperVNetSpec $Machines | ConvertFrom-Json
    $dns = ($net.dns -join ';') + ';'
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@'
#!/bin/bash
# Gerado por infra/providers/hyperv.ps1: rede de primeiro boot da golden
# Hyper-V (switch interno sem DHCP). Um perfil por MAC de gerência; o role
# common do projeto remove estes perfis e cria o ens18 definitivo.
set -euo pipefail
dir=/etc/NetworkManager/system-connections
rm -f "$dir"/*.nmconnection

'@)
    foreach ($h in $net.hosts) {
        $uuid = [guid]::NewGuid().ToString()
        [void]$sb.Append(@"
cat > "`$dir/rhcsa-firstboot-$($h.name).nmconnection" <<'EOF'
[connection]
id=rhcsa-firstboot-$($h.name)
uuid=$uuid
type=ethernet
autoconnect=true

[ethernet]
mac-address=$($h.mac)

[ipv4]
method=manual
address1=$($h.ip)/$($net.prefix)
gateway=$($net.gateway)
dns=$dns

[ipv6]
method=auto
addr-gen-mode=eui64
EOF

"@)
    }
    [void]$sb.Append(@'
chmod 600 "$dir"/rhcsa-firstboot-*.nmconnection
restorecon -R "$dir" || true
'@)
    $out = Join-Path $paths.Work 'hyperv-golden-net.sh'
    [System.IO.File]::WriteAllText($out, ($sb.ToString() -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    return $out
}

# ================================================================ CONTRATO ===

function Test-ProviderHostNeedsElevation { $true }

function Test-ProviderEnvironment([hashtable]$Settings, $Machines) {
    $items = @()
    $hv = Get-HyperVSettings $Settings $Machines
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        return @(New-CheckItem 'fail' 'módulo Hyper-V ausente: ative o Hyper-V (rode infra/setup-host.ps1 como administrador)')
    }
    try { Get-VMHost -ErrorAction Stop | Out-Null; $items += New-CheckItem 'ok' 'Hyper-V ativo e acessível por este usuário' }
    catch { return @(New-CheckItem 'fail' "sem acesso ao Hyper-V ($($_.Exception.Message)). Rode setup-host.ps1 e saia/entre de novo na sessão do Windows (grupo Hyper-V Administrators).") }

    if (Get-VMSwitch -Name $hv.SwitchName -ErrorAction SilentlyContinue) { $items += New-CheckItem 'ok' "switch interno '$($hv.SwitchName)'" }
    else { $items += New-CheckItem 'fail' "switch '$($hv.SwitchName)' ausente (rode infra/setup-host.ps1 como administrador)" }

    $ipOk = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $hv.Gateway -ErrorAction SilentlyContinue |
        Where-Object InterfaceAlias -eq "vEthernet ($($hv.SwitchName))"
    if ($ipOk) { $items += New-CheckItem 'ok' "Windows no gateway do lab ($($hv.Gateway) em vEthernet ($($hv.SwitchName)))" }
    else { $items += New-CheckItem 'fail' "o Windows não tem $($hv.Gateway) em vEthernet ($($hv.SwitchName)) (rode setup-host.ps1)" }

    if (Get-NetNat -Name $hv.NatName -ErrorAction SilentlyContinue) { $items += New-CheckItem 'ok' "NAT do Windows '$($hv.NatName)' ($($hv.Cidr))" }
    else { $items += New-CheckItem 'fail' "NAT '$($hv.NatName)' ausente (rode setup-host.ps1)" }

    foreach ($r in Get-HyperVFirewallRules) {
        if (Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue) { $items += New-CheckItem 'ok' "firewall: $r" }
        else { $items += New-CheckItem 'fail' "regra de firewall '$r' ausente (rode setup-host.ps1)" }
    }

    if (-not (Get-IpMap).Identity) {
        $items += New-CheckItem 'warn' 'há tradução de IPs para o Hyper-V; normalmente o switch dedicado usa a rede original sem tradução'
    }
    if ((Test-Path (Get-HyperVGoldenVhdx $Settings $Machines)) -and -not (Test-HyperVGoldenNetSpec $Settings $Machines)) {
        $items += New-CheckItem 'fail' 'a golden foi construída com outra rede/MACs (machines.yaml mudou): rode ./infra/lab.ps1 image -Force'
    }
    return $items
}

# Configuração única do host (administrador): recurso Hyper-V, grupo Hyper-V
# Administrators, switch interno com o Windows no gateway, NAT e firewall.
function Initialize-ProviderHost([hashtable]$Settings, $Machines) {
    $hv = Get-HyperVSettings $Settings $Machines

    Write-Step 'Recurso Hyper-V do Windows'
    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
    if ($feature.State -ne 'Enabled') {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Null
        Write-Warn 'Hyper-V ativado. REINICIE o Windows e rode este script de novo para terminar a configuração.'
        return
    }
    Write-Ok 'Hyper-V ativo'

    Write-Step "Grupo Hyper-V Administrators (para usar o lab sem sessão de administrador)"
    $group = Get-LocalGroup -SID 'S-1-5-32-578'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue | Where-Object Name -eq $me) { Write-Ok "$me já é membro" }
    else {
        Add-LocalGroupMember -Group $group -Member $me
        Write-Warn "$me adicionado ao grupo '$($group.Name)': saia e entre de novo na sessão do Windows para valer."
    }

    Write-Step "Switch interno '$($hv.SwitchName)'"
    $conflict = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like (($hv.Gateway -replace '\.\d+$', '') + '.*') -and $_.InterfaceAlias -ne "vEthernet ($($hv.SwitchName))" }
    if ($conflict) {
        throw "A rede $($hv.Cidr) já está em uso no Windows ($($conflict.InterfaceAlias -join ', ')), por exemplo pela rede host-only do VirtualBox. Libere-a ou use outra rede via ip-map.hyperv.yaml."
    }
    if (-not (Get-VMSwitch -Name $hv.SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $hv.SwitchName -SwitchType Internal | Out-Null
    }
    $if = Get-NetAdapter -Name "vEthernet ($($hv.SwitchName))"
    Get-NetIPAddress -InterfaceIndex $if.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -ne $hv.Gateway | Remove-NetIPAddress -Confirm:$false
    if (-not (Get-NetIPAddress -InterfaceIndex $if.ifIndex -IPAddress $hv.Gateway -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceIndex $if.ifIndex -IPAddress $hv.Gateway -PrefixLength $hv.Prefix | Out-Null
    }
    Write-Ok "vEthernet ($($hv.SwitchName)) = $($hv.Gateway)/$($hv.Prefix)"

    Write-Step "NAT do Windows '$($hv.NatName)'"
    $nat = Get-NetNat -Name $hv.NatName -ErrorAction SilentlyContinue
    if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $hv.Cidr) { Remove-NetNat -Name $hv.NatName -Confirm:$false; $nat = $null }
    if (-not $nat) { New-NetNat -Name $hv.NatName -InternalIPInterfaceAddressPrefix $hv.Cidr | Out-Null }
    Write-Ok "$($hv.Cidr) -> internet"

    Write-Step 'Firewall do Windows na interface do lab'
    $alias = "vEthernet ($($hv.SwitchName))"
    $rules = Get-HyperVFirewallRules
    foreach ($r in $rules) { Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
    New-NetFirewallRule -DisplayName $rules[0] -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Settings.PackerHttpPort `
        -InterfaceAlias $alias -Profile Any | Out-Null
    # O examsim-network confere que o gateway responde ping.
    New-NetFirewallRule -DisplayName $rules[1] -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 `
        -InterfaceAlias $alias -Profile Any | Out-Null
    # O Windows não é servidor DNS. Liberar a porta faz ele responder "porta
    # fechada" na hora, e o resolver das VMs pula para o próximo DNS
    # (8.8.8.8) sem esperar o timeout a cada consulta.
    New-NetFirewallRule -DisplayName $rules[2] -Direction Inbound -Action Allow -Protocol UDP -LocalPort 53 `
        -InterfaceAlias $alias -Profile Any | Out-Null
    foreach ($r in $rules) { Write-Ok $r }
}

function Get-ProviderKickstartPackages { @('hyperv-daemons') }

# Sem DHCP no switch interno: a instalação da golden usa IP fixo (GoldenIp).
function Edit-ProviderKickstart([hashtable]$Settings, $Machines, [string]$Kickstart) {
    $hv = Get-HyperVSettings $Settings $Machines
    $mask = ConvertTo-Netmask $hv.Prefix
    $dns = (@($Machines.network.dns) | Where-Object { $_ -ne $hv.Gateway } | Select-Object -First 1)
    if (-not $dns) { $dns = '8.8.8.8' }
    $re = [regex]'(?m)^network --bootproto=dhcp(.*)$'
    if (-not $re.IsMatch($Kickstart)) { throw "Adaptação Hyper-V falhou: linha 'network --bootproto=dhcp' não encontrada no kickstart." }
    return $re.Replace($Kickstart, "# rhcsa-lab-iac (Hyper-V): switch interno sem DHCP, IP fixo só na instalação.`nnetwork --bootproto=static --ip=$($hv.GoldenIp) --netmask=$mask --gateway=$($hv.Gateway) --nameserver=$dns`$1", 1)
}

function Test-ProviderGolden([hashtable]$Settings, $Machines) { Test-Path (Get-HyperVGoldenVhdx $Settings $Machines) }
function Get-ProviderGoldenLabel([hashtable]$Settings, $Machines) { Get-HyperVGoldenVhdx $Settings $Machines }

function Build-ProviderGolden([hashtable]$Settings, $Machines) {
    $hv = Get-HyperVSettings $Settings $Machines
    $vars = Get-PackerCommonVars $Settings $Machines
    $mask = ConvertTo-Netmask $hv.Prefix
    # No Hyper-V o Windows É o gateway do lab: o kickstart sai dele
    # (HostIp de settings.psd1 é ignorado neste provider).
    $vars.host_ip     = $hv.Gateway
    $vars.switch_name = $hv.SwitchName
    $vars.golden_ip   = $hv.GoldenIp
    $vars.gateway     = $hv.Gateway
    $vars.netmask     = $mask
    $vars.net_script  = (New-HyperVGoldenNetScript $Settings $Machines) -replace '\\', '/'
    $outDir = Join-Path $Settings.GoldenDir $Machines.image
    if (Test-Path $outDir) { Write-Step "Removendo golden anterior ($outDir)"; Remove-Item -Recurse -Force $outDir }
    New-Item -ItemType Directory -Force -Path $Settings.GoldenDir | Out-Null
    Invoke-PackerBuild (Join-Path (Get-LabPaths).Packer 'hyperv') $vars

    $vhdx = Get-HyperVGoldenVhdx $Settings $Machines
    if (-not (Test-Path $vhdx)) { throw "O Packer terminou, mas não encontrei $vhdx." }
    # Disco-pai dos clones diferenciais: nunca pode mudar.
    Set-ItemProperty -Path $vhdx -Name IsReadOnly -Value $true
    Set-Content -Path (Get-HyperVNetSpecFile $Settings $Machines) -Value (Get-HyperVNetSpec $Machines) -Encoding utf8NoBOM
    Write-Ok $vhdx
}

function Test-ProviderVmExists([hashtable]$Settings, [string]$Name) { [bool](Get-HyperVVm $Name) }

function Test-ProviderVmRunning([hashtable]$Settings, [string]$Name) {
    $vm = Get-HyperVVm $Name
    return ($vm -and $vm.State -eq 'Running')
}

# VM Geração 1 (BIOS, como exige o kickstart) com disco diferencial sobre a
# golden, NICs com os MACs de machines.yaml no switch do lab e discos extra
# no controlador SCSI na ordem de machines.yaml.
function New-ProviderVm([hashtable]$Settings, $Machines, [string]$Name, $Spec, [bool]$IsController) {
    $hv = Get-HyperVSettings $Settings $Machines
    if (-not (Test-HyperVGoldenNetSpec $Settings $Machines)) {
        throw 'A golden do Hyper-V foi construída com outra rede/MACs: rode ./infra/lab.ps1 image -Force'
    }
    $vmName = Get-HyperVVmName $Name
    $dir = Get-HyperVVmDir $Settings $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $osDisk = Join-Path $dir "$Name.vhdx"
    New-VHD -Path $osDisk -ParentPath (Get-HyperVGoldenVhdx $Settings $Machines) -Differencing | Out-Null
    New-VM -Name $vmName -Generation 1 -MemoryStartupBytes ([int64]$Spec.memory_mb * 1MB) -VHDPath $osDisk `
        -Path $dir -SwitchName $hv.SwitchName | Out-Null
    # Memória fixa, sem checkpoints automáticos (o Windows 11 liga por padrão)
    # e checkpoints "Standard" (funcionam com a VM desligada, sem VSS).
    Set-VM -Name $vmName -ProcessorCount ([int]$Spec.cpus) -StaticMemory -AutomaticCheckpointsEnabled $false `
        -CheckpointType Standard -AutomaticStopAction ShutDown -AutomaticStartAction Nothing

    $nics = @($Spec.nics)
    $first = Get-VMNetworkAdapter -VMName $vmName | Select-Object -First 1
    Set-VMNetworkAdapter -VMNetworkAdapter $first -StaticMacAddress (([string]$nics[0].mac) -replace '[:-]', '').ToUpper()
    for ($i = 1; $i -lt $nics.Count; $i++) {
        Add-VMNetworkAdapter -VMName $vmName -SwitchName $hv.SwitchName -Name "nic$i" `
            -StaticMacAddress (([string]$nics[$i].mac) -replace '[:-]', '').ToUpper()
    }

    if ($Spec.Contains('extra_disks')) {
        if (-not (Get-VMScsiController -VMName $vmName)) { Add-VMScsiController -VMName $vmName }
        $loc = 0
        foreach ($d in $Spec.extra_disks) {
            $file = Join-Path $dir "$Name-$($d.label).vhdx"
            if (-not (Test-Path $file)) { New-VHD -Path $file -SizeBytes ([int64]$d.size_gb * 1GB) -Dynamic | Out-Null }
            Add-VMHardDiskDrive -VMName $vmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $loc -Path $file
            Write-Ok ("{0,-12} disco {1} GiB -> SCSI 0:{2} ({3})" -f $Name, $d.size_gb, $loc, $d.label)
            $loc++
        }
    }

    if (-not (Get-VMDvdDrive -VMName $vmName)) { Add-VMDvdDrive -VMName $vmName -ControllerNumber 1 -ControllerLocation 0 }
    Set-ProviderVmIso $Settings $Name $(if ($IsController) { $Settings.IsoPath } else { '' })
}

function Start-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Gui) {
    Start-VM -Name (Get-HyperVVmName $Name)
    if ($Gui) { Start-Process vmconnect.exe -ArgumentList 'localhost', (Get-HyperVVmName $Name) }
}

# Desligamento limpo pelo serviço de integração (hv_utils, nativo no RHEL);
# "na tomada" com $Hard ou se o limpo não terminar em 90 s.
function Stop-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Hard) {
    $vmName = Get-HyperVVmName $Name
    if ($Hard) { Stop-VM -Name $vmName -TurnOff -Force; return }
    $job = Stop-VM -Name $vmName -Force -AsJob
    if (-not (Wait-Job $job -Timeout 90)) { Stop-VM -Name $vmName -TurnOff -Force }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

function Remove-ProviderVm([hashtable]$Settings, [string]$Name) {
    $vm = Get-HyperVVm $Name
    if ($vm) {
        if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Force }
        Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue | Remove-VMSnapshot -IncludeAllChildSnapshots -ErrorAction SilentlyContinue
        Remove-VM -VM $vm -Force
    }
    $dir = Get-HyperVVmDir $Settings $Name
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

# VM desligada. $IsoPath vazio = drive sem mídia.
function Set-ProviderVmIso([hashtable]$Settings, [string]$Name, [string]$IsoPath) {
    $vmName = Get-HyperVVmName $Name
    $dvd = Get-VMDvdDrive -VMName $vmName | Select-Object -First 1
    if ($IsoPath) { Set-VMDvdDrive -VMDvdDrive $dvd -Path $IsoPath }
    else { Set-VMDvdDrive -VMDvdDrive $dvd -Path $null }
}

function Get-ProviderIsoFailureReason([hashtable]$Settings, [string]$Name) {
    $dvd = Get-VMDvdDrive -VMName (Get-HyperVVmName $Name) -ErrorAction SilentlyContinue | Select-Object -First 1
    "DVD da VM no Hyper-V aponta para: '$($dvd.Path)'"
}

function Test-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vm = Get-HyperVVm $Name
    return ($vm -and [bool](Get-VMSnapshot -VM $vm -Name $Snapshot -ErrorAction SilentlyContinue))
}

function New-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vm = Get-HyperVVm $Name
    Get-VMSnapshot -VM $vm -Name $Snapshot -ErrorAction SilentlyContinue | Remove-VMSnapshot
    Checkpoint-VM -VM $vm -SnapshotName $Snapshot
}

function Restore-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    Restore-VMSnapshot -VMName (Get-HyperVVmName $Name) -Name $Snapshot -Confirm:$false
}

# O switch interno é alcançável direto pelo Windows (ele está no gateway).
function Get-ProviderEndpoint([hashtable]$Settings, $Machines, [string]$Name) {
    [pscustomobject]@{ Host = [string]$Machines.machines[$Name].ip; Port = 22 }
}

function Get-ProviderDashboardUrl([hashtable]$Settings, $Machines) {
    "http://$($Machines.machines[$Machines.dashboard.host].ip):$($Machines.dashboard.port)"
}

function Get-ProviderConsoleHint([hashtable]$Settings, [string]$Name) {
    "vmconnect.exe localhost $(Get-HyperVVmName $Name)   (ou Gerenciador do Hyper-V)"
}
