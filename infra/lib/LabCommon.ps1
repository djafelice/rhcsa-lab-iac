# Núcleo comum dos backends nativos (sem virtualização aninhada).
#
# Tudo aqui independe do hypervisor: configuração, tradução de IPs,
# kickstart, SSH, cópia do repositório para a controladora, inventário.
# O que fala com o hypervisor fica em providers/<provider>.ps1, que
# implementa o contrato descrito em providers/README.md.
#
# Requisitos: PowerShell 7.2+ (Windows ou Linux), módulo powershell-yaml.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Saída do ssh (UTF-8) com acentos corretos no terminal.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# --------------------------------------------------------------- caminhos ---
$script:InfraDir = Split-Path -Parent $PSScriptRoot
$script:RepoRoot  = Split-Path -Parent $script:InfraDir
$script:WorkDir   = Join-Path $script:InfraDir '.work'

function Get-LabPaths {
    [ordered]@{
        Repo       = $script:RepoRoot
        Infra      = $script:InfraDir
        Work       = $script:WorkDir
        Http       = Join-Path $script:WorkDir 'http'
        StudentKey = Join-Path $script:WorkDir 'student_key'
        KnownHosts = Join-Path $script:WorkDir 'known_hosts'
        Settings   = Join-Path $script:InfraDir 'settings.psd1'
        IpMap      = Join-Path $script:InfraDir 'ip-map.yaml'
        Machines   = Join-Path $script:RepoRoot 'machines.yaml'
        Kickstart  = Join-Path $script:RepoRoot 'kickstart/ks.cfg.tpl'
        Finalize   = Join-Path $script:RepoRoot 'image/finalize.sh'
        Packer     = Join-Path $script:InfraDir 'packer'
        Providers  = Join-Path $script:InfraDir 'providers'
        Provision  = Join-Path $script:InfraDir 'provision'
        Stage      = Join-Path $script:WorkDir 'stage'
        Logs       = Join-Path $script:WorkDir 'logs'
    }
}

$script:IsWindowsHost = $IsWindows

# --------------------------------------------------------------- mensagens ---
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  OK    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  AVISO $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  ERRO  $Message" -ForegroundColor Red }

# Item de verificação devolvido pelos providers ao `check`.
function New-CheckItem([string]$Level, [string]$Message) {
    [pscustomobject]@{ Level = $Level; Message = $Message }   # Level: ok | warn | fail
}

# ------------------------------------------------------------ configuração ---
# Providers: seção específica em settings.psd1, sistemas de host já
# implementados (Hosts) e planejados (Planned). Linux + KVM não está aqui:
# é o backend original do projeto (make deploy, Terraform + libvirt).
$script:Providers = [ordered]@{
    vmware     = @{ Section = 'VMware';     Hosts = @('Windows'); Planned = @('Linux'); Label = 'VMware Workstation' }
    hyperv     = @{ Section = 'HyperV';     Hosts = @('Windows'); Planned = @();        Label = 'Hyper-V' }
    virtualbox = @{ Section = 'VirtualBox'; Hosts = @('Windows'); Planned = @('Linux'); Label = 'VirtualBox' }
}

function Get-HostOs {
    if ($IsWindows) { return 'Windows' }
    if ($IsLinux) { return 'Linux' }
    return 'macOS'
}

# Falha cedo, com orientação, se o provider não combina com o host.
function Assert-ProviderHost([string]$Provider) {
    $hostOs = Get-HostOs
    if ($hostOs -eq 'macOS') { throw 'Host macOS não é suportado pelo projeto (hosts físicos suportados: Linux e Windows).' }
    $p = $script:Providers[$Provider]
    if ($p.Hosts -contains $hostOs) { return }
    if ($p.Planned -contains $hostOs) { throw "Provider '$Provider' em $hostOs ainda está em desenvolvimento." }
    $ok = @($script:Providers.Keys | Where-Object { $script:Providers[$_].Hosts -contains $hostOs })
    $hint = if ($hostOs -eq 'Linux') { ' Com KVM, use o backend original: make deploy (docs/how-to/deploy-linux.md).' } else { '' }
    throw "Provider '$Provider' não roda em $hostOs. Neste host: $($(if ($ok) { $ok -join ', ' } else { 'nenhum provider nativo ainda' })).$hint"
}

