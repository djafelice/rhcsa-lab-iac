#Requires -Version 7.2
<#
.SYNOPSIS
    Backend VMware Workstation do rhcsa-lab-iac (Windows).

.DESCRIPTION
    Comandos:
      check   Confere ferramentas, configuração, rede e tradução de IPs.
      image   Constrói a imagem golden RHEL 10 com o Packer (uma vez).
      up      Cria (clones vinculados da golden) e liga as 3 VMs do lab.
      down    Desliga e apaga as 3 VMs do lab (a golden não é tocada).
      status  Mostra o estado das VMs do lab.
      ssh     Abre SSH como student numa VM: lab.ps1 ssh servera
      help    Mostra esta ajuda.

    Próximas fases: provisionamento (Ansible), snapshot, reset.

.EXAMPLE
    .\vmware\lab.ps1 check
.EXAMPLE
    .\vmware\lab.ps1 image
.EXAMPLE
    .\vmware\lab.ps1 image -Force
.EXAMPLE
    .\vmware\lab.ps1 up -Gui
.EXAMPLE
    .\vmware\lab.ps1 ssh workstation
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'image', 'up', 'down', 'status', 'ssh', 'help')]
    [string]$Command = 'help',

    # ssh: nome da VM (workstation, servera, serverb).
    [Parameter(Position = 1)]
    [string]$Name,

    # image: reconstrói a golden mesmo se já existir.
    # down: não pede confirmação.
    [switch]$Force,

    # up: liga as VMs com janela no VMware Workstation (padrão: em segundo plano).
    [switch]$Gui
)

. "$PSScriptRoot\lib\LabCommon.ps1"

