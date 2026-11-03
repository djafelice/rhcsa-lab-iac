# Referência: configuração do `infra/`

Arquivos de configuração dos providers do `infra/`. A configuração do
backend KVM (`.env`, variáveis do Terraform) está em
[configuração](configuracao.md); o `machines.yaml` é comum aos dois.

## `infra/settings.psd1`

Arquivo local (ignorado pelo Git), criado a partir de
`infra/settings.example.psd1`. Formato: hashtable do PowerShell.

### Comuns

| Chave | Obrigatória | Padrão | Significado |
|---|---|---|---|
| `Provider` | sim | — | `vmware`, `hyperv` ou `virtualbox`. Validado contra o sistema do host |
| `IsoPath` | sim | — | caminho da DVD ISO do RHEL 10 x86_64 |
| `IsoChecksum` | sim | — | `sha256:<hash>` ou `none` (sem verificação; o `check` avisa) |
| `VmRoot` | sim | — | raiz das VMs: `golden/<provider>/` e `lab/<provider>/` |
| `HostIp` | sim | — | IP do host na rede do lab, de onde o Packer serve o kickstart. Usado só pelo `vmware`; `hyperv` usa o gateway, `virtualbox` usa a rede NAT própria do Packer |
| `PackerHttpPort` | sim | — | porta fixa do servidor HTTP do Packer (padrão do exemplo: `8519`) |
| `PackerHeadless` | sim | — | `$true` constrói a golden sem janela |
| `BootMenu` | sim | — | `grub` (RHEL 10 em BIOS) ou `isolinux` |
| `StudentPassword` | sim | — | senha do `student`; aplicada **na golden** (mudá-la exige `image -Force`). O acesso do `lab.ps1` é por chave |
| `RhsmOrgId` | para provisionar | `''` | Org ID da Red Hat Developer Subscription |
| `RhsmActivationKey` | para provisionar | `''` | nome da activation key |
| `RootPassword` | não | `''` | senha de root nas VMs; vazio = root só por chave |
| `FlatpakMirror` | não | `$true` | monta o mirror flatpak (~1,6 GB por provisionamento); `$false` desliga `examsim-flatpak` e `dyn-flatpak-*` |
| `RecordingEnabled` | não | `$false` | grava os terminais (pré-requisito da [revisão por IA](../how-to/ativar-revisao-ia.md)) |

Só a seção do provider escolhido é lida; as outras podem ficar no arquivo.

### `VMware = @{ ... }`

| Chave | Padrão | Significado |
|---|---|---|
| `InstallDir` | `C:\Program Files\VMware\VMware Workstation` (Linux: `/usr/bin`) | onde estão `vmrun` e `vmware-vdiskmanager` |
| `VmNet` | — (obrigatória) | rede NAT do VMware do lab (`VMnet8`, `vmnet8`, ...) |

### `HyperV = @{ ... }`

| Chave | Padrão | Significado |
|---|---|---|
| `SwitchName` | `rhcsa-lab` | switch interno do lab |
| `NatName` | `rhcsa-lab` | NAT do Windows (`New-NetNat`) |
| `GoldenIp` | `<rede>.250` | IP só da VM de build da golden |

### `VirtualBox = @{ ... }`

| Chave | Padrão | Significado |
|---|---|---|
| `InstallDir` | `C:\Program Files\Oracle\VirtualBox` (Linux: `/usr/bin`) | onde está o `VBoxManage` |
| `NatNetwork` | `rhcsa-lab` | NAT Network do lab |
| `SshPortBase` | `2210` | porta local do SSH da 1ª VM do `machines.yaml`; as seguintes somam 1 |
| `DashboardPort` | `8421` | porta local do dashboard |

## `infra/ip-map.<provider>.yaml`

Opcional e local (ignorado pelo Git), um por provider. Sem ele, o lab usa
a rede original `192.168.56.0/24`. Com ele, todo `192.168.56.X` do projeto
é trocado pelo endereço da tabela, em memória e na cópia enviada às VMs.

```yaml
network:
  from: 192.168.56.0/24
  to: 192.168.150.0/24
addresses:
  192.168.56.1: 192.168.150.2     # gateway e DNS
  192.168.56.10: 192.168.150.10   # workstation
  192.168.56.20: 192.168.150.11   # servera
  192.168.56.30: 192.168.150.12   # serverb
  192.168.56.91: 192.168.150.91   # IP do exercício examsim-network
```

Regras: mesma máscara dos dois lados; o endereço de rede (`.0`) é
traduzido sozinho; um `192.168.56.X` do projeto sem entrada faz o `check`
falhar com a lista do que falta. `infra/` e `terraform/` não são
traduzidos (não vão para as VMs).

## Rede de cada provider

| | `vmware` | `hyperv` | `virtualbox` |
|---|---|---|---|
| Rede | NAT do VMware (`VmNet`) | switch interno `rhcsa-lab` | NAT Network `rhcsa-lab` |
| Gateway e DNS (`.1` do projeto) | o NAT do VMware (via `ip-map`, se preciso) | o Windows, com `New-NetNat` | o VirtualBox |
| IP das VMs no 1º boot | reserva DHCP por MAC | perfil NM por MAC embutido na golden | DHCP fixo por MAC |
| Host alcança as VMs | direto pelo IP | direto pelo IP | `127.0.0.1:<SshPortBase + n>` |
| Tradução de IPs | normalmente sim | não | não |

## O que o `infra/` lê do `machines.yaml`

| Campo | Uso |
|---|---|
| `image` | nome da golden |
| `student.username` | usuário do kickstart e do SSH |
| `domain`, `classroom`, `dashboard` | inventário e URL do dashboard |
| `network.cidr`, `network.gateway`, `network.dns` | rede do lab (Hyper-V/VirtualBox) e inventário |
| `machines.<vm>.ip`, `cpus`, `memory_mb`, `role` | cada VM |
| `machines.<vm>.nics[].mac`, `name` | MACs fixos (o role `common` renomeia para `ens18`/`ens19` pelo MAC); o 1º é o de gerência |
| `machines.<vm>.extra_disks[].size_gb`, `label` | discos extra, criados **na ordem** (os exercícios os acham pelo tamanho) |

Mudou o `machines.yaml`? Rode o `setup-host.ps1` de novo (reservas DHCP e
redirecionamentos) e recrie o lab (`down` + `up`); no Hyper-V, também
`image -Force`.
