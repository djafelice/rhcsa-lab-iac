#Requires -Version 7.2
<#
.SYNOPSIS
    Backend VMware Workstation do rhcsa-lab-iac (Windows).

.DESCRIPTION
    Comandos:
      check   Confere ferramentas, configuração, rede e tradução de IPs.
      image   Constrói a imagem golden RHEL 10 com o Packer (uma vez).
      up         Cria (clones vinculados da golden), liga e provisiona as
                 3 VMs do lab e tira o snapshot 'pronto'. Se o lab já
                 existe e já foi provisionado, só liga as VMs.
                 -NoProvision: só a infraestrutura.
      provision  Roda (de novo) o provisionamento Ansible e refaz o snapshot.
      stop       Desliga as 3 VMs, mantendo tudo (exercícios em andamento).
      start      Liga as 3 VMs de novo, do ponto em que pararam.
      snapshot   Desliga as VMs e (re)tira o snapshot 'pronto' do estado atual.
      reset      Volta as 3 VMs ao snapshot 'pronto' (descarta o que mudou).
      down       Desregistra da Red Hat, desliga e apaga as 3 VMs do lab
                 (a golden não é tocada).
      status     Estado das VMs, snapshot e provisionamento.
      ssh        Abre SSH como student numa VM: lab.ps1 ssh servera
      help       Mostra esta ajuda.

    Rode tudo numa sessão NORMAL do PowerShell 7 (sem administrador).
    Só o setup-host.ps1 precisa de administrador.

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
    [ValidateSet('check', 'image', 'up', 'provision', 'stop', 'start', 'snapshot', 'reset', 'down', 'status', 'ssh', 'help')]
    [string]$Command = 'help',

    # ssh: nome da VM (workstation, servera, serverb).
    [Parameter(Position = 1)]
    [string]$Name,

    # image: reconstrói a golden mesmo se já existir.
    # down, reset: não pedem confirmação.
    [switch]$Force,

    # up: liga as VMs com janela no VMware Workstation (padrão: em segundo plano).
    [switch]$Gui,

    # up: cria só a infraestrutura, sem rodar o Ansible.
    [switch]$NoProvision
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
    try { Import-LabYaml; Write-Ok "módulo powershell-yaml ($((Get-Module powershell-yaml).ModuleBase))" }
    catch { Fail $_.Exception.Message }

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
function Set-LabVmConfig([hashtable]$Settings, [string]$VmName, $Spec, [string]$Vmx, [bool]$IsController = $false) {
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
    # A workstation (controladora do provisionamento e host do classroom)
    # recebe a ISO no CD: dela saem o ansible-core e o mirror de pacotes.
    if ($IsController) {
        [void](Set-VmxCdrom $cfg $Settings.IsoPath)
        Write-Ok "$VmName com a ISO no CD-ROM (provisionamento)"
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
    if (-not $NoProvision -and -not (Test-Path -LiteralPath $s.IsoPath -PathType Leaf)) {
        throw "ISO não encontrada em '$($s.IsoPath)' (o provisionamento precisa dela). Ajuste IsoPath em vmware\settings.psd1."
    }
    $snaps = Invoke-Vmrun $s @('listSnapshots', $golden)
    if (-not ($snaps -match '^\s*base\s*$')) { throw "A golden não tem o snapshot 'base'. Rode: .\vmware\lab.ps1 image -Force" }
    $key = Initialize-StudentKey
    $marker = Get-ProvisionMarker $s
    $created = $false

    foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        $vmx = Get-LabVmx $s $vmName

        if (Test-Path $vmx) {
            Write-Step "$vmName já existe ($vmx)"
        } else {
            Write-Step "Clonando $vmName (clone vinculado de '$($m.image)', snapshot 'base')"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vmx) | Out-Null
            Invoke-Vmrun $s @('clone', $golden, $vmx, 'linked', '-snapshot=base', "-cloneName=rhcsa-lab-$vmName") | Out-Null
            Set-LabVmConfig -Settings $s -VmName $vmName -Spec $spec -Vmx $vmx -IsController ($vmName -eq $m.classroom.host)
            $created = $true
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

    # VM nova = lab ainda não provisionado, mesmo que sobre um marcador antigo.
    if ($created) { Remove-Item -Force $marker -ErrorAction SilentlyContinue }

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
    if ($NoProvision) {
        Write-Host 'Provisionamento pulado (-NoProvision). Quando quiser: .\vmware\lab.ps1 provision'
        return
    }
    if (Test-Path $marker) {
        Write-Host "Lab já provisionado em $((Get-Content $marker -Raw).Trim()); só liguei as VMs."
        Write-Host '  Para voltar ao estado limpo: .\vmware\lab.ps1 reset'
        Write-Host '  Para rodar o Ansible de novo: .\vmware\lab.ps1 provision'
        return
    }
    Invoke-Provision
}

# ------------------------------------------------- ciclo de vida do lab ---
$script:SnapshotName = 'pronto'

function Get-ProvisionMarker([hashtable]$Settings) { Join-Path $Settings.LabDir '.provisionado' }

# VMs do lab que existem em disco, na ordem de machines.yaml.
function Get-ExistingLabVms([hashtable]$Settings, $Machines, [switch]$RequireAll) {
    $list = foreach ($vmName in $Machines.machines.Keys) {
        $vmx = Get-LabVmx $Settings $vmName
        if (Test-Path $vmx) { [pscustomobject]@{ Name = $vmName; Vmx = $vmx; Ip = $Machines.machines[$vmName].ip } }
        elseif ($RequireAll) { throw "$vmName não existe. Rode: .\vmware\lab.ps1 up" }
    }
    return @($list)
}

function Test-LabSnapshot([hashtable]$Settings, [string]$Vmx) {
    $snaps = Invoke-Vmrun $Settings @('listSnapshots', $Vmx) -AllowFailure
    return [bool]($snaps -match "^\s*$($script:SnapshotName)\s*$")
}

function Start-LabVms([hashtable]$Settings, $Vms) {
    foreach ($v in $Vms) {
        if (Test-VmRunning $Settings $v.Vmx) { Write-Ok "$($v.Name) já está ligada"; continue }
        Invoke-Vmrun $Settings @('start', $v.Vmx, ($(if ($Gui) { 'gui' } else { 'nogui' }))) | Out-Null
        Write-Ok "$($v.Name) ligada"
    }
    Write-Step 'Aguardando SSH'
    foreach ($v in $Vms) { Wait-LabSsh $v.Name $v.Ip; Write-Ok "$($v.Name) ($($v.Ip)) responde SSH" }
}

function Stop-LabVms([hashtable]$Settings, $Vms, [switch]$Hard) {
    foreach ($v in $Vms) {
        if (-not (Test-VmRunning $Settings $v.Vmx)) { Write-Ok "$($v.Name) já está desligada"; continue }
        if ($Hard) { Invoke-Vmrun $Settings @('stop', $v.Vmx, 'hard') -AllowFailure | Out-Null }
        else { Stop-LabVm $Settings $v.Vmx }
        Write-Ok "$($v.Name) desligada"
    }
}

function Invoke-Stop {
    $s = Get-LabSettings
    $vms = Get-ExistingLabVms $s (Get-LabMachines)
    if ($vms.Count -eq 0) { Write-Host 'Nenhuma VM do lab criada.'; return }
    Write-Step 'Desligando o lab (desligamento limpo; nada é perdido)'
    Stop-LabVms $s $vms
    Write-Host 'Lab desligado. Para continuar de onde parou: .\vmware\lab.ps1 start' -ForegroundColor Green
}

function Invoke-Start {
    $s = Get-LabSettings
    $vms = Get-ExistingLabVms $s (Get-LabMachines) -RequireAll
    Write-Step 'Ligando o lab'
    Start-LabVms $s $vms
    Write-Host 'Lab no ar. .\vmware\lab.ps1 ssh workstation' -ForegroundColor Green
}

# Snapshot com as VMs DESLIGADAS: estado de disco consistente, sem memória
# (menor, e sem o relógio "congelado" que um snapshot de VM ligada traria
# de volta no reset).
function Invoke-Snapshot([switch]$Quiet) {
    $s = Get-LabSettings
    $m = Get-LabMachines
    $vms = Get-ExistingLabVms $s $m -RequireAll
    Write-Step "Snapshot '$($script:SnapshotName)' das 3 VMs (desliga, fotografa e religa)"
    Stop-LabVms $s $vms
    foreach ($v in $vms) {
        if ($v.Name -eq $m.classroom.host) {
            # Sem ISO no CD no estado salvo, como no homelab. (O provision
            # reconecta a ISO sozinho quando precisa dela.)
            $cfg = Read-Vmx $v.Vmx
            [void](Set-VmxCdrom $cfg '')
            Write-Vmx $v.Vmx $cfg
        }
        if (Test-LabSnapshot $s $v.Vmx) {
            Invoke-Vmrun $s @('deleteSnapshot', $v.Vmx, $script:SnapshotName) | Out-Null
        }
        Invoke-Vmrun $s @('snapshot', $v.Vmx, $script:SnapshotName) | Out-Null
        Write-Ok "$($v.Name): snapshot '$($script:SnapshotName)'"
    }
    Start-LabVms $s $vms
    if (-not $Quiet) {
        Write-Host "Snapshot salvo. .\vmware\lab.ps1 reset volta a este ponto." -ForegroundColor Green
    }
}

function Invoke-Reset {
    $s = Get-LabSettings
    $vms = Get-ExistingLabVms $s (Get-LabMachines) -RequireAll
    foreach ($v in $vms) {
        if (-not (Test-LabSnapshot $s $v.Vmx)) {
            throw "$($v.Name) não tem o snapshot '$($script:SnapshotName)'. Rode: .\vmware\lab.ps1 snapshot (ou provision)"
        }
    }
    if (-not $Force) {
        Write-Host "Reset: as 3 VMs voltam ao snapshot '$($script:SnapshotName)'. Tudo o que foi feito depois dele"
        Write-Host 'é DESCARTADO, inclusive o histórico do dashboard e exercícios em andamento.'
        $ans = Read-Host 'Confirma? Digite "sim"'
        if ($ans -ne 'sim') { Write-Host 'Cancelado.'; return }
    }
    Write-Step 'Desligando (o estado atual vai ser descartado)'
    Stop-LabVms $s $vms -Hard
    Write-Step "Voltando ao snapshot '$($script:SnapshotName)'"
    foreach ($v in $vms) {
        Invoke-Vmrun $s @('revertToSnapshot', $v.Vmx, $script:SnapshotName) | Out-Null
        Write-Ok $v.Name
    }
    Write-Step 'Ligando'
    Start-LabVms $s $vms
    Write-Host 'Lab de volta ao estado limpo.' -ForegroundColor Green
}

# -------------------------------------------------------------- provision ---
# Liga/desliga uma VM e espera o estado (vmrun stop soft depende do
# open-vm-tools, presente na golden).
function Stop-LabVm([hashtable]$Settings, [string]$Vmx) {
    Invoke-Vmrun $Settings @('stop', $Vmx, 'soft') -AllowFailure | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Test-VmRunning $Settings $Vmx) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
    if (Test-VmRunning $Settings $Vmx) { Invoke-Vmrun $Settings @('stop', $Vmx, 'hard') -AllowFailure | Out-Null }
}

