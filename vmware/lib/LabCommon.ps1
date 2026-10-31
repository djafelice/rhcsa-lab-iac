# Funções compartilhadas pelos scripts do backend VMware (lab.ps1,
# setup-host.ps1). Carregado com dot-source: . "$PSScriptRoot\lib\LabCommon.ps1"
#
# Requisitos: PowerShell 7.2+, módulo powershell-yaml.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------- caminhos ---
$script:VmwareBackendDir = Split-Path -Parent $PSScriptRoot
$script:RepoRoot         = Split-Path -Parent $script:VmwareBackendDir
$script:WorkDir          = Join-Path $script:VmwareBackendDir '.work'

function Get-LabPaths {
    [ordered]@{
        Repo        = $script:RepoRoot
        Backend     = $script:VmwareBackendDir
        Work        = $script:WorkDir
        Http        = Join-Path $script:WorkDir 'http'
        StudentKey  = Join-Path $script:WorkDir 'student_key'
        Settings    = Join-Path $script:VmwareBackendDir 'settings.psd1'
        IpMap       = Join-Path $script:VmwareBackendDir 'ip-map.yaml'
        Machines    = Join-Path $script:RepoRoot 'machines.yaml'
        Kickstart   = Join-Path $script:RepoRoot 'kickstart\ks.cfg.tpl'
        Finalize    = Join-Path $script:RepoRoot 'image\finalize.sh'
        PackerDir   = Join-Path $script:VmwareBackendDir 'packer'
    }
}

# --------------------------------------------------------------- mensagens ---
function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "  OK    $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "  AVISO $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "  ERRO  $Message" -ForegroundColor Red }

# ------------------------------------------------------------ configuração ---
function Get-LabSettings {
    $paths = Get-LabPaths
    if (-not (Test-Path $paths.Settings)) {
        throw "Não encontrei $($paths.Settings). Copie vmware\settings.example.psd1 para vmware\settings.psd1 e ajuste."
    }
    $s = Import-PowerShellDataFile -Path $paths.Settings
    $required = 'VmwareDir', 'IsoPath', 'IsoChecksum', 'VmRoot', 'VmNet', 'HostIp',
                'PackerHttpPort', 'PackerHeadless', 'BootMenu', 'StudentPassword'
    $missing = $required | Where-Object { -not $s.ContainsKey($_) }
    if ($missing) { throw "Faltam chaves em settings.psd1: $($missing -join ', ')" }
    if ($s.StudentPassword -eq 'troque-esta-senha' -or [string]::IsNullOrWhiteSpace($s.StudentPassword)) {
        throw 'Defina StudentPassword em vmware\settings.psd1 (não use o valor de exemplo).'
    }
    if ($s.BootMenu -notin 'grub', 'isolinux') {
        throw "BootMenu deve ser 'grub' ou 'isolinux' (atual: '$($s.BootMenu)')."
    }
    $s.GoldenDir  = Join-Path $s.VmRoot 'golden'
    $s.LabDir     = Join-Path $s.VmRoot 'lab'
    return $s
}

# --------------------------------------------------------------- ferramentas ---
function Get-VmwareTool([hashtable]$Settings, [string]$Name) {
    $p = Join-Path $Settings.VmwareDir $Name
    if (-not (Test-Path $p)) { throw "Não encontrei $Name em $($Settings.VmwareDir) (ajuste VmwareDir em settings.psd1)." }
    return $p
}

# openssl.exe vem com o Git for Windows (usr\bin). Usado só para gerar o hash
# SHA-512 crypt da senha do student, o mesmo formato do "openssl passwd -6"
# usado por scripts/build-image.sh no backend Linux.
function Get-GitOpenSsl {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { throw 'git não encontrado no PATH (instale o Git for Windows).' }
    # ...\Git\cmd\git.exe -> ...\Git
    $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
    $openssl = Join-Path $gitRoot 'usr\bin\openssl.exe'
    if (-not (Test-Path $openssl)) { throw "openssl.exe não encontrado em $openssl (vem com o Git for Windows)." }
    return $openssl
}

