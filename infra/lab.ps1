#Requires -Version 7.2
<#
.SYNOPSIS
    Backends nativos do rhcsa-lab-iac: as 3 VMs do lab direto no hypervisor
    do host (VMware, Hyper-V, VirtualBox), sem virtualização aninhada.

.DESCRIPTION
    O hypervisor é escolhido em infra/settings.psd1 (Provider = ...).

    Comandos:
      check      Confere ferramentas, configuração, rede e tradução de IPs.
      image      Constrói a imagem golden RHEL 10 com o Packer (uma vez).
      up         Cria (clones da golden), liga, provisiona e tira o snapshot
                 'pronto'. Lab já provisionado: só liga. -NoProvision: só a
                 infraestrutura.
      provision  Roda (de novo) o Ansible e refaz o snapshot 'pronto'.
      stop       Desliga as 3 VMs, sem perder nada.
      start      Liga as 3 VMs do ponto em que pararam.
      snapshot   (Re)tira o snapshot 'pronto' do estado atual.
      reset      Volta as 3 VMs ao snapshot 'pronto' (descarta mudanças).
      down       Desregistra da Red Hat e apaga as 3 VMs (golden intacta).
      status     Estado das VMs, snapshot e provisionamento.
      ssh        SSH como student: lab.ps1 ssh servera
      help       Esta ajuda.

    Rode numa sessão NORMAL (sem administrador). Só o setup-host.ps1 exige
    administrador.

.EXAMPLE
    ./infra/lab.ps1 check
.EXAMPLE
    ./infra/lab.ps1 up -Gui
.EXAMPLE
    ./infra/lab.ps1 ssh workstation
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'image', 'up', 'provision', 'stop', 'start', 'snapshot', 'reset', 'down', 'status', 'ssh', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Name,

    # image: reconstrói a golden. down/reset: sem confirmação.
    [switch]$Force,
    # up/start: liga as VMs com janela no hypervisor.
    [switch]$Gui,
    # up: só a infraestrutura, sem Ansible.
    [switch]$NoProvision
)

. "$PSScriptRoot/lib/LabCommon.ps1"

$script:SnapshotName = 'pronto'
$script:Settings = $null
$script:SettingsError = $null
try { $script:Settings = Get-LabSettings } catch { $script:SettingsError = $_.Exception.Message }
if ($script:Settings) { . (Get-ProviderScript $script:Settings) }

function Get-S {
    if (-not $script:Settings) { throw $script:SettingsError }
    return $script:Settings
}

function Get-ProvisionMarker([hashtable]$Settings) { Join-Path $Settings.LabDir '.provisionado' }

# --------------------------------------------------------------- helpers ---
function Get-LabVms([hashtable]$Settings, $Machines, [switch]$RequireAll) {
    $list = foreach ($vmName in $Machines.machines.Keys) {
        if (Test-ProviderVmExists $Settings $vmName) {
            [pscustomobject]@{ Name = $vmName; Ep = (Get-LabEndpoint $Settings $Machines $vmName) }
        } elseif ($RequireAll) { throw "$vmName não existe. Rode: ./infra/lab.ps1 up" }
    }
    # Vírgula: devolve o array inteiro (sem desenrolar), com .Count confiável.
    return , ([object[]]@($list))
}

function Start-LabVms([hashtable]$Settings, $Vms) {
    foreach ($v in $Vms) {
        if (Test-ProviderVmRunning $Settings $v.Name) { Write-Ok "$($v.Name) já está ligada"; continue }
        Start-ProviderVm $Settings $v.Name ([bool]$Gui)
        Write-Ok "$($v.Name) ligada"
    }
    Write-Step 'Aguardando SSH'
    foreach ($v in $Vms) { Wait-LabSsh $v.Name $v.Ep; Write-Ok "$($v.Name) ($($v.Ep.Host):$($v.Ep.Port)) responde SSH" }
}

function Stop-LabVms([hashtable]$Settings, $Vms, [switch]$Hard) {
    foreach ($v in $Vms) {
        if (-not (Test-ProviderVmRunning $Settings $v.Name)) { Write-Ok "$($v.Name) já está desligada"; continue }
        Stop-ProviderVm $Settings $v.Name ([bool]$Hard)
        Write-Ok "$($v.Name) desligada"
    }
}

