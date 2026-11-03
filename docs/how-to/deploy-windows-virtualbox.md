# Como fazer o deploy no Windows com VirtualBox

> **Status: não testado.** O provider `virtualbox` implementa o mesmo
> contrato do provider `vmware` (testado) e foi revisado, mas ninguém rodou
> o ciclo completo ainda. Pontos de maior risco: a sintaxe dos comandos de
> NAT Network e DHCP do `VBoxManage` (escrita para o VirtualBox 7.x). Se
> testar, relate numa issue.

As 3 VMs rodam direto no VirtualBox, sem virtualização aninhada, numa
**NAT Network** dedicada (`rhcsa-lab`, `192.168.56.0/24`). Nela o próprio
VirtualBox é o gateway e o DNS em `192.168.56.1` e entrega a cada VM o IP
do `machines.yaml` por DHCP fixo por MAC, o mesmo papel do host no backend
KVM.

A diferença para os outros hypervisors: a NAT Network **não é alcançável
direto pelo Windows**. SSH e dashboard passam por redirecionamento de
portas em `127.0.0.1`:

| Destino | Do Windows |
|---|---|
| SSH da workstation / servera / serverb | `127.0.0.1:2210` / `2211` / `2212` |
| Dashboard | `http://127.0.0.1:8421` |

O `lab.ps1 ssh <vm>` já usa a porta certa; você não precisa decorar.

## Antes de começar

- Ferramentas comuns instaladas: [preparar o host](preparar-host-infra.md).
- [Requisitos comuns](escolher-o-host.md#requisitos-comuns).
- De preferência, Hyper-V **desligado**: com ele ligado o VirtualBox roda
  por cima do hypervisor da Microsoft, bem mais lento. O `check` avisa.

## 1. Instalar o VirtualBox 7

```powershell
winget install --id Oracle.VirtualBox -e
```

## 2. Configurar o lab

```powershell
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
Copy-Item infra\settings.example.psd1 infra\settings.psd1
code infra\settings.psd1
```

```powershell
Provider          = 'virtualbox'
IsoPath           = 'D:\iso\rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<hash>'
VmRoot            = 'D:\rhcsa-lab'
StudentPassword   = '<sua senha>'
RhsmOrgId         = '<Org ID>'
RhsmActivationKey = '<activation key>'
VirtualBox = @{
    InstallDir    = 'C:\Program Files\Oracle\VirtualBox'
    NatNetwork    = 'rhcsa-lab'
    SshPortBase   = 2210
    DashboardPort = 8421
}
```

O `HostIp` não é usado (na instalação da golden o Packer usa a rede NAT
própria do VirtualBox). Não crie `ip-map.virtualbox.yaml`.

## 3. Configurar o host (sem administrador)

```powershell
.\infra\setup-host.ps1
```

Cria a NAT Network `rhcsa-lab`, restringe a faixa dinâmica do DHCP a
`.100-.200`, fixa o IP de cada MAC de gerência e cria os redirecionamentos
de porta. Rode de novo se mudar o `machines.yaml`.

## 4. Conferir, construir a golden e subir

```powershell
.\infra\lab.ps1 check
.\infra\lab.ps1 image
.\infra\lab.ps1 up
```

A golden fica registrada no VirtualBox como a VM `rhel10-rhcsa-base`
(com o snapshot `base`): não a ligue nem a apague, os clones dependem dela.

## 5. Estudar

```powershell
.\infra\lab.ps1 ssh workstation
```

Console de uma VM (para o exercício de recuperar a senha de root): no
VirtualBox, selecione `rhcsa-lab-serverb` e clique em **Mostrar**.

Dia a dia: [operar o lab](operar-o-lab-infra.md). Problemas:
[resolver problemas](resolver-problemas-infra.md).
