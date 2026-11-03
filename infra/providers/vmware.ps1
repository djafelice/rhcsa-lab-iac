# Provider: VMware Workstation (Windows e Linux).
# Implementa o contrato de providers/README.md com vmrun,
# vmware-vdiskmanager, edição de .vmx e Packer (vmware-iso).
#
# Testado: Windows 11 Pro + Workstation 26H1. Linux: não testado.
#
# settings.psd1:
#   VMware = @{
#       InstallDir = 'C:\Program Files\VMware\VMware Workstation'   # Linux: '/usr/bin'
#       VmNet      = 'VMnet1'      # rede NAT do VMware usada pelo lab (Linux: 'vmnet8', ...)
#   }
#
# O IP de cada VM vem de reservas DHCP por MAC no serviço DHCP do VMware:
#   Windows: %ProgramData%\VMware\vmnetdhcp.conf
#   Linux:   /etc/vmware/<vmnet>/dhcpd/dhcpd.conf

$script:ProviderLabel = 'VMware Workstation'

function Get-VmwareSettings([hashtable]$Settings) {
    $p = $Settings.P
    $default = if ($IsWindows) { 'C:\Program Files\VMware\VMware Workstation' } else { '/usr/bin' }
    $installDir = if ($p.ContainsKey('InstallDir')) { $p.InstallDir } else { $default }
    if (-not $p.ContainsKey('VmNet')) { throw "Defina VMware = @{ VmNet = 'VMnetX' } em infra/settings.psd1." }
    [pscustomobject]@{ InstallDir = $installDir; VmNet = $p.VmNet }
}

function Get-VmwareTool([hashtable]$Settings, [string]$Name) {
    if ($IsWindows) { $Name = "$Name.exe" }
    $p = Join-Path (Get-VmwareSettings $Settings).InstallDir $Name
    if (-not (Test-Path $p)) { throw "Não encontrei $Name em $((Get-VmwareSettings $Settings).InstallDir) (ajuste VMware.InstallDir)." }
    return $p
}

function Invoke-Vmrun([hashtable]$Settings, [string[]]$Arguments, [switch]$AllowFailure) {
    $vmrun = Get-VmwareTool $Settings 'vmrun'
    $out = & $vmrun -T ws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "vmrun $($Arguments -join ' ') falhou: $out" }
    return $out
}

# ------------------------------------------------------------- arquivos .vmx ---
# .vmx = linhas  chave = "valor", chaves sem distinção de maiúsculas (o
# Packer grava em minúsculas, o VMware em camelCase): dicionário ordenado e
# case-insensitive para não duplicar chaves.
function Read-Vmx([string]$Path) {
    $vmx = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*([^=\s]+)\s*=\s*"(.*)"\s*$') { $vmx[$Matches[1]] = $Matches[2] }
    }
    return $vmx
}