function Get-LabSettings {
    $paths = Get-LabPaths
    if (-not (Test-Path $paths.Settings)) {
        throw "Não encontrei $($paths.Settings). Copie infra/settings.example.psd1 para infra/settings.psd1 e ajuste."
    }
    $s = Import-PowerShellDataFile -Path $paths.Settings
    $required = 'Provider', 'IsoPath', 'IsoChecksum', 'VmRoot', 'HostIp', 'PackerHttpPort',
                'PackerHeadless', 'BootMenu', 'StudentPassword'
    $missing = $required | Where-Object { -not $s.ContainsKey($_) }
    if ($missing) { throw "Faltam chaves em settings.psd1: $($missing -join ', ')" }
    if (-not $script:Providers.Contains($s.Provider)) {
        throw "Provider '$($s.Provider)' desconhecido. Use: $($script:Providers.Keys -join ', ')."
    }
    Assert-ProviderHost $s.Provider
    if ($s.StudentPassword -eq 'troque-esta-senha' -or [string]::IsNullOrWhiteSpace($s.StudentPassword)) {
        throw 'Defina StudentPassword em infra/settings.psd1 (não use o valor de exemplo).'
    }
    if ($s.BootMenu -notin 'grub', 'isolinux') { throw "BootMenu deve ser 'grub' ou 'isolinux'." }

    $defaults = @{
        RhsmOrgId         = ''
        RhsmActivationKey = ''
        RootPassword      = ''
        FlatpakMirror     = $true
        RecordingEnabled  = $false
    }
    foreach ($k in $defaults.Keys) { if (-not $s.ContainsKey($k)) { $s[$k] = $defaults[$k] } }

    # Seção do provider (ex.: VMware = @{...}); vazia se ausente.
    $section = $script:Providers[$s.Provider].Section
    $s.P = if ($s.ContainsKey($section)) { $s[$section] } else { @{} }

    $s.GoldenDir = Join-Path $s.VmRoot 'golden'
    $s.LabDir    = Join-Path $s.VmRoot 'lab'
    return $s
}

function Get-ProviderScript([hashtable]$Settings) {
    $p = Join-Path (Get-LabPaths).Providers "$($Settings.Provider).ps1"
    if (-not (Test-Path $p)) { throw "Provider '$($Settings.Provider)' ainda não implementado ($p)." }
    return $p
}

# --------------------------------------------------------------- ferramentas ---
# openssl: hash SHA-512 crypt da senha do student (o mesmo "openssl passwd -6"
# do backend Linux). No Windows vem com o Git for Windows (usr\bin).
function Get-OpenSsl {
    $cmd = Get-Command openssl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($script:IsWindowsHost) {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $openssl = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'usr\bin\openssl.exe'
            if (Test-Path $openssl) { return $openssl }
        }
    }
    throw 'openssl não encontrado (no Windows vem com o Git for Windows; no Linux, instale o pacote openssl).'
}

# ------------------------------------------------------- powershell-yaml ---
# Carrega o módulo mesmo se o PSModulePath da sessão não incluir as pastas
# padrão de módulos do pwsh 7 (visto num perfil personalizado).
function Import-LabYaml {
    if (Get-Module powershell-yaml) { return }
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        $sep = [System.IO.Path]::PathSeparator
        $candidates = @(
            $(if ($script:IsWindowsHost) { Join-Path $env:ProgramFiles 'PowerShell\Modules' } else { '/usr/local/share/powershell/Modules' }),
            (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'),
            (Join-Path $HOME '.local/share/powershell/Modules')
        ) | Where-Object { (Test-Path $_) -and (($env:PSModulePath -split $sep) -notcontains $_) }
        foreach ($c in $candidates) { $env:PSModulePath = "$env:PSModulePath$sep$c" }
    }
    try { Import-Module powershell-yaml -ErrorAction Stop }
    catch { throw 'Módulo powershell-yaml não encontrado. Instale com: Install-PSResource powershell-yaml -Scope AllUsers -TrustRepository' }
}