# ------------------------------------------------------------------ check ---
function Invoke-Check {
    $paths = Get-LabPaths
    $script:problems = 0
    function Fail([string]$Msg) { Write-Fail $Msg; $script:problems++ }

    Write-Step 'Ferramentas'
    if ($PSVersionTable.PSVersion -ge [version]'7.2') { Write-Ok "PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.OS))" }
    else { Fail "PowerShell $($PSVersionTable.PSVersion) (precisa 7.2+)" }
    foreach ($cmd in 'git', 'packer', 'ssh', 'scp', 'ssh-keygen', 'tar') {
        $c = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($c) { Write-Ok "$cmd ($($c.Source))" } else { Fail "$cmd não está no PATH" }
    }
    try { Write-Ok "openssl ($(Get-OpenSsl))" } catch { Fail $_.Exception.Message }
    try { Import-LabYaml; Write-Ok "powershell-yaml ($((Get-Module powershell-yaml).ModuleBase))" } catch { Fail $_.Exception.Message }

    $crlf = Get-ChildItem -Path (Join-Path $paths.Repo 'labs'), (Join-Path $paths.Repo 'ansible'), (Join-Path $paths.Repo 'kickstart'), (Join-Path $paths.Repo 'image'), $paths.Provision `
        -Recurse -File -Include *.sh, *.py, *.yml, *.yaml, *.j2, *.tpl, *.json, *.txt -ErrorAction SilentlyContinue |
        Where-Object { [System.IO.File]::ReadAllText($_.FullName).Contains("`r`n") }
    if ($crlf) { Fail "arquivos com CRLF (rode 'git add --renormalize .'): $(($crlf | Select-Object -First 5).FullName -join ', ')" }
    else { Write-Ok 'scripts do lab com LF' }

    Write-Step 'Configuração (infra/settings.psd1)'
    $s = $script:Settings
    if (-not $s) { Fail $script:SettingsError }
    else {
        Write-Ok "provider: $($s.Provider) ($script:ProviderLabel)"
        if (Test-Path -LiteralPath $s.IsoPath -PathType Leaf) { Write-Ok "ISO ($($s.IsoPath))" } else { Fail "ISO não encontrada: $($s.IsoPath)" }
        if ($s.IsoChecksum -eq 'none') { Write-Warn 'IsoChecksum = none (integridade da ISO não verificada)' }
        if ([string]::IsNullOrWhiteSpace($s.RhsmOrgId) -or [string]::IsNullOrWhiteSpace($s.RhsmActivationKey)) {
            Fail 'RhsmOrgId/RhsmActivationKey vazios (o provisionamento registra as VMs na Red Hat)'
        } else { Write-Ok 'subscription Red Hat configurada' }
    }

    $m = $null
    Write-Step 'Rede do lab e tradução de IPs'
    try {
        $ipMap = Get-IpMap
        if ($ipMap.Identity) { Write-Ok 'sem infra/ip-map.yaml: rede original 192.168.56.0/24, sem tradução' }
        else {
            Write-Ok "$($ipMap.FromCidr) -> $($ipMap.ToCidr), $($ipMap.Map.Count) endereços"
            $touched = 0
            Get-ChildItem -Path $paths.Repo -Recurse -File |
                # infra/ e terraform/ ficam fora: só o resto do repositório vai para as VMs.
                Where-Object { $_.FullName.Substring($paths.Repo.Length) -notmatch '^[\\/](\.git|infra|terraform)[\\/]' -and $_.Length -lt 5MB -and
                               $_.Extension -notin '.png', '.jpg', '.iso', '.vmdk', '.vhdx', '.vdi', '.qcow2', '.gif', '.ico' } |
                ForEach-Object {
                    $text = [System.IO.File]::ReadAllText($_.FullName)
                    if ($text.Contains($ipMap.FromPrefix + '.')) {
                        [void](Convert-LabText -Text $text -IpMap $ipMap -Source $_.FullName.Substring($paths.Repo.Length + 1))
                        $touched++
                    }
                }
            Write-Ok "todos os IPs do projeto têm tradução ($touched arquivos)"
        }
    } catch { Fail $_.Exception.Message }
    # Separado do bloco acima: um IP sem tradução num arquivo qualquer não
    # pode impedir as verificações do provider e da golden.
    try {
        $m = Get-LabMachines
        foreach ($n in $m.machines.Keys) { Write-Ok ("{0,-12} {1}" -f $n, $m.machines[$n].ip) }
    } catch { Fail $_.Exception.Message }

    if ($s -and $m) {
        Write-Step "Provider: $script:ProviderLabel"
        foreach ($item in @(Test-ProviderEnvironment $s $m)) {
            switch ($item.Level) { 'ok' { Write-Ok $item.Message } 'warn' { Write-Warn $item.Message } default { Fail $item.Message } }
        }
        Write-Step 'Imagem golden'
        if (Test-ProviderGolden $s $m) { Write-Ok (Get-ProviderGoldenLabel $s $m) }
        else { Write-Warn 'golden ainda não construída (rode: ./infra/lab.ps1 image)' }
    }

    Write-Host ''
    if ($script:problems -eq 0) { Write-Host 'Tudo certo.' -ForegroundColor Green; return }
    Write-Host "$script:problems problema(s) encontrado(s)." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------------ image ---
function Invoke-Image {
    $s = Get-S
    $m = Get-LabMachines
    if ((Test-ProviderGolden $s $m) -and -not $Force) {
        Write-Host "A imagem golden já existe: $(Get-ProviderGoldenLabel $s $m)"
        Write-Host 'Use -Force para reconstruir (só depois do down: as VMs do lab dependem dela).'
        return
    }
    if ((Get-LabVms $s $m).Count -gt 0) { throw 'Há VMs do lab criadas a partir da golden. Rode ./infra/lab.ps1 down antes.' }
    if (-not (Test-Path -LiteralPath $s.IsoPath -PathType Leaf)) { throw "ISO não encontrada: $($s.IsoPath)" }

    Initialize-StudentKey | Out-Null
    Write-Step 'Renderizando o kickstart (kickstart/ks.cfg.tpl + adaptações do backend nativo)'
    Write-Ok (New-LabKickstart -Settings $s -StudentUser $m.student.username -ExtraPackages (Get-ProviderKickstartPackages))
    Build-ProviderGolden $s $m
    Write-Host ''
    Write-Host 'Imagem golden pronta. Não ligue esta VM: ela é só a base dos clones.' -ForegroundColor Green
}

# --------------------------------------------------------------------- up ---
function Invoke-Up {
    $s = Get-S
    $m = Get-LabMachines
    if (-not (Test-ProviderGolden $s $m)) { throw 'A imagem golden não existe. Rode: ./infra/lab.ps1 image' }
    if (-not $NoProvision -and -not (Test-Path -LiteralPath $s.IsoPath -PathType Leaf)) {
        throw "ISO não encontrada em '$($s.IsoPath)' (o provisionamento precisa dela). Ajuste IsoPath."
    }
    Initialize-StudentKey | Out-Null
    $marker = Get-ProvisionMarker $s
    $created = $false
    New-Item -ItemType Directory -Force -Path $s.LabDir | Out-Null

    foreach ($vmName in $m.machines.Keys) {
        $spec = $m.machines[$vmName]
        if (Test-ProviderVmExists $s $vmName) {
            Write-Step "$vmName já existe"
        } else {
            Write-Step "Criando $vmName (clone da golden '$($m.image)')"
            New-ProviderVm $s $m $vmName $spec ($vmName -eq $m.classroom.host)
            Write-Ok ("{0,-12} {1} vCPU, {2} MiB, {3} NIC(s), IP {4}" -f $vmName, $spec.cpus, $spec.memory_mb, @($spec.nics).Count, $spec.ip)
            $created = $true
        }
    }
    # VM nova = lab ainda não provisionado, mesmo que sobre um marcador antigo.
    if ($created) { Remove-Item -Force $marker -ErrorAction SilentlyContinue }

    $vms = Get-LabVms $s $m -RequireAll
    Write-Step 'Ligando'
    Start-LabVms $s $vms

    Write-Step 'Conferindo NICs e discos dentro das VMs'
    $problems = 0
    foreach ($v in $vms) {
        $spec = $m.machines[$v.Name]
        # Sem aspas duplas no comando remoto (passariam por duas camadas de escape).
        $r = Invoke-LabSsh $v.Ep "ip -br link | awk '{print `$3}'; echo ---; lsblk -dnbo SIZE,TYPE | awk '`$2 ~ /disk/ {print `$1}'"
        if ($r.ExitCode -ne 0) { Write-Fail "$($v.Name): falha ao consultar NICs/discos: $($r.Output -join ' ')"; $problems++; continue }
        $parts = @(($r.Output -join "`n") -split '---') + @('', '')
        $macs  = @($parts[0] -split '\s+' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
        $sizes = @($parts[1] -split '\s+' | Where-Object { $_ })
        foreach ($nic in $spec.nics) {
            $mac = ([string]$nic.mac).ToLower()
            if ($macs -contains $mac) { Write-Ok "$($v.Name) NIC $mac ($($nic.name))" }
            else { Write-Fail "$($v.Name) sem NIC com MAC $mac"; $problems++ }
        }
        if ($spec.Contains('extra_disks')) {
            foreach ($d in $spec.extra_disks) {
                $bytes = [string]([int64]$d.size_gb * 1GB)
                if ($sizes -contains $bytes) { Write-Ok "$($v.Name) disco de $($d.size_gb) GiB" }
                else { Write-Fail "$($v.Name) sem disco de $($d.size_gb) GiB ($bytes bytes)"; $problems++ }
            }
        }
    }
    Write-Host ''
    if ($problems -gt 0) { Write-Host "$problems problema(s) na conferência." -ForegroundColor Red; exit 1 }
    Write-Host 'Infraestrutura do lab no ar.' -ForegroundColor Green

    if ($NoProvision) { Write-Host 'Provisionamento pulado (-NoProvision). Quando quiser: ./infra/lab.ps1 provision'; return }
    if (Test-Path $marker) {
        Write-Host "Lab já provisionado em $((Get-Content $marker -Raw).Trim()); só liguei as VMs."
        Write-Host '  Estado limpo: ./infra/lab.ps1 reset    |    Ansible de novo: ./infra/lab.ps1 provision'
        return
    }
    Invoke-Provision
}

