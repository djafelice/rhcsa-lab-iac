# Como preparar o host para o `infra/` (Windows ou Linux)

Use antes de qualquer guia de deploy com VMware, VirtualBox ou Hyper-V.
Instala as ferramentas comuns aos três; o hypervisor em si é instalado no
guia de cada um. (Linux com KVM não usa nada disto: siga
[deploy-linux.md](deploy-linux.md).)

O que vai ser instalado:

| Ferramenta | Para quê |
|---|---|
| PowerShell 7.2+ (`pwsh`) | roda o `infra/lab.ps1` (o PowerShell 5.1 do Windows não serve) |
| Git | clonar o repositório (no Windows também traz o `openssl`) |
| Packer | construir a imagem golden uma vez |
| módulo `powershell-yaml` | ler o `machines.yaml` |
| OpenSSH client e `tar` | falar com as VMs (já vêm no Windows 10/11 e no Linux) |
| `openssl` | gerar o hash da senha do `student` |

## Windows

### 1. Instalar as ferramentas

Num terminal (PowerShell ou Prompt):

```powershell
winget install --id Microsoft.PowerShell -e
winget install --id Git.Git -e
winget install --id Hashicorp.Packer -e
```

**Feche e abra o terminal** e use daqui em diante o **PowerShell 7**
(`pwsh`): o `PATH` novo só vale para terminais abertos depois da instalação.

### 2. Configurar o Git para não converter quebras de linha

Os scripts do lab rodam dentro das VMs Linux e quebram com quebras de
linha do Windows (CRLF):

```powershell
git config --global core.autocrlf false
git config --global core.eol lf
```

O repositório também tem um `.gitattributes` que força LF, mas configure
assim mesmo para clones antigos.

### 3. Instalar o `powershell-yaml` para todos os usuários

Num PowerShell 7 **como administrador** (ou `sudo pwsh`, ver o passo 5):

```powershell
Install-PSResource powershell-yaml -Scope AllUsers -TrustRepository
```

Use o `Install-PSResource` (já vem no PowerShell 7.4+), não o
`Install-Module`: o antigo depende de um provider NuGet que falha em
versões recentes. E instale em `AllUsers`, fora da pasta Documentos, que
costuma estar no OneDrive.

### 4. Liberar scripts locais

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Se baixar arquivos `.ps1` ou `.zip` pela internet, rode `Unblock-File` neles.

### 5. (Recomendado) Ativar o `sudo` do Windows

O `infra/setup-host.ps1` precisa de administrador uma vez; o resto roda
como usuário normal. O `sudo` do Windows 11 eleva um comando na mesma
janela: Configurações → Sistema → Para desenvolvedores → **Habilitar
sudo**, modo **Inline**. Uso: `sudo pwsh -NoProfile -File .\infra\setup-host.ps1`.

**Não rode o `lab.ps1` como administrador.** VMs ligadas por um processo
elevado podem ficar invisíveis para uma sessão normal, e vice-versa.

### 6. Conferir

```powershell
$PSVersionTable.PSVersion          # 7.2 ou maior
git config --global --get core.autocrlf   # false
packer version
ssh -V
Get-Module -ListAvailable powershell-yaml
```

## Linux

### 1. Instalar as ferramentas

```bash
# RHEL/Rocky/Fedora
sudo dnf install -y git openssl tar openssh-clients dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y packer

# Ubuntu/Debian
sudo apt update && sudo apt install -y git openssl tar openssh-client gnupg curl lsb-release
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer
```

### 2. Instalar o PowerShell 7

Siga o guia oficial da Microsoft para a sua distribuição ("Install
PowerShell on Linux", em learn.microsoft.com). Em distribuições com snap,
a forma mais curta é:

```bash
sudo snap install powershell --classic
```

### 3. Instalar o `powershell-yaml` para todos os usuários

```bash
sudo pwsh -NoProfile -Command 'Install-PSResource powershell-yaml -Scope AllUsers -TrustRepository'
```

### 4. Conferir

```bash
pwsh --version
packer version
pwsh -NoProfile -Command 'Get-Module -ListAvailable powershell-yaml'
```

No Linux, os comandos do lab rodam sempre pelo `pwsh`:
`pwsh infra/lab.ps1 <comando>` (no Windows: `.\infra\lab.ps1 <comando>`).

## Próximo passo

Volte ao guia do seu hypervisor ([escolher o host](escolher-o-host.md)).