# ----------------------------------------------------- tradução de IPs ---
function Get-IpMap {
    $paths = Get-LabPaths
    Import-Module powershell-yaml -ErrorAction Stop
    $raw = ConvertFrom-Yaml (Get-Content $paths.IpMap -Raw)
    $fromNet = ($raw.network.from -split '/')[0]
    $toNet   = ($raw.network.to -split '/')[0]
    $fromPrefix = $fromNet.Substring(0, $fromNet.LastIndexOf('.'))
    $toPrefix   = $toNet.Substring(0, $toNet.LastIndexOf('.'))
    $map = @{}
    foreach ($k in $raw.addresses.Keys) { $map[[string]$k] = [string]$raw.addresses[$k] }
    # O endereço de rede (.0) é traduzido automaticamente.
    $map["$fromPrefix.0"] = "$toPrefix.0"
    [pscustomobject]@{
        FromPrefix = $fromPrefix
        ToPrefix   = $toPrefix
        FromCidr   = [string]$raw.network.from
        ToCidr     = [string]$raw.network.to
        Map        = $map
    }
}

# Troca todo IP da rede original pelo equivalente da tabela. O regex casa o
# octeto final inteiro (192.168.56.1 nunca casa dentro de 192.168.56.10).
# Lança erro listando qualquer endereço sem mapeamento.
function Convert-LabText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$IpMap,
        [string]$Source = '(texto)'
    )
    $escaped = [regex]::Escape($IpMap.FromPrefix)
    $pattern = "(?<![\d.])$escaped\.(\d{1,3})(?![\d])"
    $unmapped = [System.Collections.Generic.HashSet[string]]::new()
    $result = [regex]::Replace($Text, $pattern, {
            param($m)
            $ip = $m.Value
            if ($IpMap.Map.ContainsKey($ip)) { return $IpMap.Map[$ip] }
            [void]$unmapped.Add($ip)
            return $ip
        })
    if ($unmapped.Count -gt 0) {
        throw "Endereços sem tradução em vmware\ip-map.yaml ($Source): $($unmapped -join ', ')"
    }
    return $result
}

# machines.yaml já traduzido para a rede do VMware.
function Get-LabMachines {
    $paths = Get-LabPaths
    Import-Module powershell-yaml -ErrorAction Stop
    $ipMap = Get-IpMap
    $text = Convert-LabText -Text (Get-Content $paths.Machines -Raw) -IpMap $ipMap -Source 'machines.yaml'
    return ConvertFrom-Yaml $text
}

# --------------------------------------------------------- chave do student ---
# Par ed25519 com que o Packer (e depois o provisionamento) entra nas VMs.
# Equivale ao output/student_key do backend Linux. Fica em vmware\.work\.
function Initialize-StudentKey {
    $paths = Get-LabPaths
    New-Item -ItemType Directory -Force -Path $paths.Work | Out-Null
    if (-not (Test-Path $paths.StudentKey)) {
        Write-Step 'Gerando par de chaves SSH do student (vmware\.work\student_key)'
        # Start-Process com a linha de comando crua: garante que -N "" chegue
        # ao ssh-keygen como senha vazia em qualquer versão do PowerShell.
        $kgArgs = "-q -t ed25519 -N `"`" -C rhcsa-lab-iac-student -f `"$($paths.StudentKey)`""
        $p = Start-Process -FilePath 'ssh-keygen.exe' -ArgumentList $kgArgs -NoNewWindow -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "ssh-keygen falhou (código $($p.ExitCode))." }
    }
    # O ssh.exe do Windows recusa chave privada legível por outros usuários
    # ("UNPROTECTED PRIVATE KEY FILE"). Deixa só o usuário atual com acesso.
    & icacls.exe $paths.StudentKey /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'icacls falhou ao restringir a chave privada.' }
    return $paths.StudentKey
}

