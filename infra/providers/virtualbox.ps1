# Provider: VirtualBox (Windows e Linux), VirtualBox 7.x.
# Implementa o contrato de providers/README.md com VBoxManage e Packer
# (virtualbox-iso). Testado: não (mesmo contrato do provider vmware, testado).
#
# Rede: uma "NAT Network" dedicada (rhcsa-lab, 192.168.56.0/24). Nela o
# VirtualBox faz o papel do host libvirt do backend original: gateway e DNS
# no .1, NAT para a internet e DHCP, aqui com endereço fixo por MAC
# (reservas de machines.yaml). As VMs dessa rede não são alcançáveis
# diretamente pelo host: SSH e dashboard passam por redirecionamento de
# portas em 127.0.0.1 (ver Get-ProviderEndpoint).
#
# settings.psd1:
#   VirtualBox = @{
#       InstallDir    = 'C:\Program Files\Oracle\VirtualBox'   # Linux: '/usr/bin'
#       NatNetwork    = 'rhcsa-lab'
#       SshPortBase   = 2210    # workstation=2210, servera=2211, serverb=2212
#       DashboardPort = 8421    # http://127.0.0.1:8421
#   }

$script:ProviderLabel = 'VirtualBox'
$script:VBoxSata = 'SATA Controller'   # nome do controlador criado pelo Packer
$script:VBoxIde  = 'IDE Controller'

function Get-VBoxSettings([hashtable]$Settings) {
    $p = $Settings.P
    $default = if ($IsWindows) { 'C:\Program Files\Oracle\VirtualBox' } else { '/usr/bin' }
    [pscustomobject]@{
        InstallDir    = $(if ($p.ContainsKey('InstallDir')) { $p.InstallDir } else { $default })
        NatNetwork    = $(if ($p.ContainsKey('NatNetwork')) { $p.NatNetwork } else { 'rhcsa-lab' })
        SshPortBase   = $(if ($p.ContainsKey('SshPortBase')) { [int]$p.SshPortBase } else { 2210 })
        DashboardPort = $(if ($p.ContainsKey('DashboardPort')) { [int]$p.DashboardPort } else { 8421 })
    }
}

function Get-VBoxManage([hashtable]$Settings) {
    $exe = if ($IsWindows) { 'VBoxManage.exe' } else { 'VBoxManage' }
    $p = Join-Path (Get-VBoxSettings $Settings).InstallDir $exe
    if (-not (Test-Path $p)) { throw "Não encontrei $exe em $((Get-VBoxSettings $Settings).InstallDir) (ajuste VirtualBox.InstallDir)." }
    return $p
}

function Invoke-VBox([hashtable]$Settings, [string[]]$Arguments, [switch]$AllowFailure) {
    $vbm = Get-VBoxManage $Settings
    $out = & $vbm @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "VBoxManage $($Arguments -join ' ') falhou: $out" }
    return $out
}

function Get-VBoxVmName([string]$Name) { "rhcsa-lab-$Name" }

# showvminfo --machinereadable -> hashtable chave=valor (sem aspas).
function Get-VBoxInfo([hashtable]$Settings, [string]$VmName) {
    $h = @{}
    foreach ($line in (Invoke-VBox $Settings @('showvminfo', $VmName, '--machinereadable') -AllowFailure)) {
        if ([string]$line -match '^"?([^"=]+)"?="?(.*?)"?$') { $h[$Matches[1]] = $Matches[2] }
    }
    return $h
}