function Write-Vmx([string]$Path, $Vmx) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($k in $Vmx.Keys) { [void]$sb.Append("$k = `"$($Vmx[$k])`"`n") }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

function Remove-VmxKeys($Vmx, [string]$Pattern) {
    foreach ($k in @($Vmx.Keys | Where-Object { $_ -match $Pattern })) { $Vmx.Remove($k) }
}

# CD-ROM: reescreve o dispositivo do zero (o Packer, ao desanexar a ISO no
# fim do build, deixa chaves que fariam o VMware ignorar o fileName).
function Set-VmxCdrom($Vmx, [string]$IsoPath) {
    $key = @($Vmx.Keys | Where-Object { $_ -match '^(ide|sata)\d+:\d+\.deviceType$' -and $Vmx[$_] -like 'cdrom*' }) | Select-Object -First 1
    if (-not $key) { throw 'O .vmx não tem drive de CD-ROM (a golden deveria ter um).' }
    $dev = $key -replace '\.deviceType$', ''
    if ($IsoPath) {
        Remove-VmxKeys $Vmx ('^' + [regex]::Escape($dev) + '\.')
        $Vmx["$dev.present"]        = 'TRUE'
        $Vmx["$dev.deviceType"]     = 'cdrom-image'
        $Vmx["$dev.fileName"]       = $IsoPath
        $Vmx["$dev.startConnected"] = 'TRUE'
    } else {
        $Vmx["$dev.startConnected"] = 'FALSE'
    }
}

function Get-VmwareVmx([hashtable]$Settings, [string]$Name) {
    Join-Path (Join-Path $Settings.LabDir $Name) "$Name.vmx"
}

function Get-VmwareGoldenVmx([hashtable]$Settings, $Machines) {
    Join-Path (Join-Path $Settings.GoldenDir $Machines.image) "$($Machines.image).vmx"
}

function Test-VmwareRunning([hashtable]$Settings, [string]$Vmx) {
    $full = [System.IO.Path]::GetFullPath($Vmx)
    $out = Invoke-Vmrun $Settings @('list') -AllowFailure
    foreach ($r in @($out | Select-Object -Skip 1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })) {
        $cmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if ([string]::Equals([System.IO.Path]::GetFullPath($r), $full, $cmp)) { return $true }
    }
    return $false
}

function Test-VmwareSnapshot([hashtable]$Settings, [string]$Vmx, [string]$Snapshot) {
    $snaps = Invoke-Vmrun $Settings @('listSnapshots', $Vmx) -AllowFailure
    return [bool]($snaps -match "^\s*$([regex]::Escape($Snapshot))\s*$")
}

# ================================================================ CONTRATO ===

# Arquivo do serviço DHCP do VMware onde ficam as reservas do lab.
function Get-VmwareDhcpConf([hashtable]$Settings) {
    if ($IsWindows) { return (Join-Path $env:ProgramData 'VMware\vmnetdhcp.conf') }
    $vmnet = (Get-VmwareSettings $Settings).VmNet.ToLower()
    return "/etc/vmware/$vmnet/dhcpd/dhcpd.conf"
}

function Test-HostHasIp([string]$Ip) {
    if ($IsWindows) { return [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $Ip) }
    return [bool]((& ip -4 -o addr show 2>$null) -match "inet $([regex]::Escape($Ip))/")
}

function Test-ProviderHostNeedsElevation { $true }

function Test-ProviderEnvironment([hashtable]$Settings, $Machines) {
    $items = @()
    foreach ($t in 'vmrun', 'vmware-vdiskmanager') {
        try { $items += New-CheckItem 'ok' "$t ($(Get-VmwareTool $Settings $t))" } catch { $items += New-CheckItem 'fail' $_.Exception.Message }
    }
    try { $items += New-CheckItem 'ok' "rede do lab: $((Get-VmwareSettings $Settings).VmNet)" } catch { $items += New-CheckItem 'fail' $_.Exception.Message }

    if (Test-HostHasIp $Settings.HostIp) { $items += New-CheckItem 'ok' "o host tem o IP $($Settings.HostIp) (HostIp)" }
    else { $items += New-CheckItem 'fail' "nenhuma interface do host tem o IP $($Settings.HostIp) (confira HostIp e a VMnet do lab)" }

    if ($IsWindows) {
        if (Get-NetFirewallRule -DisplayName 'rhcsa-lab-iac: Packer HTTP' -ErrorAction SilentlyContinue) {
            $items += New-CheckItem 'ok' "regra de firewall para a porta $($Settings.PackerHttpPort)"
        } else { $items += New-CheckItem 'fail' 'regra de firewall do Packer ausente (rode infra/setup-host.ps1 elevado)' }
    }

    $dhcpConf = Get-VmwareDhcpConf $Settings
    if ((Test-Path $dhcpConf) -and (Select-String -Path $dhcpConf -Pattern '# BEGIN rhcsa-lab-iac' -Quiet)) {
        $items += New-CheckItem 'ok' "reservas DHCP do lab em $dhcpConf"
    } else { $items += New-CheckItem 'fail' "reservas DHCP do lab ausentes em $dhcpConf (rode infra/setup-host.ps1 elevado)" }
    return $items
}

# Configuração única do host (elevado): reservas DHCP dos MACs de
# machines.yaml no DHCP do VMware e liberação da porta HTTP do Packer.
function Initialize-ProviderHost([hashtable]$Settings, $Machines) {
    $ipMap = Get-IpMap
    $cidr = $ipMap.ToCidr
    Write-Step "Firewall: porta TCP $($Settings.PackerHttpPort) (Packer HTTP) a partir de $cidr"
    if ($IsWindows) {
        $ruleName = 'rhcsa-lab-iac: Packer HTTP'
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP `
            -LocalPort $Settings.PackerHttpPort -RemoteAddress $cidr -Profile Any | Out-Null
        Write-Ok $ruleName
    } elseif ((Get-Command firewall-cmd -ErrorAction SilentlyContinue) -and ((& firewall-cmd --state 2>$null) -eq 'running')) {
        & firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$cidr port port=$($Settings.PackerHttpPort) protocol=tcp accept" | Out-Null
        & firewall-cmd --reload | Out-Null
        Write-Ok 'firewalld: regra permanente criada'
    } elseif ((Get-Command ufw -ErrorAction SilentlyContinue) -and ((& ufw status 2>$null) -match 'Status: active')) {
        & ufw allow from $cidr to any port $Settings.PackerHttpPort proto tcp | Out-Null
        Write-Ok 'ufw: regra criada'
    } else { Write-Ok 'nenhum firewall ativo detectado (firewalld/ufw)' }

    $dhcpConf = Get-VmwareDhcpConf $Settings
    if (-not (Test-Path $dhcpConf)) { throw "Não encontrei $dhcpConf. A VMnet do lab existe e tem DHCP ligado no Virtual Network Editor?" }
    Write-Step "Reservas DHCP em $dhcpConf"
    $backup = "$dhcpConf.bak-rhcsa-lab-iac"
    if (-not (Test-Path $backup)) { Copy-Item $dhcpConf $backup; Write-Ok "backup original em $backup" }
    $nl = if ($IsWindows) { "`r`n" } else { "`n" }
    $lines = @('# BEGIN rhcsa-lab-iac (gerado por infra/setup-host.ps1; não edite à mão)')
    foreach ($name in $Machines.machines.Keys) {
        $vm = $Machines.machines[$name]
        $mac = ([string]$vm.nics[0].mac).ToUpper()
        $lines += "host rhcsa-lab-$name {", "    hardware ethernet $mac;", "    fixed-address $($vm.ip);", '}'
        Write-Ok ("{0,-12} {1}  ->  {2}" -f $name, $mac, $vm.ip)
    }
    $lines += '# END rhcsa-lab-iac'
    $content = Get-Content $dhcpConf -Raw
    $content = [regex]::Replace($content, '(?s)\r?\n?# BEGIN rhcsa-lab-iac.*?# END rhcsa-lab-iac\r?\n?', $nl)
    $content = $content.TrimEnd() + $nl + $nl + ($lines -join $nl) + $nl
    [System.IO.File]::WriteAllText($dhcpConf, $content, [System.Text.UTF8Encoding]::new($false))

    Write-Step 'Reiniciando o serviço DHCP do VMware'
    if ($IsWindows) {
        if (Get-Service -Name VMnetDHCP -ErrorAction SilentlyContinue) { Restart-Service -Name VMnetDHCP -Force; Write-Ok 'VMnetDHCP reiniciado' }
        else { Write-Warn 'serviço VMnetDHCP não encontrado; reinicie o DHCP do VMware manualmente.' }
    } else {
        & vmware-networks --stop | Out-Null
        & vmware-networks --start | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok 'vmware-networks reiniciado' } else { Write-Warn 'falha ao reiniciar com vmware-networks; reinicie a rede do VMware manualmente.' }
    }
}

function Get-ProviderKickstartPackages { @('open-vm-tools') }

# O DHCP do VMware (com as reservas) atende a instalação: nada a ajustar.
function Edit-ProviderKickstart([hashtable]$Settings, $Machines, [string]$Kickstart) { $Kickstart }

function Test-ProviderGolden([hashtable]$Settings, $Machines) {
    $vmx = Get-VmwareGoldenVmx $Settings $Machines
    return ((Test-Path $vmx) -and (Test-VmwareSnapshot $Settings $vmx 'base'))
}

function Get-ProviderGoldenLabel([hashtable]$Settings, $Machines) { Get-VmwareGoldenVmx $Settings $Machines }

function Build-ProviderGolden([hashtable]$Settings, $Machines) {
    $vs = Get-VmwareSettings $Settings
    $vars = Get-PackerCommonVars $Settings $Machines
    $vars.network = $vs.VmNet
    $outDir = Join-Path $Settings.GoldenDir $Machines.image
    if (Test-Path $outDir) { Write-Step "Removendo golden anterior ($outDir)"; Remove-Item -Recurse -Force $outDir }
    New-Item -ItemType Directory -Force -Path $Settings.GoldenDir | Out-Null
    Invoke-PackerBuild (Join-Path (Get-LabPaths).Packer 'vmware') $vars

    $vmx = Get-VmwareGoldenVmx $Settings $Machines
    Write-Step "Snapshot 'base' (ponto de partida dos clones vinculados)"
    Invoke-Vmrun $Settings @('snapshot', $vmx, 'base') | Out-Null
    Write-Ok $vmx
}

function Test-ProviderVmExists([hashtable]$Settings, [string]$Name) { Test-Path (Get-VmwareVmx $Settings $Name) }

function Test-ProviderVmRunning([hashtable]$Settings, [string]$Name) {
    $vmx = Get-VmwareVmx $Settings $Name
    return ((Test-Path $vmx) -and (Test-VmwareRunning $Settings $vmx))
}

# Clone vinculado da golden + .vmx ajustado a machines.yaml: CPU/memória,
# NICs com os MACs fixos na VMnet do lab, discos extra no SCSI na ordem de
# machines.yaml (serverb: sdb=6G, sdc=1G, sdd=2G, sde=3G; os exercícios
# acham os discos por tamanho). A controladora recebe a ISO no CD.
function New-ProviderVm([hashtable]$Settings, $Machines, [string]$Name, $Spec, [bool]$IsController) {
    $vs = Get-VmwareSettings $Settings
    $golden = Get-VmwareGoldenVmx $Settings $Machines
    $vmx = Get-VmwareVmx $Settings $Name
    $vmDir = Split-Path -Parent $vmx
    New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
    Invoke-Vmrun $Settings @('clone', $golden, $vmx, 'linked', '-snapshot=base', "-cloneName=rhcsa-lab-$Name") | Out-Null

    $vdisk = Get-VmwareTool $Settings 'vmware-vdiskmanager'
    $cfg = Read-Vmx $vmx
    $cfg['displayName']    = "rhcsa-lab-$Name"
    $cfg['memsize']        = [string]$Spec.memory_mb
    $cfg['numvcpus']       = [string]$Spec.cpus
    # Evita que perguntas do VMware pendurem o vmrun start. Efeito colateral
    # conhecido: falhas ao conectar dispositivos ficam só no vmware.log (por
    # isso o provision confere a ISO por dentro da VM).
    $cfg['msg.autoAnswer'] = 'TRUE'
    Set-VmxCdrom $cfg $(if ($IsController) { $Settings.IsoPath } else { '' })

    Remove-VmxKeys $cfg '^ethernet\d+\.'
    $i = 0
    foreach ($nic in $Spec.nics) {
        $e = "ethernet$i"
        $cfg["$e.present"]         = 'TRUE'
        $cfg["$e.connectionType"]  = 'custom'
        $cfg["$e.vnet"]            = $vs.VmNet
        $cfg["$e.virtualDev"]      = 'vmxnet3'
        $cfg["$e.addressType"]     = 'static'
        $cfg["$e.address"]         = ([string]$nic.mac).ToLower()
        # MACs do homelab (bc:24:11, do Proxmox) ficam fora da faixa estática
        # do VMware (00:50:56): sem isto o VMware recusa o endereço.
        $cfg["$e.checkMACAddress"] = 'FALSE'
        $cfg["$e.startConnected"]  = 'TRUE'
        $i++
    }

    $unit = 1
    if ($Spec.Contains('extra_disks')) {
        foreach ($d in $Spec.extra_disks) {
            if ($unit -eq 7) { $unit++ }   # scsi0:7 é do controlador
            $file = "$Name-$($d.label).vmdk"
            $full = Join-Path $vmDir $file
            if (-not (Test-Path $full)) {
                & $vdisk -c -s "$($d.size_gb)GB" -a lsilogic -t 0 $full | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "vmware-vdiskmanager falhou ao criar $file" }
            }
            $cfg["scsi0:$unit.present"]  = 'TRUE'
            $cfg["scsi0:$unit.fileName"] = $file
            $cfg["scsi0:$unit.mode"]     = 'persistent'
            Write-Ok ("{0,-12} disco {1} GiB -> scsi0:{2} ({3})" -f $Name, $d.size_gb, $unit, $d.label)
            $unit++
        }
    }
    Write-Vmx $vmx $cfg
}