# ------------------------------------------------------------------ check ---
function Invoke-Check {
    $paths = Get-LabPaths
    $script:problems = 0
    $m = $null
    function Fail([string]$Msg) { Write-Fail $Msg; $script:problems++ }

    Write-Step 'Ferramentas'
    if ($PSVersionTable.PSVersion -ge [version]'7.2') { Write-Ok "PowerShell $($PSVersionTable.PSVersion)" }
    else { Fail "PowerShell $($PSVersionTable.PSVersion) (precisa 7.2+)" }

    foreach ($cmd in 'git', 'packer', 'ssh', 'ssh-keygen') {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($c) { Write-Ok "$cmd ($($c.Source))" } else { Fail "$cmd não está no PATH" }
    }
    try { Write-Ok "openssl do Git ($(Get-GitOpenSsl))" } catch { Fail $_.Exception.Message }
    if (Get-Module -ListAvailable powershell-yaml) { Write-Ok 'módulo powershell-yaml' }
    else { Fail 'módulo powershell-yaml ausente (Install-PSResource powershell-yaml -Scope CurrentUser -TrustRepository)' }

    $autocrlf = (& git -C $paths.Repo config --get core.autocrlf) 2>$null
    if ($autocrlf -eq 'false' -or (Test-Path (Join-Path $paths.Repo '.gitattributes'))) { Write-Ok "quebras de linha (core.autocrlf=$autocrlf, .gitattributes presente)" }
    else { Fail 'git core.autocrlf não é false e não há .gitattributes' }

    # Arquivos de texto do repo com CRLF quebrariam nas VMs Linux.
    $crlf = Get-ChildItem -Path (Join-Path $paths.Repo 'labs'), (Join-Path $paths.Repo 'ansible'), (Join-Path $paths.Repo 'kickstart'), (Join-Path $paths.Repo 'image') `
        -Recurse -File -Include *.sh, *.py, *.yml, *.yaml, *.j2, *.tpl, *.json, *.txt -ErrorAction SilentlyContinue |
        Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains("`r`n") }
    if ($crlf) { Fail "arquivos com CRLF (rode 'git add --renormalize .' e confira): $(($crlf | Select-Object -First 5).FullName -join ', ')" }
    else { Write-Ok 'scripts do lab com LF' }

    Write-Step 'Configuração (vmware\settings.psd1)'
    $s = $null
    try { $s = Get-LabSettings; Write-Ok 'settings.psd1 carregado' } catch { Fail $_.Exception.Message }
    if ($s) {
        foreach ($t in 'vmrun.exe', 'vmware-vdiskmanager.exe') {
            try { Write-Ok "$t ($(Get-VmwareTool $s $t))" } catch { Fail $_.Exception.Message }
        }
        if (Test-Path $s.IsoPath) { Write-Ok "ISO ($($s.IsoPath))" } else { Fail "ISO não encontrada: $($s.IsoPath)" }
        if ($s.IsoChecksum -eq 'none') { Write-Warn 'IsoChecksum = none (integridade da ISO não será verificada)' }

        Write-Step "Rede ($($s.VmNet))"
        $hostIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $s.HostIp
        if ($hostIp) { Write-Ok "IP do Windows $($s.HostIp) em '$($hostIp.InterfaceAlias)'" }
        else { Fail "nenhum adaptador do Windows tem o IP $($s.HostIp) (confira HostIp e o adaptador da $($s.VmNet))" }

        $rule = Get-NetFirewallRule -DisplayName 'rhcsa-lab-iac: Packer HTTP' -ErrorAction SilentlyContinue
        if ($rule) { Write-Ok "regra de firewall para a porta $($s.PackerHttpPort)" }
        else { Fail 'regra de firewall do Packer ausente (rode vmware\setup-host.ps1 como administrador)' }

        $dhcpConf = Join-Path $env:ProgramData 'VMware\vmnetdhcp.conf'
        if ((Test-Path $dhcpConf) -and (Select-String -Path $dhcpConf -Pattern '# BEGIN rhcsa-lab-iac' -Quiet)) { Write-Ok 'reservas DHCP do lab no vmnetdhcp.conf' }
        else { Fail 'reservas DHCP do lab ausentes (rode vmware\setup-host.ps1 como administrador)' }
    }

    Write-Step 'Tradução de IPs (vmware\ip-map.yaml)'
    try {
        $ipMap = Get-IpMap
        Write-Ok "$($ipMap.FromCidr) -> $($ipMap.ToCidr), $($ipMap.Map.Count) endereços"
        $files = Get-ChildItem -Path $paths.Repo -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|\.work|terraform)[\\/]' -and $_.Length -lt 5MB } |
            Where-Object { $_.Extension -notin '.png', '.jpg', '.iso', '.vmdk', '.qcow2', '.gif', '.ico' }
        $touched = 0
        foreach ($f in $files) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($text.Contains($ipMap.FromPrefix + '.')) {
                [void](Convert-LabText -Text $text -IpMap $ipMap -Source $f.FullName.Substring($paths.Repo.Length + 1))
                $touched++
            }
        }
        Write-Ok "todos os IPs do projeto têm tradução ($touched arquivos usam a rede do lab)"
        $m = Get-LabMachines
        foreach ($name in $m.machines.Keys) { Write-Ok ("{0,-12} {1}" -f $name, $m.machines[$name].ip) }
    } catch { Fail $_.Exception.Message }

    if ($s -and $m) {
        Write-Step 'Imagem golden'
        $vmx = Get-GoldenVmx $s $m.image
        if (Test-Path $vmx) {
            $snaps = Invoke-Vmrun $s @('listSnapshots', $vmx) -AllowFailure
            if ($snaps -match '^\s*base\s*$') { Write-Ok "$vmx (snapshot 'base')" }
            else { Fail "golden existe sem o snapshot 'base' (rode: .\vmware\lab.ps1 image -Force)" }
        } else { Write-Warn "golden ainda não construída (rode: .\vmware\lab.ps1 image)" }
    }

    Write-Host ''
    if ($script:problems -eq 0) { Write-Host 'Tudo certo.' -ForegroundColor Green; return }
    Write-Host "$script:problems problema(s) encontrado(s)." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------ image ---
function Invoke-Image {
    $paths = Get-LabPaths
    $s = Get-LabSettings
    $m = Get-LabMachines
    $imageName = $m.image
    $studentUser = $m.student.username
    $outDir = Join-Path $s.GoldenDir $imageName
    $vmx = Get-GoldenVmx $s $imageName

    if ((Test-Path $vmx) -and -not $Force) {
        Write-Host "A imagem golden já existe: $vmx"
        Write-Host 'Use -Force para reconstruir (só depois de apagar as VMs do lab, que dependem dela).'
        return
    }
    if ($Force -and (Test-Path $s.LabDir) -and (Get-ChildItem $s.LabDir -Recurse -Filter *.vmx -ErrorAction SilentlyContinue)) {
        throw "Há VMs do lab em $($s.LabDir) que são clones vinculados da golden. Apague-as antes (fase 2: lab.ps1 down)."
    }
    if (-not (Test-Path $s.IsoPath)) { throw "ISO não encontrada: $($s.IsoPath)" }

    Initialize-StudentKey | Out-Null

    Write-Step 'Renderizando o kickstart (kickstart/ks.cfg.tpl + adaptações VMware)'
    $ks = New-LabKickstart -Settings $s -StudentUser $studentUser
    Write-Ok $ks

    if (Test-Path $outDir) {
        Write-Step "Removendo golden anterior ($outDir)"
        Remove-Item -Recurse -Force $outDir
    }
    New-Item -ItemType Directory -Force -Path $s.GoldenDir | Out-Null

    # Variáveis em arquivo JSON: evita qualquer problema de aspas/barras do
    # Windows na linha de comando do packer.
    $vars = [ordered]@{
        # file:/// evita que o "D:" do caminho seja lido como esquema de URL.
        iso_path        = 'file:///' + ($s.IsoPath -replace '\\', '/')
        iso_checksum    = $s.IsoChecksum
        output_dir      = $outDir -replace '\\', '/'
        vm_name         = $imageName
        network         = $s.VmNet
        host_ip         = $s.HostIp
        http_dir        = $paths.Http -replace '\\', '/'
        http_port       = [int]$s.PackerHttpPort
        student_user    = $studentUser
        ssh_key_file    = $paths.StudentKey -replace '\\', '/'
        finalize_script = $paths.Finalize -replace '\\', '/'
        headless        = [bool]$s.PackerHeadless
        boot_menu       = $s.BootMenu
    }
    $varFile = Join-Path $paths.Work 'golden.pkrvars.json'
    $vars | ConvertTo-Json | Set-Content -Path $varFile -Encoding utf8NoBOM

    Push-Location $paths.PackerDir
    try {
        Write-Step 'packer init (baixa o plugin VMware na primeira vez)'
        & packer init .
        if ($LASTEXITCODE -ne 0) { throw 'packer init falhou.' }

        Write-Step 'packer build (instalação desassistida, 10-20 minutos)'
        $env:PACKER_LOG = '1'
        $env:PACKER_LOG_PATH = Join-Path $paths.Work 'packer-build.log'
        & packer build -force "-var-file=$varFile" .
        if ($LASTEXITCODE -ne 0) { throw "packer build falhou. Log detalhado: $($env:PACKER_LOG_PATH)" }
    } finally {
        Remove-Item Env:PACKER_LOG, Env:PACKER_LOG_PATH -ErrorAction SilentlyContinue
        Pop-Location
    }

    # O kickstart renderizado tem o hash da senha: não fica largado em disco.
    Remove-Item -Force (Join-Path $paths.Http 'ks.cfg') -ErrorAction SilentlyContinue

    Write-Step "Snapshot 'base' (ponto de partida dos clones vinculados)"
    Invoke-Vmrun $s @('snapshot', $vmx, 'base') | Out-Null
    Write-Ok $vmx

    Write-Host ''
    Write-Host 'Imagem golden pronta. Não ligue esta VM: ela é só a base dos clones.' -ForegroundColor Green
}

# --------------------------------------------------------------------- up ---
# Configura o .vmx de um clone recém-criado: CPU/memória, NICs com os MACs
# fixos de machines.yaml na VMnet do lab e os discos extra brutos, na ordem
# de machines.yaml (todos no controlador SCSI, depois do disco do SO:
# serverb fica com sdb=6G, sdc=1G, sdd=2G, sde=3G; os exercícios acham os
# discos por tamanho, nunca pelo nome).
function Set-LabVmConfig([hashtable]$Settings, [string]$VmName, $Spec, [string]$Vmx) {
    $vmDir = Split-Path -Parent $Vmx
    $vdisk = Get-VmwareTool $Settings 'vmware-vdiskmanager.exe'
    $cfg = Read-Vmx $Vmx

    $cfg['displayName'] = "rhcsa-lab-$VmName"
    $cfg['memsize']     = [string]$Spec.memory_mb
    $cfg['numvcpus']    = [string]$Spec.cpus
    # Responde sozinho a perguntas do tipo "você moveu ou copiou esta VM?",
    # que deixariam o vmrun start pendurado.
    $cfg['msg.autoAnswer'] = 'TRUE'
    # O CD da golden fica desconectado (a ISO só volta na fase 3, se preciso).
    foreach ($k in @($cfg.Keys | Where-Object { $_ -match '^(ide|sata)\d+:\d+\.deviceType$' -and $cfg[$_] -like 'cdrom*' })) {
        $dev = $k -replace '\.deviceType$', ''
        $cfg["$dev.startConnected"] = 'FALSE'
    }

    # NICs: substitui a placa da golden pelas de machines.yaml.
    Remove-VmxKeys $cfg '^ethernet\d+\.'
    $i = 0
    foreach ($nic in $Spec.nics) {
        $e = "ethernet$i"
        $cfg["$e.present"]         = 'TRUE'
        $cfg["$e.connectionType"]  = 'custom'
        $cfg["$e.vnet"]            = $Settings.VmNet
        $cfg["$e.virtualDev"]      = 'vmxnet3'
        $cfg["$e.addressType"]     = 'static'
        $cfg["$e.address"]         = ([string]$nic.mac).ToLower()
        # MACs do homelab (prefixo bc:24:11, do Proxmox) ficam fora da faixa
        # estática do VMware (00:50:56); sem isto o VMware recusa o endereço.
        $cfg["$e.checkMACAddress"] = 'FALSE'
        $cfg["$e.startConnected"]  = 'TRUE'
        $i++
    }

    # Discos extra no scsi0, a partir da unidade 1 (a 0 é o disco do SO).
    $unit = 1
    if ($Spec.Contains('extra_disks')) {
        foreach ($d in $Spec.extra_disks) {
            if ($unit -eq 7) { $unit++ }   # scsi0:7 é reservado ao controlador
            $file = "$VmName-$($d.label).vmdk"
            $full = Join-Path $vmDir $file
            if (-not (Test-Path $full)) {
                & $vdisk -c -s "$($d.size_gb)GB" -a lsilogic -t 0 $full | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "vmware-vdiskmanager falhou ao criar $file" }
            }
            $cfg["scsi0:$unit.present"]  = 'TRUE'
            $cfg["scsi0:$unit.fileName"] = $file
            $cfg["scsi0:$unit.mode"]     = 'persistent'
            Write-Ok ("{0,-12} disco {1} GiB -> scsi0:{2} ({3})" -f $VmName, $d.size_gb, $unit, $d.label)
            $unit++
        }
    }

    Write-Vmx $Vmx $cfg
}

function Invoke-Up {
    $s = Get-LabSettings
    $m = Get-LabMachines
    $golden = Get-GoldenVmx $s $m.image
    if (-not (Test-Path $golden)) { throw 'A imagem golden não existe. Rode: .\vmware\lab.ps1 image' }
    $snaps = Invoke-Vmrun $s @('listSnapshots', $golden)
    if (-not ($snaps -match '^\s*base\s*$')) { throw "A golden não tem o snapshot 'base'. Rode: .\vmware\lab.ps1 image -Force" }
    $key = Initialize-StudentKey

    foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        $vmx = Get-LabVmx $s $vmName

        if (Test-Path $vmx) {
            Write-Step "$vmName já existe ($vmx)"
        } else {
            Write-Step "Clonando $vmName (clone vinculado de '$($m.image)', snapshot 'base')"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vmx) | Out-Null
            Invoke-Vmrun $s @('clone', $golden, $vmx, 'linked', '-snapshot=base', "-cloneName=rhcsa-lab-$vmName") | Out-Null
            Set-LabVmConfig -Settings $s -VmName $vmName -Spec $spec -Vmx $vmx
            Write-Ok ("{0,-12} {1} vCPU, {2} MiB, {3} NIC(s), IP {4}" -f $vmName, $spec.cpus, $spec.memory_mb, @($spec.nics).Count, $spec.ip)
        }

        if (Test-VmRunning $s $vmx) {
            Write-Ok "$vmName já está ligada"
        } else {
            Invoke-Vmrun $s @('start', $vmx, ($(if ($Gui) { 'gui' } else { 'nogui' }))) | Out-Null
            Write-Ok "$vmName ligada"
        }
    }

    Write-Step 'Aguardando SSH nas VMs (primeiro boot gera chaves e machine-id)'
    foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        Wait-LabSsh $vmName $spec.ip
        Write-Ok "$vmName ($($spec.ip)) responde SSH"
    }

    Write-Step 'Conferindo NICs e discos dentro das VMs'
    $problems = 0
    foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        # Sem aspas duplas no comando remoto: elas passariam por duas camadas
        # de escape (PowerShell -> ssh.exe -> shell remoto).
        $r = Invoke-LabSsh $spec.ip "ip -br link | awk '{print `$3}'; echo ---; lsblk -dnbo SIZE,TYPE | awk '`$2 ~ /disk/ {print `$1}'"
        if ($r.ExitCode -ne 0) { Write-Fail "${vmName}: falha ao consultar NICs/discos: $($r.Output -join ' ')"; $problems++; continue }
        $parts = @(($r.Output -join "`n") -split '---') + @('', '')
        $macs  = @($parts[0] -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
        $sizes = @($parts[1] -split '\s+' | Where-Object { $_ })
        foreach ($nic in $spec.nics) {
            $mac = ([string]$nic.mac).ToLower()
            if ($macs -contains $mac) { Write-Ok "$vmName NIC $mac (vai virar $($nic.name))" }
            else { Write-Fail "$vmName sem NIC com MAC $mac"; $problems++ }
        }
        if ($spec.Contains('extra_disks')) {
            foreach ($d in $spec.extra_disks) {
                $bytes = [string]([int64]$d.size_gb * 1GB)
                if ($sizes -contains $bytes) { Write-Ok "$vmName disco de $($d.size_gb) GiB presente" }
                else { Write-Fail "$vmName sem disco de $($d.size_gb) GiB ($bytes bytes)"; $problems++ }
            }
        }
    }

    Write-Host ''
    if ($problems -gt 0) { Write-Host "$problems problema(s) na conferência." -ForegroundColor Red; exit 1 }
    Write-Host 'Infraestrutura do lab no ar.' -ForegroundColor Green
    Write-Host 'Próximo passo (fase 3): provisionamento com o Ansible. Por ora: .\vmware\lab.ps1 ssh workstation'
}