# ----------------------------------------------------- tradução de IPs ---
# infra/ip-map.yaml é OPCIONAL e local (não versionado). Sem ele, o lab usa
# a rede original 192.168.56.0/24 sem tradução (caso de Hyper-V e
# VirtualBox, que criam uma rede dedicada). Com ele, todo 192.168.56.X do
# projeto é trocado pelo endereço da tabela (caso de uma rede NAT do VMware
# já usada por outras VMs). Ver infra/ip-map.example.yaml.
function Get-IpMap {
    $paths = Get-LabPaths
    if (-not (Test-Path $paths.IpMap)) {
        return [pscustomobject]@{ Identity = $true; FromPrefix = '192.168.56'; ToPrefix = '192.168.56'
                                  FromCidr = '192.168.56.0/24'; ToCidr = '192.168.56.0/24'; Map = @{} }
    }
    Import-LabYaml
    $raw = ConvertFrom-Yaml (Get-Content $paths.IpMap -Raw)
    $fromNet = ($raw.network.from -split '/')[0]
    $toNet   = ($raw.network.to -split '/')[0]
    $fromPrefix = $fromNet.Substring(0, $fromNet.LastIndexOf('.'))
    $toPrefix   = $toNet.Substring(0, $toNet.LastIndexOf('.'))
    $map = @{}
    foreach ($k in $raw.addresses.Keys) { $map[[string]$k] = [string]$raw.addresses[$k] }
    $map["$fromPrefix.0"] = "$toPrefix.0"
    [pscustomobject]@{
        Identity = $false; FromPrefix = $fromPrefix; ToPrefix = $toPrefix
        FromCidr = [string]$raw.network.from; ToCidr = [string]$raw.network.to; Map = $map
    }
}

# Troca cada IP da rede original pelo da tabela, casando o octeto inteiro
# (192.168.56.1 nunca casa dentro de 192.168.56.10). Endereço sem
# tradução = erro com a lista do que falta.
function Convert-LabText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$IpMap,
        [string]$Source = '(texto)'
    )
    if ($IpMap.Identity) { return $Text }
    $pattern = "(?<![\d.])$([regex]::Escape($IpMap.FromPrefix))\.(\d{1,3})(?![\d])"
    $unmapped = [System.Collections.Generic.HashSet[string]]::new()
    $result = [regex]::Replace($Text, $pattern, {
            param($m)
            if ($IpMap.Map.ContainsKey($m.Value)) { return $IpMap.Map[$m.Value] }
            [void]$unmapped.Add($m.Value)
            return $m.Value
        })
    if ($unmapped.Count -gt 0) {
        throw "Endereços sem tradução em infra/ip-map.yaml ($Source): $($unmapped -join ', ')"
    }
    return $result
}

# machines.yaml já traduzido. -Ordered: mantém a ordem das VMs e dos discos
# extra (que define sdb/sdc/... dentro das VMs).
function Get-LabMachines {
    $paths = Get-LabPaths
    Import-LabYaml
    $text = Convert-LabText -Text (Get-Content $paths.Machines -Raw) -IpMap (Get-IpMap) -Source 'machines.yaml'
    return ConvertFrom-Yaml $text -Ordered
}

# --------------------------------------------------------- chave do student ---
# Par ed25519 com que o Packer e o provisionamento entram nas VMs. A golden
# embute a pública: trocar a chave exige reconstruir a golden.
function Initialize-StudentKey {
    $paths = Get-LabPaths
    New-Item -ItemType Directory -Force -Path $paths.Work | Out-Null
    if (-not (Test-Path $paths.StudentKey)) {
        Write-Step 'Gerando par de chaves SSH do student (infra/.work/student_key)'
        # Linha de comando crua: garante -N "" (senha vazia) em qualquer pwsh.
        $kgArgs = "-q -t ed25519 -N `"`" -C rhcsa-lab-iac-student -f `"$($paths.StudentKey)`""
        $p = Start-Process -FilePath 'ssh-keygen' -ArgumentList $kgArgs -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "ssh-keygen falhou (código $($p.ExitCode))." }
    }
    # O ssh recusa chave privada legível por outros usuários.
    if ($script:IsWindowsHost) {
        & icacls.exe $paths.StudentKey /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'icacls falhou ao restringir a chave privada.' }
    } else {
        & chmod 600 $paths.StudentKey
    }
    return $paths.StudentKey
}