function Start-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Gui) {
    Invoke-Vmrun $Settings @('start', (Get-VmwareVmx $Settings $Name), $(if ($Gui) { 'gui' } else { 'nogui' })) | Out-Null
}

# Desligamento limpo (open-vm-tools) com fallback para desligar "na tomada".
function Stop-ProviderVm([hashtable]$Settings, [string]$Name, [bool]$Hard) {
    $vmx = Get-VmwareVmx $Settings $Name
    if (-not $Hard) {
        Invoke-Vmrun $Settings @('stop', $vmx, 'soft') -AllowFailure | Out-Null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Test-VmwareRunning $Settings $vmx) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    }
    if (Test-VmwareRunning $Settings $vmx) { Invoke-Vmrun $Settings @('stop', $vmx, 'hard') -AllowFailure | Out-Null }
}

function Remove-ProviderVm([hashtable]$Settings, [string]$Name) {
    $vmx = Get-VmwareVmx $Settings $Name
    if (Test-Path $vmx) { Invoke-Vmrun $Settings @('deleteVM', $vmx) -AllowFailure | Out-Null }
    $dir = Split-Path -Parent $vmx
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

# VM desligada. $IsoPath vazio = drive sem mídia.
function Set-ProviderVmIso([hashtable]$Settings, [string]$Name, [string]$IsoPath) {
    $vmx = Get-VmwareVmx $Settings $Name
    $cfg = Read-Vmx $vmx
    Set-VmxCdrom $cfg $IsoPath
    Write-Vmx $vmx $cfg
}

function Get-ProviderIsoFailureReason([hashtable]$Settings, [string]$Name) {
    $log = Join-Path (Split-Path -Parent (Get-VmwareVmx $Settings $Name)) 'vmware.log'
    $why = Select-String -Path $log -Pattern 'cdromImage\.cantOpen|Failed to open' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($why) { return "vmware.log: $($why.Line)" }
    return '(nada registrado no vmware.log)'
}

function Test-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vmx = Get-VmwareVmx $Settings $Name
    return ((Test-Path $vmx) -and (Test-VmwareSnapshot $Settings $vmx $Snapshot))
}