function Test-VBoxVm([hashtable]$Settings, [string]$VmName) {
    [bool]((Invoke-VBox $Settings @('list', 'vms') -AllowFailure) -match "^`"$([regex]::Escape($VmName))`" ")
}

function Test-VBoxSnapshot([hashtable]$Settings, [string]$VmName, [string]$Snapshot) {
    $out = Invoke-VBox $Settings @('snapshot', $VmName, 'list', '--machinereadable') -AllowFailure
    return [bool]($out -match "^SnapshotName[-\d]*=`"$([regex]::Escape($Snapshot))`"$")
}

# Porta local que leva ao SSH de cada VM (ordem de machines.yaml).
function Get-VBoxSshPort([hashtable]$Settings, $Machines, [string]$Name) {
    $i = [array]::IndexOf(@($Machines.machines.Keys), $Name)
    return (Get-VBoxSettings $Settings).SshPortBase + $i
}

# Slot (controlador-porta-dispositivo) do drive de DVD da VM.
function Get-VBoxDvdSlot([hashtable]$Settings, [string]$VmName) {
    $info = Get-VBoxInfo $Settings $VmName
    foreach ($k in $info.Keys) {
        if ($k -match '^(.+)-(\d+)-(\d+)$' -and ($info[$k] -eq 'emptydrive' -or $info[$k] -match '\.iso$')) {
            return [pscustomobject]@{ Ctl = $Matches[1]; Port = $Matches[2]; Device = $Matches[3] }
        }
    }
    return $null
}

# ================================================================ CONTRATO ===

# NAT Network, DHCP e redirecionamentos são do usuário: sem elevação.
function Test-ProviderHostNeedsElevation { $false }

function Test-ProviderEnvironment([hashtable]$Settings, $Machines) {
    $items = @()
    try {
        $ver = (Invoke-VBox $Settings @('--version')) -join ''
        $items += New-CheckItem 'ok' "VBoxManage $ver"
        if ($ver -notmatch '^7\.') { $items += New-CheckItem 'warn' 'o provider foi escrito para o VirtualBox 7.x' }
    } catch { return @(New-CheckItem 'fail' $_.Exception.Message) }

    $vb = Get-VBoxSettings $Settings
    $nets = Invoke-VBox $Settings @('natnetwork', 'list') -AllowFailure
    if ($nets -match "^Name:\s+$([regex]::Escape($vb.NatNetwork))\s*$") { $items += New-CheckItem 'ok' "NAT Network '$($vb.NatNetwork)'" }
    else { $items += New-CheckItem 'fail' "NAT Network '$($vb.NatNetwork)' ausente (rode infra/setup-host.ps1)" }

    foreach ($n in $Machines.machines.Keys) {
        $port = Get-VBoxSshPort $Settings $Machines $n
        $items += New-CheckItem 'ok' ("SSH da {0,-11} -> 127.0.0.1:{1}" -f $n, $port)
    }
    if (-not $IsWindows -and ((& lsmod 2>$null) -match '^kvm_(intel|amd)\s')) {
        $items += New-CheckItem 'warn' 'módulos KVM carregados: o VirtualBox pode não conseguir usar VT-x/AMD-V (descarregue kvm_intel/kvm_amd)'
    }
    if ($IsWindows) {
        $hv = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
        if ($hv -and $hv.State -eq 'Enabled') { $items += New-CheckItem 'warn' 'Hyper-V ativo: o VirtualBox roda sobre ele, bem mais lento' }
    }
    if (-not (Get-IpMap).Identity) { $items += New-CheckItem 'warn' 'há tradução de IPs para o VirtualBox; a NAT Network dedicada normalmente usa a rede original' }
    return $items
}

# NAT Network do lab com DHCP fixo por MAC e redirecionamentos de porta.
function Initialize-ProviderHost([hashtable]$Settings, $Machines) {
    $vb = Get-VBoxSettings $Settings
    $net = $vb.NatNetwork
    $cidr = [string]$Machines.network.cidr
    $prefix = $cidr -replace '\.\d+/\d+$', ''

    Write-Step "NAT Network '$net' ($cidr)"
    $nets = Invoke-VBox $Settings @('natnetwork', 'list') -AllowFailure
    if ($nets -match "^Name:\s+$([regex]::Escape($net))\s*$") {
        Invoke-VBox $Settings @('natnetwork', 'modify', '--netname', $net, '--network', $cidr, '--enable', '--dhcp', 'on') | Out-Null
    } else {
        Invoke-VBox $Settings @('natnetwork', 'add', '--netname', $net, '--network', $cidr, '--enable', '--dhcp', 'on') | Out-Null
    }
    Write-Ok "gateway/DNS em $prefix.1 (VirtualBox), DHCP ligado"

    Write-Step 'DHCP: faixa dinâmica longe dos IPs do lab e endereço fixo por MAC'
    Invoke-VBox $Settings @('dhcpserver', 'modify', "--network=$net", "--lower-ip=$prefix.100", "--upper-ip=$prefix.200") | Out-Null
    foreach ($n in $Machines.machines.Keys) {
        $vm = $Machines.machines[$n]
        $mac = ([string]$vm.nics[0].mac).ToLower()
        Invoke-VBox $Settings @('dhcpserver', 'modify', "--network=$net", "--mac-address=$mac", "--fixed-address=$($vm.ip)") | Out-Null
        Write-Ok ("{0,-12} {1}  ->  {2}" -f $n, $mac, $vm.ip)
    }

    Write-Step 'Redirecionamentos de porta (host 127.0.0.1 -> VMs)'
    $rules = @()
    foreach ($n in $Machines.machines.Keys) {
        $rules += [pscustomobject]@{ Name = "rhcsa-ssh-$n"; Port = (Get-VBoxSshPort $Settings $Machines $n); Ip = $Machines.machines[$n].ip; GuestPort = 22 }
    }
    $rules += [pscustomobject]@{ Name = 'rhcsa-dashboard'; Port = $vb.DashboardPort; Ip = $Machines.machines[$Machines.dashboard.host].ip; GuestPort = [int]$Machines.dashboard.port }
    foreach ($r in $rules) {
        Invoke-VBox $Settings @('natnetwork', 'modify', '--netname', $net, '--port-forward-4', 'delete', $r.Name) -AllowFailure | Out-Null
        Invoke-VBox $Settings @('natnetwork', 'modify', '--netname', $net, '--port-forward-4', "$($r.Name):tcp:[127.0.0.1]:$($r.Port):[$($r.Ip)]:$($r.GuestPort)") | Out-Null
        Write-Ok "127.0.0.1:$($r.Port) -> $($r.Ip):$($r.GuestPort)"
    }
    Invoke-VBox $Settings @('natnetwork', 'stop', '--netname', $net) -AllowFailure | Out-Null
    Invoke-VBox $Settings @('natnetwork', 'start', '--netname', $net) -AllowFailure | Out-Null
}

# Sem "guest additions" nos repositórios do RHEL; o desligamento limpo usa ACPI.
function Get-ProviderKickstartPackages { @() }

# A golden é instalada na rede NAT padrão do Packer (DHCP do VirtualBox).
function Edit-ProviderKickstart([hashtable]$Settings, $Machines, [string]$Kickstart) { $Kickstart }

function Test-ProviderGolden([hashtable]$Settings, $Machines) {
    (Test-VBoxVm $Settings $Machines.image) -and (Test-VBoxSnapshot $Settings $Machines.image 'base')
}

function Get-ProviderGoldenLabel([hashtable]$Settings, $Machines) { "VM '$($Machines.image)' no VirtualBox (snapshot 'base')" }

function Build-ProviderGolden([hashtable]$Settings, $Machines) {
    if (Test-VBoxVm $Settings $Machines.image) {
        Write-Step "Removendo golden anterior ($($Machines.image))"
        Invoke-VBox $Settings @('unregistervm', $Machines.image, '--delete') | Out-Null
    }
    $outDir = Join-Path $Settings.GoldenDir $Machines.image
    if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
    New-Item -ItemType Directory -Force -Path $Settings.GoldenDir | Out-Null
    Invoke-PackerBuild (Join-Path (Get-LabPaths).Packer 'virtualbox') (Get-PackerCommonVars $Settings $Machines)

    Write-Step "Snapshot 'base' (ponto de partida dos clones vinculados)"
    Invoke-VBox $Settings @('snapshot', $Machines.image, 'take', 'base') | Out-Null
    Write-Ok $Machines.image
}

function Test-ProviderVmExists([hashtable]$Settings, [string]$Name) { Test-VBoxVm $Settings (Get-VBoxVmName $Name) }

function Test-ProviderVmRunning([hashtable]$Settings, [string]$Name) {
    [bool]((Invoke-VBox $Settings @('list', 'runningvms') -AllowFailure) -match "^`"$([regex]::Escape((Get-VBoxVmName $Name)))`" ")
}

# Clone vinculado do snapshot 'base' + NICs virtio na NAT Network com os
# MACs de machines.yaml + discos extra SATA na ordem de machines.yaml.
function New-ProviderVm([hashtable]$Settings, $Machines, [string]$Name, $Spec, [bool]$IsController) {
    $vb = Get-VBoxSettings $Settings
    $vmName = Get-VBoxVmName $Name
    $dir = Join-Path $Settings.LabDir $Name
    New-Item -ItemType Directory -Force -Path $Settings.LabDir | Out-Null
    Invoke-VBox $Settings @('clonevm', $Machines.image, '--snapshot', 'base', '--options', 'link', '--name', $vmName,
                           '--basefolder', $Settings.LabDir, '--register') | Out-Null

    $mod = @('modifyvm', $vmName, '--memory', [string]$Spec.memory_mb, '--cpus', [string]$Spec.cpus)
    $i = 1
    foreach ($nic in $Spec.nics) {
        $mod += @("--nic$i", 'natnetwork', "--nat-network$i", $vb.NatNetwork, "--nictype$i", 'virtio',
                  "--macaddress$i", (([string]$nic.mac) -replace '[:-]', '').ToUpper(), "--cableconnected$i", 'on')
        $i++
    }
    Invoke-VBox $Settings $mod | Out-Null

    if ($Spec.Contains('extra_disks')) {
        $disks = @($Spec.extra_disks)
        Invoke-VBox $Settings @('storagectl', $vmName, '--name', $script:VBoxSata, '--portcount', [string](1 + $disks.Count)) | Out-Null
        $port = 1
        foreach ($d in $disks) {
            $file = Join-Path (Join-Path $Settings.LabDir $vmName) "$Name-$($d.label).vdi"
            Invoke-VBox $Settings @('createmedium', 'disk', '--filename', $file, '--size', [string]([int]$d.size_gb * 1024), '--format', 'VDI') | Out-Null
            Invoke-VBox $Settings @('storageattach', $vmName, '--storagectl', $script:VBoxSata, '--port', [string]$port,
                                   '--device', '0', '--type', 'hdd', '--medium', $file) | Out-Null
            Write-Ok ("{0,-12} disco {1} GiB -> SATA {2} ({3})" -f $Name, $d.size_gb, $port, $d.label)
            $port++
        }
    }
    Set-ProviderVmIso $Settings $Name $(if ($IsController) { $Settings.IsoPath } else { '' })
}

function Start-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Gui) {
    Invoke-VBox $Settings @('startvm', (Get-VBoxVmName $Name), '--type', $(if ($Gui) { 'gui' } else { 'headless' })) | Out-Null
}

# Desligamento limpo por ACPI; "na tomada" com $Hard ou após 90 s.
function Stop-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Hard) {
    $vmName = Get-VBoxVmName $Name
    if (-not $Hard) {
        Invoke-VBox $Settings @('controlvm', $vmName, 'acpipowerbutton') -AllowFailure | Out-Null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Test-ProviderVmRunning $Settings $Name) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    }
    if (Test-ProviderVmRunning $Settings $Name) { Invoke-VBox $Settings @('controlvm', $vmName, 'poweroff') -AllowFailure | Out-Null }
    Start-Sleep -Seconds 2   # o VirtualBox libera a sessão da VM logo depois
}

function Remove-ProviderVm([hashtable]$Settings, [string]$Name) {
    $vmName = Get-VBoxVmName $Name
    if (Test-VBoxVm $Settings $vmName) { Invoke-VBox $Settings @('unregistervm', $vmName, '--delete') -AllowFailure | Out-Null }
    $dir = Join-Path $Settings.LabDir $vmName
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

# VM desligada. $IsoPath vazio = drive sem mídia.
function Set-ProviderVmIso([hashtable]$Settings, [string]$Name, [string]$IsoPath) {
    $vmName = Get-VBoxVmName $Name
    $slot = Get-VBoxDvdSlot $Settings $vmName
    if (-not $slot) { $slot = [pscustomobject]@{ Ctl = $script:VBoxIde; Port = '1'; Device = '0' } }
    $medium = if ($IsoPath) { $IsoPath } else { 'emptydrive' }
    Invoke-VBox $Settings @('storageattach', $vmName, '--storagectl', $slot.Ctl, '--port', $slot.Port, '--device', $slot.Device,
                           '--type', 'dvddrive', '--medium', $medium) | Out-Null
}

function Get-ProviderIsoFailureReason([hashtable]$Settings, [string]$Name) {
    $slot = Get-VBoxDvdSlot $Settings (Get-VBoxVmName $Name)
    if ($slot) { return "DVD em $($slot.Ctl) $($slot.Port):$($slot.Device)" }
    return 'a VM não tem drive de DVD'
}

function Test-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vmName = Get-VBoxVmName $Name
    (Test-VBoxVm $Settings $vmName) -and (Test-VBoxSnapshot $Settings $vmName $Snapshot)
}

function New-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vmName = Get-VBoxVmName $Name
    if (Test-VBoxSnapshot $Settings $vmName $Snapshot) { Invoke-VBox $Settings @('snapshot', $vmName, 'delete', $Snapshot) | Out-Null }
    Invoke-VBox $Settings @('snapshot', $vmName, 'take', $Snapshot) | Out-Null
}

function Restore-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    Invoke-VBox $Settings @('snapshot', (Get-VBoxVmName $Name), 'restore', $Snapshot) | Out-Null
}

# A NAT Network não é roteável a partir do host: SSH por 127.0.0.1:<porta>.
function Get-ProviderEndpoint([hashtable]$Settings, $Machines, [string]$Name) {
    [pscustomobject]@{ Host = '127.0.0.1'; Port = (Get-VBoxSshPort $Settings $Machines $Name) }
}

function Get-ProviderDashboardUrl([hashtable]$Settings, $Machines) {
    "http://127.0.0.1:$((Get-VBoxSettings $Settings).DashboardPort)"
}

function Get-ProviderConsoleHint([hashtable]$Settings, [string]$Name) {
    "Abra o VirtualBox e use 'Mostrar' na VM $(Get-VBoxVmName $Name) (ou: VBoxManage startvm $(Get-VBoxVmName $Name) --type separate)"
}
