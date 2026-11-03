# Como fazer o deploy no Windows com VMware Workstation

> **Status: testado** em 2026-10-31 (Windows 11 Pro build 26300, 32 GB,
> VMware Workstation Pro 26H1, ISO RHEL 10.2): `image` em ~8 min, `up`
> com provisionamento completo, ciclo `down`/`up`, `lab list` e exercícios
> na workstation. Depois da reorganização do código em `infra/`
> (2026-11), revalidado com `check` e `status`.

As 3 VMs rodam direto no VMware Workstation, sem virtualização aninhada,
numa rede NAT do VMware. Para um passo a passo didático deste mesmo
caminho, ver o [tutorial](../tutorials/primeiro-lab-windows-vmware.md).

## Antes de começar

- Ferramentas comuns instaladas: [preparar o host](preparar-host-infra.md).
- [Requisitos comuns](escolher-o-host.md#requisitos-comuns) (RAM, disco,
  ISO, subscription).

## 1. Instalar o VMware Workstation Pro

Baixe do portal da Broadcom (gratuito para uso pessoal) e instale com as
opções padrão. O `vmrun.exe` e o `vmware-vdiskmanager.exe` vêm junto, em
`C:\Program Files\VMware\VMware Workstation` (ou `Program Files (x86)` em
versões antigas).

## 2. Escolher a rede NAT do lab

O VMware no Windows permite **uma única** rede NAT. Abra Edit → Virtual
Network Editor → Change Settings e anote, da rede NAT (normalmente a
VMnet8):

| Dado | Onde | Exemplo |
|---|---|---|
| Subnet | Subnet IP | `192.168.150.0` |
| Gateway | NAT Settings → Gateway IP | `192.168.150.2` |
| IP do Windows | `ipconfig`, adaptador da VMnet | `192.168.150.1` |
| Faixa DHCP | DHCP Settings | `.128` a `.254` |

Confirme que **Use local DHCP service** está marcado.

O projeto usa `192.168.56.0/24` com gateway em `.1`. Se a sua rede NAT for
outra (o mais comum), crie uma tradução: copie
`infra/ip-map.example.yaml` para `infra/ip-map.vmware.yaml` e ajuste:

```yaml
network:
  from: 192.168.56.0/24
  to: 192.168.150.0/24          # a sua subnet

addresses:
  192.168.56.1: 192.168.150.2   # o Gateway IP do NAT
  192.168.56.10: 192.168.150.10 # workstation
  192.168.56.20: 192.168.150.11 # servera
  192.168.56.30: 192.168.150.12 # serverb
  192.168.56.91: 192.168.150.91 # IP do exercício examsim-network
```

Os quatro endereços das VMs precisam estar **livres** e **fora da faixa
DHCP**. A tradução vale só para a cópia enviada às VMs; os arquivos do
repositório nunca mudam ([por quê](../explanation/infra-hypervisors.md#tradução-de-ips)).

## 3. Configurar o lab

```powershell
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
Copy-Item infra\settings.example.psd1 infra\settings.psd1
code infra\settings.psd1
```

Ajuste, no mínimo:

```powershell
Provider          = 'vmware'
IsoPath           = 'D:\iso\rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<hash da página de download>'
VmRoot            = 'D:\rhcsa-lab'
HostIp            = '192.168.150.1'      # o IP do Windows na VMnet
StudentPassword   = '<sua senha>'
RhsmOrgId         = '<Org ID>'
RhsmActivationKey = '<activation key>'
VMware = @{
    InstallDir = 'C:\Program Files\VMware\VMware Workstation'
    VmNet      = 'VMnet8'
}
```

Todas as chaves: [referência de configuração](../reference/configuracao-infra.md).

## 4. Configurar o host (uma vez, como administrador)

```powershell
sudo pwsh -NoProfile -File .\infra\setup-host.ps1
```

Libera no firewall a porta do servidor HTTP do Packer e grava, no
`C:\ProgramData\VMware\vmnetdhcp.conf`, reservas DHCP para os MACs de
gerência do `machines.yaml` (com backup do original). Rode de novo se
clicar em OK/Apply nas configurações de DHCP do Virtual Network Editor: ele
pode regravar o arquivo.

## 5. Conferir

```powershell
.\infra\lab.ps1 check
```

Tudo `OK`; só a imagem golden aparece como `AVISO` (ainda não existe).

## 6. Construir a imagem golden (uma vez)

```powershell
.\infra\lab.ps1 image
```

O Packer abre a VM, edita o menu de boot da ISO (acompanhe na janela),
instala o RHEL pelo kickstart do projeto, roda o `image/finalize.sh` e
desliga. Fica em `<VmRoot>\golden\vmware\`. Não ligue essa VM.

## 7. Subir o lab

```powershell
.\infra\lab.ps1 up
```

Clona as 3 VMs, liga, confere MACs e discos e provisiona com o Ansible do
projeto (20 a 35 min, a maior parte no mirror flatpak). No fim, tira o
snapshot `pronto` e mostra o endereço do dashboard.

## 8. Estudar

```powershell
.\infra\lab.ps1 ssh workstation
```

```bash
lab list
lab start examsim-grupos
```

O dia a dia (desligar, retomar, voltar ao estado limpo, destruir) está em
[operar o lab](operar-o-lab-infra.md). Se algo falhar:
[resolver problemas](resolver-problemas-infra.md).