# Dispara uma fase do run.sh na controladora via systemd-run (sobrevive a
# quedas do SSH) e acompanha o log por polling até o código de saída.
function Invoke-RemotePhase([string]$Ip, [string]$Phase, [int]$TimeoutMin) {
    $log = "/var/log/rhcsa-lab-provision-$Phase.log"
    $rc  = "/var/log/rhcsa-lab-provision-$Phase.rc"
    $r = Invoke-LabSsh $Ip "sudo rm -f $log $rc; sudo systemd-run --quiet --unit=rhcsa-lab-provision-$Phase --collect -p StandardOutput=append:$log -p StandardError=append:$log /bin/bash /root/rhcsa-provision/run.sh $Phase"
    if ($r.ExitCode -ne 0) { throw "Não consegui iniciar a fase '$Phase': $($r.Output -join ' ')" }

    $next = 1
    $warned = $false
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ($true) {
        Start-Sleep -Seconds 5
        $cmd = 'n=$(sudo cat {0} 2>/dev/null | wc -l); n=${{n:-0}}; [ $n -ge {2} ] && sudo sed -n {2},${{n}}p {0}; echo __N__$n; sudo cat {1} 2>/dev/null' -f $log, $rc, $next
        $p = Invoke-LabSsh $Ip $cmd
        if ($p.ExitCode -eq 255) {
            if (-not $warned) { Write-Warn 'SSH com a workstation caiu; o provisionamento continua lá dentro, reconectando...'; $warned = $true }
            if ((Get-Date) -gt $deadline) { throw "Tempo esgotado na fase '$Phase'." }
            continue
        }
        $warned = $false
        $code = $null
        $afterMarker = $false
        foreach ($line in $p.Output) {
            $l = [string]$line
            if ($afterMarker) { if ($l.Trim() -match '^\d+$') { $code = [int]$l.Trim() }; continue }
            if ($l -match '^__N__(\d+)$') { $next = [int]$Matches[1] + 1; $afterMarker = $true; continue }
            Write-Host $l
        }
        if ($null -ne $code) {
            if ($code -ne 0) { throw "A fase '$Phase' falhou (código $code). Log completo na workstation: $log" }
            return
        }
        if ((Get-Date) -gt $deadline) { throw "Tempo esgotado na fase '$Phase' ($TimeoutMin min). Log: $log" }
    }
}