# ---------------------------------------------------------------- kickstart ---
function Get-PasswordHash([string]$Password) {
    $openssl = Get-OpenSsl
    $hash = $Password | & $openssl passwd -6 -stdin   # -stdin: fora da lista de processos
    if ($LASTEXITCODE -ne 0 -or -not ($hash -match '^\$6\$')) { throw 'Falha ao gerar o hash da senha com openssl.' }
    return ($hash | Select-Object -First 1).Trim()
}

# Renderiza kickstart/ks.cfg.tpl (o MESMO do backend Linux) com as
# adaptações dos backends nativos. Falha alto se o template do upstream
# mudar a ponto de a adaptação não se aplicar.
function New-LabKickstart([hashtable]$Settings, [string]$StudentUser, [string[]]$ExtraPackages = @()) {
    $paths = Get-LabPaths
    $tpl = (Get-Content $paths.Kickstart -Raw) -replace "`r`n", "`n"
    $pub = (Get-Content "$($paths.StudentKey).pub" -Raw).Trim()
    $hash = Get-PasswordHash $Settings.StudentPassword

    # .Replace() é literal: o hash tem "$" e não pode passar por regex.
    $ks = $tpl.Replace('${STUDENT_USER}', $StudentUser).
               Replace('${STUDENT_SSH_PUBKEY}', $pub).
               Replace('${STUDENT_PASSWORD_HASH}', $hash)

    # poweroff -> reboot: o Packer entra por SSH no 1o boot para rodar o
    # image/finalize.sh (no libvirt ele roda offline via virt-customize).
    $re = [regex]'(?m)^poweroff[ \t]*$'
    if (-not $re.IsMatch($ks)) { throw "Adaptação falhou: linha 'poweroff' não encontrada em kickstart/ks.cfg.tpl." }
    $ks = $re.Replace($ks, "# rhcsa-lab-iac (backend nativo): reboot no lugar de poweroff -- o Packer`n# entra por SSH no 1o boot para rodar image/finalize.sh.`nreboot", 1)

    # Pacotes de integração do hypervisor (open-vm-tools, hyperv-daemons...).
    if ($ExtraPackages.Count -gt 0) {
        $re = [regex]'(?m)^@\^minimal-environment[ \t]*$'
        if (-not $re.IsMatch($ks)) { throw "Adaptação falhou: '@^minimal-environment' não encontrado no %packages." }
        $ks = $re.Replace($ks, "@^minimal-environment`n# rhcsa-lab-iac (backend nativo): integração com o hypervisor.`n$($ExtraPackages -join "`n")", 1)
    }

    if ($ks -match '\$\{[A-Z_]+\}') { throw "Ainda há placeholders sem valor no kickstart: $($Matches[0])" }
    New-Item -ItemType Directory -Force -Path $paths.Http | Out-Null
    $out = Join-Path $paths.Http 'ks.cfg'
    [System.IO.File]::WriteAllText($out, $ks, [System.Text.UTF8Encoding]::new($false))
    return $out
}

# ------------------------------------------------------------------ SSH ---
# Endpoint = onde o host alcança o SSH de uma VM: o IP do lab na
# maioria dos providers; 127.0.0.1:<porta> quando a rede só é acessível por
# redirecionamento de portas (VirtualBox NAT Network).
function Get-LabEndpoint([hashtable]$Settings, $Machines, [string]$Name) {
    Get-ProviderEndpoint $Settings $Machines $Name
}

# known_hosts próprio do lab: as chaves de host mudam a cada `up` (o
# finalize.sh apaga as da golden) e o arquivo é descartado no `down`.
function Get-LabSshArgs([int]$Port = 22, [switch]$Scp, [switch]$Interactive) {
    $paths = Get-LabPaths
    $a = @('-i', $paths.StudentKey,
           '-o', 'StrictHostKeyChecking=accept-new',
           '-o', "UserKnownHostsFile=$($paths.KnownHosts)",
           '-o', 'ConnectTimeout=5',
           '-o', 'LogLevel=ERROR')
    if (-not $Interactive) { $a += @('-o', 'BatchMode=yes') }
    if ($Port -ne 22) { $a += @($(if ($Scp) { '-P' } else { '-p' }), [string]$Port) }
    return $a
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 2000) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try { return ($c.ConnectAsync($HostName, $Port).Wait($TimeoutMs) -and $c.Connected) }
    catch { return $false } finally { $c.Dispose() }
}

function Invoke-LabSsh($Endpoint, [string]$RemoteCommand, [string]$User = 'student') {
    $sshArgs = Get-LabSshArgs -Port $Endpoint.Port
    $out = & ssh @sshArgs "$User@$($Endpoint.Host)" $RemoteCommand 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($out) }
}

function Send-LabFiles($Endpoint, [string[]]$Files, [string]$RemoteDir, [string]$User = 'student') {
    $sshArgs = Get-LabSshArgs -Port $Endpoint.Port -Scp
    & scp -q @sshArgs @Files "$User@$($Endpoint.Host):$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { throw 'scp falhou ao enviar os arquivos.' }
}

function Receive-LabFiles($Endpoint, [string]$RemotePattern, [string]$LocalDir, [string]$User = 'student') {
    $sshArgs = Get-LabSshArgs -Port $Endpoint.Port -Scp
    & scp -q @sshArgs "$User@$($Endpoint.Host):$RemotePattern" $LocalDir 2>$null
}

function Wait-LabSsh([string]$Name, $Endpoint, [int]$TimeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort $Endpoint.Host $Endpoint.Port) {
            if ((Invoke-LabSsh $Endpoint 'true').ExitCode -eq 0) { return }
        }
        Start-Sleep -Seconds 3
    }
    throw "$Name ($($Endpoint.Host):$($Endpoint.Port)) não respondeu SSH em $TimeoutSec s. Abra o console da VM no hypervisor para ver o que aconteceu."
}

# ------------------------------------------------- cópia traduzida do repo ---
# Monta em .work/stage/repo a cópia que vai para a workstation: arquivos do
# Git (rastreados e novos não ignorados), com os IPs traduzidos. Binários
# copiados intactos. Devolve também os caminhos executáveis segundo o Git
# (o checkout no Windows não guarda o bit +x).
function New-LabStage {
    $paths = Get-LabPaths
    $ipMap = Get-IpMap
    $stageRepo = Join-Path $paths.Stage 'repo'
    if (Test-Path $paths.Stage) { Remove-Item -Recurse -Force $paths.Stage }
    New-Item -ItemType Directory -Force -Path $stageRepo | Out-Null

    $files = & git -C $paths.Repo ls-files --cached --others --exclude-standard
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files falhou.' }
    $exec = @(& git -C $paths.Repo ls-files -s | Where-Object { $_ -match '^100755 ' } | ForEach-Object { ($_ -split "`t", 2)[1] })

    $translated = 0
    foreach ($rel in $files) {
        if ($rel -match '^(infra|terraform)/') { continue }
        $src = Join-Path $paths.Repo $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $stageRepo $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        $bytes = [System.IO.File]::ReadAllBytes($src)
        if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { [System.IO.File]::WriteAllBytes($dst, $bytes); continue }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if (-not $ipMap.Identity -and $text.Contains($ipMap.FromPrefix + '.')) {
            $text = Convert-LabText -Text $text -IpMap $ipMap -Source $rel
            $translated++
        }
        [System.IO.File]::WriteAllText($dst, $text, [System.Text.UTF8Encoding]::new($false))
    }
    Copy-Item (Join-Path $paths.Provision 'infra-bootstrap-ws.yml') (Join-Path $stageRepo 'ansible/infra-bootstrap-ws.yml')
    [pscustomobject]@{ Path = $stageRepo; Translated = $translated; Executables = $exec }
}

# Inventário no mesmo formato do que o Terraform gera (terraform/main.tf),
# com caminhos da controladora (workstation) e IPs internos do lab.
function New-LabInventory($Machines, [string]$KeyPathOnController) {
    $spec = $Machines
    $ip = { param($n) $spec.machines[$n].ip }
    $hostsIp = ($spec.machines.Keys | ForEach-Object { "      ${_}: $(& $ip $_)" }) -join "`n"
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
# Gerado por infra/lab.ps1 provision. Mesmo formato do inventário do Terraform.
all:
  vars:
    ansible_user: $($spec.student.username)
    ansible_ssh_private_key_file: $KeyPathOnController
    lab_domain: $($spec.domain)
    lab_student_user: $($spec.student.username)
    lab_network_cidr: $($spec.network.cidr)
    lab_gateway_ip: $($spec.network.gateway)
    lab_hosts_ip:
$hostsIp
    classroom_host: $($spec.classroom.host)
    classroom_ip: $(& $ip $spec.classroom.host)
    classroom_port: $($spec.classroom.port)
    dashboard_host: $($spec.dashboard.host)
    dashboard_port: $($spec.dashboard.port)
    dashboard_allowed_source: $($spec.dashboard.allowed_source)
    workstation_ip: $(& $ip 'workstation')
    servera_ip: $(& $ip 'servera')
    serverb_ip: $(& $ip 'serverb')
  children:

"@)
    foreach ($n in $spec.machines.Keys) {
        [void]$sb.Append("    ${n}:`n      hosts:`n        ${n}:`n          ansible_host: $(& $ip $n)`n")
    }
    [void]$sb.Append("    lab_hosts:`n      children:`n")
    foreach ($n in $spec.machines.Keys) {
        if ($spec.machines[$n].role -eq 'server') { [void]$sb.Append("        ${n}: {}`n") }
    }
    return ($sb.ToString() -replace "`r`n", "`n")
}

# Variáveis lidas pelo Ansible (lookup env), como o .env do backend Linux.
function New-LabEnvFile([hashtable]$Settings) {
    function Q([string]$v) { "'" + ($v -replace "'", "'\''") + "'" }
    $flatpak   = ([string][bool]$Settings.FlatpakMirror).ToLower()
    $recording = ([string][bool]$Settings.RecordingEnabled).ToLower()
    $lines = @(
        "export RHSM_ORG_ID=$(Q $Settings.RhsmOrgId)",
        "export RHSM_ACTIVATION_KEY=$(Q $Settings.RhsmActivationKey)",
        "export LAB_ROOT_PASSWORD=$(Q $Settings.RootPassword)",
        "export FLATPAK_MIRROR_ENABLED=$(Q $flatpak)",
        "export RHCSA_RECORDING_ENABLED=$(Q $recording)",
        "export AI_REVIEW_ENABLED='false'"
    )
    return (($lines -join "`n") + "`n")
}

# --------------------------------------------------------- Packer (comum) ---
# Variáveis comuns a todos os templates de golden (packer/<provider>/).
function Get-PackerCommonVars([hashtable]$Settings, $Machines) {
    $paths = Get-LabPaths
    $iso = $Settings.IsoPath -replace '\\', '/'
    [ordered]@{
        # file:/// evita que o "D:" do caminho seja lido como esquema de URL.
        iso_path        = $(if ($iso -match '^[A-Za-z]:/') { "file:///$iso" } else { $iso })
        iso_checksum    = $Settings.IsoChecksum
        vm_name         = $Machines.image
        output_dir      = (Join-Path $Settings.GoldenDir $Machines.image) -replace '\\', '/'
        host_ip         = $Settings.HostIp
        http_dir        = $paths.Http -replace '\\', '/'
        http_port       = [int]$Settings.PackerHttpPort
        student_user    = $Machines.student.username
        ssh_key_file    = $paths.StudentKey -replace '\\', '/'
        finalize_script = $paths.Finalize -replace '\\', '/'
        headless        = [bool]$Settings.PackerHeadless
        boot_menu       = $Settings.BootMenu
    }
}

# Roda packer init + build num diretório de template, com variáveis em JSON.
function Invoke-PackerBuild([string]$TemplateDir, $Vars) {
    $paths = Get-LabPaths
    $varFile = Join-Path $paths.Work 'golden.pkrvars.json'
    $Vars | ConvertTo-Json | Set-Content -Path $varFile -Encoding utf8NoBOM
    Push-Location $TemplateDir
    try {
        Write-Step 'packer init (baixa o plugin na primeira vez)'
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
        # O kickstart renderizado tem o hash da senha: não fica em disco.
        Remove-Item -Force (Join-Path $paths.Http 'ks.cfg') -ErrorAction SilentlyContinue
    }
}
