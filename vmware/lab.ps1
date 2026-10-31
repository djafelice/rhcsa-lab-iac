#Requires -Version 7.2
<#
.SYNOPSIS
    Backend VMware Workstation do rhcsa-lab-iac (Windows).

.DESCRIPTION
    Comandos:
      check   Confere ferramentas, configuração, rede e tradução de IPs.
      image   Constrói a imagem golden RHEL 10 com o Packer (uma vez).
      help    Mostra esta ajuda.

    Próximas fases: up, down, snapshot, reset, status, ssh.

.EXAMPLE
    .\vmware\lab.ps1 check
.EXAMPLE
    .\vmware\lab.ps1 image
.EXAMPLE
    .\vmware\lab.ps1 image -Force
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'image', 'help')]
    [string]$Command = 'help',

    # image: reconstrói a golden mesmo se já existir.
    [switch]$Force
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
            if ($snaps -match '^base$') { Write-Ok "$vmx (snapshot 'base')" }
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

# ------------------------------------------------------------------- main ---
switch ($Command) {
    'check' { Invoke-Check }
    'image' { Invoke-Image }
    default { Get-Help $PSCommandPath -Detailed }
}