# VM desligada. Substitui o snapshot se já existir.
function New-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    $vmx = Get-VmwareVmx $Settings $Name
    if (Test-VmwareSnapshot $Settings $vmx $Snapshot) { Invoke-Vmrun $Settings @('deleteSnapshot', $vmx, $Snapshot) | Out-Null }
    Invoke-Vmrun $Settings @('snapshot', $vmx, $Snapshot) | Out-Null
}

function Restore-ProviderSnapshot([hashtable]$Settings, [string]$Name, [string]$Snapshot) {
    Invoke-Vmrun $Settings @('revertToSnapshot', (Get-VmwareVmx $Settings $Name), $Snapshot) | Out-Null
}

# A VMnet do lab é alcançável direto pelo Windows.
function Get-ProviderEndpoint([hashtable]$Settings, $Machines, [string]$Name) {
    [pscustomobject]@{ Host = [string]$Machines.machines[$Name].ip; Port = 22 }
}

function Get-ProviderDashboardUrl([hashtable]$Settings, $Machines) {
    "http://$($Machines.machines[$Machines.dashboard.host].ip):$($Machines.dashboard.port)"
}

function Get-ProviderConsoleHint([hashtable]$Settings, [string]$Name) {
    "No VMware Workstation: File > Open > $(Get-VmwareVmx $Settings $Name)"
}