# -------------------------------------------------------------- provision ---
# Dispara uma fase do provision/run.sh na controladora via systemd-run
# (sobrevive a quedas do SSH) e acompanha o log por polling.
function Invoke-RemotePhase($Ep, [string]$Phase, [int]$TimeoutMin) {
    $log = "/var/log/rhcsa-lab-provision-$Phase.log"
    $rc  = "/var/log/rhcsa-lab-provision-$Phase.rc"
    $r = Invoke-LabSsh $Ep "sudo rm -f $log $rc; sudo systemd-run --quiet --unit=rhcsa-lab-provision-$Phase --collect -p StandardOutput=append:$log -p StandardError=append:$log /bin/bash /root/rhcsa-provision/run.sh $Phase"
    if ($r.ExitCode -ne 0) { throw "Não consegui iniciar a fase '$Phase': $($r.Output -join ' ')" }

    $next = 1
    $warned = $false
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ($true) {
        Start-Sleep -Seconds 5
        $cmd = 'n=$(sudo cat {0} 2>/dev/null | wc -l); n=${{n:-0}}; [ $n -ge {2} ] && sudo sed -n {2},${{n}}p {0}; echo __N__$n; sudo cat {1} 2>/dev/null' -f $log, $rc, $next
        $p = Invoke-LabSsh $Ep $cmd
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
    $s = Get-S
    $m = Get-LabMachines
    $paths = Get-LabPaths
    if ([string]::IsNullOrWhiteSpace($s.RhsmOrgId) -or [string]::IsNullOrWhiteSpace($s.RhsmActivationKey)) {
        throw 'Preencha RhsmOrgId e RhsmActivationKey em infra/settings.psd1.'
    }
    if (-not (Test-Path -LiteralPath $s.IsoPath -PathType Leaf)) {
        throw "ISO não encontrada em '$($s.IsoPath)'. Ajuste IsoPath em infra/settings.psd1."
    }
    $ctl = [string]$m.classroom.host
    $ep = Get-LabEndpoint $s $m $ctl
    $key = Initialize-StudentKey

    Write-Step 'Conferindo as VMs'
    $vms = Get-LabVms $s $m -RequireAll
    foreach ($v in $vms) {
        if (-not (Test-ProviderVmRunning $s $v.Name)) { throw "$($v.Name) está desligada. Rode: ./infra/lab.ps1 start" }
        Wait-LabSsh $v.Name $v.Ep 120
    }
    Write-Ok 'as 3 VMs respondem SSH'

    # Confere a mídia DENTRO da VM; sem mídia, reconecta a ISO e religa.
    $hasMedia = { (Invoke-LabSsh $ep 'sudo blkid -o value -s LABEL /dev/sr0').ExitCode -eq 0 }
    if (-not (& $hasMedia)) {
        Write-Step "Conectando a ISO ao CD da $ctl (desliga e religa a VM)"
        Stop-ProviderVm $s $ctl $false
        Set-ProviderVmIso $s $ctl $s.IsoPath
        Start-ProviderVm $s $ctl ([bool]$Gui)
        Wait-LabSsh $ctl $ep
        if (-not (& $hasMedia)) { throw "A $ctl continua sem mídia no CD. $(Get-ProviderIsoFailureReason $s $ctl)" }
    }
    Write-Ok "ISO no CD da ${ctl}: $((Invoke-LabSsh $ep 'sudo blkid -o value -s LABEL /dev/sr0').Output -join '')"

    Write-Step 'Montando a cópia do repositório (infra/.work/stage)'
    $stage = New-LabStage
    if ($stage.Translated -gt 0) { Write-Ok "$($stage.Translated) arquivos com IPs traduzidos para $((Get-IpMap).ToCidr)" }
    $inv = New-LabInventory $m '/root/rhcsa-provision/student_key'
    New-Item -ItemType Directory -Force -Path (Join-Path $stage.Path 'output') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $stage.Path 'output/inventory.yml'), $inv, [System.Text.UTF8Encoding]::new($false))
    $execList = Join-Path $paths.Stage 'executables.txt'
    [System.IO.File]::WriteAllText($execList, (($stage.Executables -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    $tgz = Join-Path $paths.Stage 'repo.tgz'
    & tar -czf $tgz -C $paths.Stage repo
    if ($LASTEXITCODE -ne 0) { throw 'tar falhou ao empacotar a cópia do repositório.' }
    Write-Ok "$([math]::Round((Get-Item $tgz).Length / 1MB, 1)) MB empacotados"

    Write-Step "Enviando para a $ctl (controladora temporária do Ansible)"
    $up = '/tmp/rhcsa-provision-upload'
    if ((Invoke-LabSsh $ep "rm -rf $up && mkdir -m 700 $up").ExitCode -ne 0) { throw "Falha ao preparar $up na $ctl." }
    Send-LabFiles $ep @($tgz, $key, (Join-Path $paths.Provision 'run.sh'), $execList) $up
    $r = Invoke-LabSsh $ep "sudo bash $up/run.sh unpack"
    if ($r.ExitCode -ne 0) { throw "Falha ao instalar os arquivos na ${ctl}: $($r.Output -join ' ')" }
    Write-Ok ($r.Output -join ' ')
    # Segredos pelo stdin do ssh (nunca no disco do host). O pwsh termina o
    # pipe com CRLF no Windows: o tr remove o \r.
    $sshArgs = Get-LabSshArgs -Port $ep.Port
    (New-LabEnvFile $s) | & ssh @sshArgs "student@$($ep.Host)" 'tr -d ''\r'' | sudo install -m 600 /dev/stdin /root/rhcsa-provision/lab.env'
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao gravar as variáveis da subscription na controladora.' }
    Write-Ok 'repositório, chave e variáveis em /root/rhcsa-provision'

    $hadEns18 = (Invoke-LabSsh $ep 'ip -br link show ens18').ExitCode -eq 0
    Write-Step "Preparando a controladora (ansible-core da ISO, collections, rede da $ctl)"
    Invoke-RemotePhase $ep 'prepare' 20
    if (-not $hadEns18) {
        Write-Step "Reiniciando a $ctl para aplicar ens18"
        Invoke-LabSsh $ep 'sudo systemctl reboot' | Out-Null
        Start-Sleep -Seconds 15
        Wait-LabSsh $ctl $ep
        if ((Invoke-LabSsh $ep 'ip -br link show ens18').ExitCode -ne 0) { throw "A $ctl voltou sem a interface ens18." }
        Write-Ok "$ctl com ens18"
    }

    Write-Step 'Rodando ansible/site.yml (registro, pacotes, classroom, exercícios, dashboard: 15-30 min)'
    Invoke-RemotePhase $ep 'site' 120

    Write-Step 'Guardando os logs em infra/.work/logs e limpando a controladora'
    New-Item -ItemType Directory -Force -Path $paths.Logs | Out-Null
    Receive-LabFiles $ep '/var/log/rhcsa-lab-provision-*.log' $paths.Logs
    $r = Invoke-LabSsh $ep 'sudo bash /root/rhcsa-provision/run.sh cleanup; sudo rm -f /var/log/rhcsa-lab-provision-*'
    if ($r.ExitCode -ne 0) { Write-Warn "limpeza incompleta: $($r.Output -join ' ')" } else { Write-Ok 'ansible-core, chave e segredos removidos da controladora' }
    Remove-Item -Recurse -Force $paths.Stage -ErrorAction SilentlyContinue

    Write-Step 'Resultado'
    foreach ($v in $vms) { Write-Ok ("{0,-12} {1}" -f $v.Name, ((Invoke-LabSsh $v.Ep 'hostname').Output -join '')) }
    Set-Content -Path (Get-ProvisionMarker $s) -Value (Get-Date -Format 'yyyy-MM-dd HH:mm') -Encoding utf8NoBOM

    Invoke-Snapshot -Quiet
    Write-Host ''
    Write-Host "Lab provisionado, com snapshot '$($script:SnapshotName)' para o reset." -ForegroundColor Green
    Write-Host "  Dashboard: $(Get-ProviderDashboardUrl $s $m)"
    Write-Host '  Estudar:   ./infra/lab.ps1 ssh workstation   e depois:  lab list'
}

# ------------------------------------------------- ciclo de vida do lab ---
function Invoke-Stop {
    $s = Get-S
    $vms = Get-LabVms $s (Get-LabMachines)
    if ($vms.Count -eq 0) { Write-Host 'Nenhuma VM do lab criada.'; return }
    Write-Step 'Desligando o lab (nada é perdido)'
    Stop-LabVms $s $vms
    Write-Host 'Lab desligado. Para continuar: ./infra/lab.ps1 start' -ForegroundColor Green
}

function Invoke-Start {
    $s = Get-S
    $vms = Get-LabVms $s (Get-LabMachines) -RequireAll
    Write-Step 'Ligando o lab'
    Start-LabVms $s $vms
    Write-Host 'Lab no ar: ./infra/lab.ps1 ssh workstation' -ForegroundColor Green
}

# Snapshot com as VMs DESLIGADAS: consistente, sem memória e sem relógio
# congelado no passado após o reset.
function Invoke-Snapshot([switch]$Quiet) {
    $s = Get-S
    $m = Get-LabMachines
    $vms = Get-LabVms $s $m -RequireAll
    Write-Step "Snapshot '$($script:SnapshotName)' das 3 VMs (desliga, fotografa e religa)"
    Stop-LabVms $s $vms
    foreach ($v in $vms) {
        # Estado salvo sem ISO no CD, como no homelab (o provision reconecta).
        if ($v.Name -eq $m.classroom.host) { Set-ProviderVmIso $s $v.Name '' }
        New-ProviderSnapshot $s $v.Name $script:SnapshotName
        Write-Ok "$($v.Name): snapshot '$($script:SnapshotName)'"
    }
    Start-LabVms $s $vms
    if (-not $Quiet) { Write-Host 'Snapshot salvo. ./infra/lab.ps1 reset volta a este ponto.' -ForegroundColor Green }
}

function Invoke-Reset {
    $s = Get-S
    $vms = Get-LabVms $s (Get-LabMachines) -RequireAll
    foreach ($v in $vms) {
        if (-not (Test-ProviderSnapshot $s $v.Name $script:SnapshotName)) {
            throw "$($v.Name) não tem o snapshot '$($script:SnapshotName)'. Rode: ./infra/lab.ps1 snapshot"
        }
    }
    if (-not $Force) {
        Write-Host "Reset: as 3 VMs voltam ao snapshot '$($script:SnapshotName)'. Tudo feito depois dele é"
        Write-Host 'DESCARTADO, inclusive o histórico do dashboard e exercícios em andamento.'
        if ((Read-Host 'Confirma? Digite "sim"') -ne 'sim') { Write-Host 'Cancelado.'; return }
    }
    Write-Step 'Desligando (o estado atual será descartado)'
    Stop-LabVms $s $vms -Hard
    Write-Step "Voltando ao snapshot '$($script:SnapshotName)'"
    foreach ($v in $vms) { Restore-ProviderSnapshot $s $v.Name $script:SnapshotName; Write-Ok $v.Name }
    Write-Step 'Ligando'
    Start-LabVms $s $vms
    Write-Host 'Lab de volta ao estado limpo.' -ForegroundColor Green
}

function Invoke-Down {
    $s = Get-S
    $m = Get-LabMachines
    $vms = Get-LabVms $s $m
    if ($vms.Count -eq 0) { Write-Host 'Nenhuma VM do lab criada.' }
    else {
        Write-Host "VMs que serão APAGADAS: $($vms.Name -join ', ')"
        if (-not $Force -and (Read-Host 'Confirma? Digite "sim"') -ne 'sim') { Write-Host 'Cancelado.'; return }
        # Desregistra da Red Hat antes de apagar (senão sobram sistemas órfãos na conta).
        foreach ($v in $vms) {
            if ((Test-ProviderVmRunning $s $v.Name) -and (Test-TcpPort $v.Ep.Host $v.Ep.Port)) {
                $r = Invoke-LabSsh $v.Ep 'sudo subscription-manager identity >/dev/null 2>&1 && sudo subscription-manager unregister || echo nao-registrada'
                if ($r.ExitCode -eq 0) { Write-Ok "$($v.Name) desregistrada ($(($r.Output | Select-Object -Last 1)))" }
                else { Write-Warn "$($v.Name) não foi desregistrada (remova em console.redhat.com > Inventory)" }
            } else { Write-Warn "$($v.Name) desligada: não deu para desregistrar (confira console.redhat.com > Inventory)" }
        }
        foreach ($v in $vms) {
            Write-Step "Apagando $($v.Name)"
            if (Test-ProviderVmRunning $s $v.Name) { Stop-ProviderVm $s $v.Name $true }
            Remove-ProviderVm $s $v.Name
            Write-Ok $v.Name
        }
    }
    Remove-Item -Force (Get-LabPaths).KnownHosts -ErrorAction SilentlyContinue
    Remove-Item -Force (Get-ProvisionMarker $s) -ErrorAction SilentlyContinue
    Write-Host 'Lab removido. A imagem golden continua intacta.' -ForegroundColor Green
}

function Invoke-Status {
    $s = Get-S
    $m = Get-LabMachines
    $rows = foreach ($vmName in $m.machines.Keys) {
        $ep = Get-LabEndpoint $s $m $vmName
        $exists = Test-ProviderVmExists $s $vmName
        $state = if (-not $exists) { 'não criada' } elseif (Test-ProviderVmRunning $s $vmName) { 'ligada' } else { 'desligada' }
        $ssh = if ($state -eq 'ligada' -and (Test-TcpPort $ep.Host $ep.Port)) { 'ok' } else { '-' }
        $snap = if ($exists -and (Test-ProviderSnapshot $s $vmName $script:SnapshotName)) { $script:SnapshotName } else { '-' }
        [pscustomobject]@{ VM = $vmName; IP = $m.machines[$vmName].ip; SSH = "$($ep.Host):$($ep.Port)"; Estado = $state; 'SSH ok' = $ssh; Snapshot = $snap }
    }
    $rows | Format-Table -AutoSize
    $marker = Get-ProvisionMarker $s
    Write-Host ("Provider:     {0}" -f $script:ProviderLabel)
    Write-Host ("Provisionado: {0}" -f $(if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { 'não' }))
    Write-Host ("Golden:       {0}" -f $(if (Test-ProviderGolden $s $m) { Get-ProviderGoldenLabel $s $m } else { 'não construída' }))
    Write-Host ("Dashboard:    {0}" -f (Get-ProviderDashboardUrl $s $m))
}

function Invoke-Ssh {
    $s = Get-S
    $m = Get-LabMachines
    if (-not $Name -or -not $m.machines.Contains($Name)) { throw "Informe a VM: ./infra/lab.ps1 ssh <$(@($m.machines.Keys) -join '|')>" }
    $ep = Get-LabEndpoint $s $m $Name
    $sshArgs = Get-LabSshArgs -Port $ep.Port -Interactive
    & ssh @sshArgs "student@$($ep.Host)"
}

# ------------------------------------------------------------------- main ---
switch ($Command) {
    'check'     { Invoke-Check }
    'image'     { Invoke-Image }
    'up'        { Invoke-Up }
    'provision' { Invoke-Provision }
    'stop'      { Invoke-Stop }
    'start'     { Invoke-Start }
    'snapshot'  { Invoke-Snapshot }
    'reset'     { Invoke-Reset }
    'down'      { Invoke-Down }
    'status'    { Invoke-Status }
    'ssh'       { Invoke-Ssh }
    default     { Get-Help $PSCommandPath -Detailed }
}