# ------------------------------------------------------------------- down ---
function Invoke-Down {
    $s = Get-LabSettings
    $paths = Get-LabPaths
    $vmxFiles = @(Get-ChildItem -Path $s.LabDir -Recurse -Filter *.vmx -ErrorAction SilentlyContinue)
    if ($vmxFiles.Count -eq 0) {
        Write-Host "Nenhuma VM do lab em $($s.LabDir)."
    } else {
        Write-Host 'VMs que serão APAGADAS:'
        $vmxFiles | ForEach-Object { Write-Host "  $($_.FullName)" }
        if (-not $Force) {
            $ans = Read-Host 'Confirma? Digite "sim"'
            if ($ans -ne 'sim') { Write-Host 'Cancelado.'; return }
        }
        # Fase 4: antes de apagar, desregistrar cada VM da subscription Red Hat.
        foreach ($f in $vmxFiles) {
            $vmx = $f.FullName
            $label = $f.BaseName
            if (Test-VmRunning $s $vmx) {
                Write-Step "Desligando $label"
                Invoke-Vmrun $s @('stop', $vmx, 'soft') -AllowFailure | Out-Null
                if (Test-VmRunning $s $vmx) { Invoke-Vmrun $s @('stop', $vmx, 'hard') -AllowFailure | Out-Null }
            }
            Write-Step "Apagando $label"
            Invoke-Vmrun $s @('deleteVM', $vmx) -AllowFailure | Out-Null
            $dir = $f.DirectoryName
            if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
            Write-Ok $label
        }
    }
    Remove-Item -Force (Join-Path $paths.Work 'known_hosts') -ErrorAction SilentlyContinue
    Write-Host 'Lab removido. A imagem golden continua intacta.' -ForegroundColor Green
}