# ---------------------------------------------------------------- kickstart ---
function Get-PasswordHash([string]$Password) {
    $openssl = Get-GitOpenSsl
    # -stdin: a senha não aparece na linha de comando (lista de processos).
    $hash = $Password | & $openssl passwd -6 -stdin
    if ($LASTEXITCODE -ne 0 -or -not ($hash -match '^\$6\$')) { throw 'Falha ao gerar o hash da senha com openssl.' }
    return ($hash | Select-Object -First 1).Trim()
}

# Renderiza kickstart/ks.cfg.tpl (o MESMO template do backend Linux) e aplica
# as adaptações do VMware, sempre falhando alto se o template do upstream
# mudar a ponto de a adaptação não se aplicar mais.
function New-LabKickstart([hashtable]$Settings, [string]$StudentUser) {
    $paths = Get-LabPaths
    $tpl = (Get-Content $paths.Kickstart -Raw) -replace "`r`n", "`n"

    $pub = (Get-Content "$($paths.StudentKey).pub" -Raw).Trim()
    $hash = Get-PasswordHash $Settings.StudentPassword

    # .Replace() é literal: o hash tem "$" e não pode passar por regex.
    $ks = $tpl.Replace('${STUDENT_USER}', $StudentUser).
               Replace('${STUDENT_PASSWORD_HASH}', $hash).
               Replace('${STUDENT_SSH_PUBKEY}', $pub)

    # 1) poweroff -> reboot: no libvirt o virt-install detecta o fim pelo
    #    poweroff e o sysprep (image/finalize.sh) roda offline. No VMware o
    #    Packer precisa entrar por SSH depois do 1o boot para rodar o mesmo
    #    finalize.sh e desligar a VM ele mesmo.
    $re = [regex]'(?m)^poweroff[ \t]*$'
    if (-not $re.IsMatch($ks)) { throw "Adaptação falhou: linha 'poweroff' não encontrada em kickstart/ks.cfg.tpl." }
    $ks = $re.Replace($ks, "# rhcsa-lab-iac (VMware): reboot no lugar de poweroff -- o Packer`n# entra por SSH no 1o boot para rodar image/finalize.sh.`nreboot", 1)

    # 2) open-vm-tools: integração com o VMware (desligamento limpo pelo
    #    vmrun, IP visível para o vmrun/Packer, sincronismo de relógio).
    $re = [regex]'(?m)^@\^minimal-environment[ \t]*$'
    if (-not $re.IsMatch($ks)) { throw "Adaptação falhou: '@^minimal-environment' não encontrado no %packages." }
    $ks = $re.Replace($ks, "@^minimal-environment`n# rhcsa-lab-iac (VMware): integração com o hypervisor.`nopen-vm-tools", 1)

    if ($ks -match '\$\{[A-Z_]+\}') { throw "Ainda há placeholders sem valor no kickstart: $($Matches[0])" }

    New-Item -ItemType Directory -Force -Path $paths.Http | Out-Null
    $out = Join-Path $paths.Http 'ks.cfg'
    [System.IO.File]::WriteAllText($out, $ks, [System.Text.UTF8Encoding]::new($false))
    return $out
}

# ------------------------------------------------------------------ vmrun ---
function Invoke-Vmrun([hashtable]$Settings, [string[]]$Arguments, [switch]$AllowFailure) {
    $vmrun = Get-VmwareTool $Settings 'vmrun.exe'
    $out = & $vmrun -T ws @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw "vmrun $($Arguments -join ' ') falhou: $out"
    }
    return $out
}

function Get-GoldenVmx([hashtable]$Settings, [string]$ImageName) {
    Join-Path (Join-Path $Settings.GoldenDir $ImageName) "$ImageName.vmx"
}
