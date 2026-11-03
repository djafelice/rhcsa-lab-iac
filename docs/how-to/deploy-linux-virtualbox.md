# Como fazer o deploy no Linux com VirtualBox

> **Status: não testado.** O provider `virtualbox` (o mesmo do Windows)
> implementa o contrato do provider `vmware` (testado), mas ninguém rodou o
> ciclo completo ainda. Se testar, relate numa issue.

Se o seu Linux pode usar KVM, prefira o [caminho original](deploy-linux.md).
Este guia é para quem já usa o VirtualBox no Linux.

A rede, o acesso por `127.0.0.1:2210-2212` e o dashboard em
`http://127.0.0.1:8421` funcionam como no Windows: leia a introdução do
[guia do Windows](deploy-windows-virtualbox.md) para entender o porquê.

## Antes de começar

- Ferramentas comuns instaladas: [preparar o host](preparar-host-infra.md#linux).
- [Requisitos comuns](escolher-o-host.md#requisitos-comuns).

## 1. Instalar o VirtualBox 7

Use o pacote da sua distribuição ou o repositório da Oracle
(virtualbox.org). Depois:

```bash
sudo usermod -aG vboxusers "$USER"     # saia e entre de novo na sessão
```

Com **Secure Boot** ligado, o módulo `vboxdrv` precisa ser assinado com
uma chave sua (MOK) para carregar.

## 2. Descarregar o KVM enquanto usar o VirtualBox

Com os módulos do KVM carregados, o VirtualBox pode não conseguir usar
VT-x/AMD-V. O `check` avisa:

```bash
sudo modprobe -r kvm_intel kvm_amd kvm
```

Para não carregarem no boot, desabilite o `libvirtd` ou coloque os módulos
numa blacklist (`/etc/modprobe.d/`).

## 3. Configurar o lab

```bash
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
cp infra/settings.example.psd1 infra/settings.psd1
```

Edite `infra/settings.psd1`:

```powershell
Provider          = 'virtualbox'
IsoPath           = '/home/<você>/iso/rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<hash>'
VmRoot            = '/home/<você>/rhcsa-lab'
StudentPassword   = '<sua senha>'
RhsmOrgId         = '<Org ID>'
RhsmActivationKey = '<activation key>'
VirtualBox = @{
    InstallDir    = '/usr/bin'
    NatNetwork    = 'rhcsa-lab'
    SshPortBase   = 2210
    DashboardPort = 8421
}
```

## 4. Configurar, conferir, construir e subir

Nada aqui precisa de root:

```bash
pwsh infra/setup-host.ps1
pwsh infra/lab.ps1 check
pwsh infra/lab.ps1 image
pwsh infra/lab.ps1 up
pwsh infra/lab.ps1 ssh workstation
```

Dia a dia: [operar o lab](operar-o-lab-infra.md). Problemas:
[resolver problemas](resolver-problemas-infra.md).