function Invoke-Provision {
    $s = Get-LabSettings
    $m = Get-LabMachines
    $paths = Get-LabPaths
    if ([string]::IsNullOrWhiteSpace($s.RhsmOrgId) -or [string]::IsNullOrWhiteSpace($s.RhsmActivationKey)) {
        throw 'Preencha RhsmOrgId e RhsmActivationKey em vmware\settings.psd1 (subscription Red Hat Developer).'
    }
    # O VMware não avisa se a ISO sumiu: com msg.autoAnswer ele liga a VM
    # com o CD vazio em silêncio (só o vmware.log registra). Confere antes.
    if (-not (Test-Path -LiteralPath $s.IsoPath -PathType Leaf)) {
        throw "ISO não encontrada em '$($s.IsoPath)'. Ajuste IsoPath em vmware\settings.psd1."
    }
    $ctl = [string]$m.classroom.host
    $ctlIp = $m.machines[$ctl].ip
    $ctlVmx = Get-LabVmx $s $ctl
    $key = Initialize-StudentKey

    Write-Step 'Conferindo as VMs'
    foreach ($vmName in $m.machines.Keys) {
        $vmx = Get-LabVmx $s $vmName
        if (-not (Test-Path $vmx) -or -not (Test-VmRunning $s $vmx)) { throw "$vmName não está criada/ligada. Rode: .\vmware\lab.ps1 up" }
        Wait-LabSsh $vmName $m.machines[$vmName].ip 120
    }
    Write-Ok 'as 3 VMs respondem SSH'

    # Confere a mídia DENTRO da VM (o .vmx pode dizer que a ISO está lá e o
    # CD ter ligado vazio). Sem mídia: reescreve o CD e religa a VM.
    $hasMedia = { (Invoke-LabSsh $ctlIp 'sudo blkid -o value -s LABEL /dev/sr0').ExitCode -eq 0 }
    if (-not (& $hasMedia)) {
        Write-Step "Conectando a ISO ao CD da $ctl (desliga e religa a VM)"
        Stop-LabVm $s $ctlVmx
        $cfg = Read-Vmx $ctlVmx
        [void](Set-VmxCdrom $cfg $s.IsoPath)
        Write-Vmx $ctlVmx $cfg
        Invoke-Vmrun $s @('start', $ctlVmx, ($(if ($Gui) { 'gui' } else { 'nogui' }))) | Out-Null
        Wait-LabSsh $ctl $ctlIp
        if (-not (& $hasMedia)) {
            $vmLog = Join-Path (Split-Path -Parent $ctlVmx) 'vmware.log'
            $why = Select-String -Path $vmLog -Pattern 'cdromImage\.cantOpen|Failed to open' -ErrorAction SilentlyContinue | Select-Object -Last 1
            throw "A $ctl continua sem mídia no CD. Motivo no vmware.log: $(if ($why) { $why.Line } else { '(nada registrado)' })"
        }
    }
    $label = (Invoke-LabSsh $ctlIp 'sudo blkid -o value -s LABEL /dev/sr0').Output -join ''
    Write-Ok "ISO no CD da ${ctl}: $label"

    Write-Step 'Montando a cópia traduzida do repositório (vmware\.work\stage)'
    $stage = New-LabStage
    Write-Ok "$($stage.Translated) arquivos com IPs traduzidos para $((Get-IpMap).ToCidr)"
    $inv = New-LabInventory $m '/root/rhcsa-provision/student_key'
    New-Item -ItemType Directory -Force -Path (Join-Path $stage.Path 'output') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stage.Path 'output\inventory.yml'), $inv, [System.Text.UTF8Encoding]::new($false))
    $execList = Join-Path $paths.Stage 'executables.txt'
    [System.IO.File]::WriteAllText($execList, (($stage.Executables -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    $tgz = Join-Path $paths.Stage 'repo.tgz'
    & tar.exe -czf $tgz -C $paths.Stage repo
    if ($LASTEXITCODE -ne 0) { throw 'tar falhou ao empacotar a cópia do repositório.' }
    Write-Ok "$([math]::Round((Get-Item $tgz).Length / 1MB, 1)) MB empacotados"

    Write-Step "Enviando para a $ctl (controladora temporária do Ansible)"
    $up = '/tmp/rhcsa-provision-upload'
    $r = Invoke-LabSsh $ctlIp "rm -rf $up && mkdir -m 700 $up"
    if ($r.ExitCode -ne 0) { throw "Falha ao preparar $up na $ctl." }
    $sshArgs = Get-LabSshArgs
    & scp.exe -q @sshArgs $tgz $key (Join-Path $paths.Provision 'run.sh') $execList "student@${ctlIp}:$up/"
    if ($LASTEXITCODE -ne 0) { throw 'scp falhou ao enviar os arquivos.' }
    $r = Invoke-LabSsh $ctlIp "sudo bash $up/run.sh unpack"
    if ($r.ExitCode -ne 0) { throw "Falha ao instalar os arquivos na ${ctl}: $($r.Output -join ' ')" }
    Write-Ok ($r.Output -join ' ')
    # Segredos pelo stdin do ssh: nunca são gravados no disco do Windows.
    # O PowerShell termina o que envia por pipe com CRLF: o tr remove o \r.
    (New-LabEnvFile $s) | & ssh.exe @sshArgs "student@$ctlIp" 'tr -d ''\r'' | sudo install -m 600 /dev/stdin /root/rhcsa-provision/lab.env'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao gravar as variáveis da subscription na controladora.' }
    Write-Ok 'repositório, chave e variáveis instalados em /root/rhcsa-provision'

    $hadEns18 = (Invoke-LabSsh $ctlIp 'ip -br link show ens18').ExitCode -eq 0

    Write-Step "Preparando a controladora (ansible-core da ISO, collections, rede da $ctl)"
    Invoke-RemotePhase $ctlIp 'prepare' 20

    if (-not $hadEns18) {
        Write-Step "Reiniciando a $ctl para aplicar ens18"
        Invoke-LabSsh $ctlIp 'sudo systemctl reboot' | Out-Null
        Start-Sleep -Seconds 15
        Wait-LabSsh $ctl $ctlIp
        if ((Invoke-LabSsh $ctlIp 'ip -br link show ens18').ExitCode -ne 0) { throw "A $ctl voltou sem a interface ens18." }
        Write-Ok "$ctl com ens18"
    }

    Write-Step 'Rodando ansible/site.yml (registro, pacotes, classroom, exercícios, dashboard: 15-30 min)'
    Invoke-RemotePhase $ctlIp 'site' 120

    Write-Step 'Guardando os logs em vmware\.work\logs e limpando a controladora'
    New-Item -ItemType Directory -Force -Path $paths.Logs | Out-Null
    & scp.exe -q @sshArgs "student@${ctlIp}:/var/log/rhcsa-lab-provision-*.log" $paths.Logs 2>$null
    $r = Invoke-LabSsh $ctlIp 'sudo bash /root/rhcsa-provision/run.sh cleanup; sudo rm -f /var/log/rhcsa-lab-provision-*'
    if ($r.ExitCode -ne 0) { Write-Warn "limpeza incompleta: $($r.Output -join ' ')" } else { Write-Ok 'ansible-core, chave e segredos removidos da controladora' }
    Remove-Item -Recurse -Force $paths.Stage -ErrorAction SilentlyContinue

    # Tira a ISO do CD sem desligar a VM (igual ao homelab, sem mídia).
    $dev = (Read-Vmx $ctlVmx).Keys | Where-Object { $_ -match '^(ide|sata)\d+:\d+\.deviceType$' } | Select-Object -First 1
    if ($dev) {
        $dev = $dev -replace '\.deviceType$', ''
        Invoke-Vmrun $s @('disconnectNamedDevice', $ctlVmx, $dev) -AllowFailure | Out-Null
    }

    Write-Step 'Resultado'
    foreach ($vmName in $m.machines.Keys) {
        $h = Invoke-LabSsh $m.machines[$vmName].ip 'hostname'
        Write-Ok ("{0,-12} {1}  ({2})" -f $vmName, ($h.Output -join ''), $m.machines[$vmName].ip)
    }
    Set-Content -Path (Get-ProvisionMarker $s) -Value (Get-Date -Format 'yyyy-MM-dd HH:mm') -Encoding utf8NoBOM

    # Estado limpo recém-provisionado: base do `reset`.
    Invoke-Snapshot -Quiet

    Write-Host ''
    Write-Host "Lab provisionado, com snapshot '$($script:SnapshotName)' para o reset." -ForegroundColor Green
    Write-Host "  Dashboard: http://${ctlIp}:$($m.dashboard.port)"
    Write-Host '  Estudar:   .\vmware\lab.ps1 ssh workstation   e depois:  lab list'
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
        # Desregistra da Red Hat antes de apagar: sem isto, cada ciclo
        # up/down deixaria 3 sistemas órfãos na sua conta.
        $m = Get-LabMachines
        foreach ($f in $vmxFiles) {
            $vmName = $f.BaseName
            if ($m.machines.Contains($vmName) -and (Test-VmRunning $s $f.FullName) -and (Test-TcpPort $m.machines[$vmName].ip 22)) {
                $r = Invoke-LabSsh $m.machines[$vmName].ip 'sudo subscription-manager identity >/dev/null 2>&1 && sudo subscription-manager unregister || echo nao-registrada'
                if ($r.ExitCode -eq 0) { Write-Ok "$vmName desregistrada da Red Hat ($(($r.Output | Select-Object -Last 1)))" }
                else { Write-Warn "$vmName não foi desregistrada: $($r.Output -join ' ') (remova em console.redhat.com)" }
            }
        }
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
    Remove-Item -Force (Get-ProvisionMarker $s) -ErrorAction SilentlyContinue
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
        $snap = if ((Test-Path $vmx) -and (Test-LabSnapshot $s $vmx)) { $script:SnapshotName } else { '-' }
        [pscustomobject]@{ VM = $vmName; IP = $spec.ip; Estado = $state; SSH = $ssh; Snapshot = $snap }
    }
    $rows | Format-Table -AutoSize
    $marker = Get-ProvisionMarker $s
    Write-Host ("Provisionado: {0}" -f $(if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { 'não' }))
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
    'provision' { Invoke-Provision }
    'stop'     { Invoke-Stop }
    'start'    { Invoke-Start }
    'snapshot' { Invoke-Snapshot }
    'reset'    { Invoke-Reset }
    'down'   { Invoke-Down }
    'status' { Invoke-Status }
    'ssh'    { Invoke-Ssh }
    default  { Get-Help $PSCommandPath -Detailed }
}