# ----------------------------------------------------------------- status ---
function Invoke-Status {
    $s = Get-LabSettings
    $m = Get-LabMachines
    $rows = foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        $vmx = Get-LabVmx $s $vmName
        $state = if (-not (Test-Path $vmx)) { 'não criada' } elseif (Test-VmRunning $s $vmx) { 'ligada' } else { 'desligada' }
        $ssh = if ($state -eq 'ligada' -and (Test-TcpPort $spec.ip 22)) { 'ok' } else { '-' }
        [pscustomobject]@{ VM = $vmName; IP = $spec.ip; Estado = $state; SSH = $ssh }
    }
    $rows | Format-Table -AutoSize
    $golden = Get-GoldenVmx $s $m.image
    Write-Host ("Golden: {0}" -f $(if (Test-Path $golden) { $golden } else { 'não construída' }))
}

# -------------------------------------------------------------------- ssh ---
function Invoke-Ssh {
    $m = Get-LabMachines
    if (-not $Name -or -not $m.machines.Contains($Name)) {
        throw "Informe a VM: .\vmware\lab.ps1 ssh <$((@($m.machines.Keys)) -join '|')>"
    }
    $ip = $m.machines[$Name].ip
    # Sem BatchMode (sessão interativa): remove o par '-o BatchMode=yes'.
    $sshArgs = @(); $all = Get-LabSshArgs
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -eq '-o' -and $all[$i + 1] -eq 'BatchMode=yes') { $i++; continue }
        $sshArgs += $all[$i]
    }
    & ssh.exe @sshArgs "student@$ip"
}

# ------------------------------------------------------------------- main ---
switch ($Command) {
    'check'  { Invoke-Check }
    'image'  { Invoke-Image }
    'up'     { Invoke-Up }
    'down'   { Invoke-Down }
    'status' { Invoke-Status }
    'ssh'    { Invoke-Ssh }
    default  { Get-Help $PSCommandPath -Detailed }
}
