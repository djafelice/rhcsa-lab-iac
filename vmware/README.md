# Backend VMware Workstation (Windows)

Alternativa ao backend Linux (KVM + Terraform) para rodar o mesmo lab RHCSA
EX200 com as 3 VMs criadas **diretamente** no VMware Workstation, sem
virtualização aninhada. Os exercícios, o comando `lab`, o dashboard e os
simulados são exatamente os do projeto; só as camadas de imagem e
infraestrutura mudam.

| Backend Linux | Backend VMware |
|---|---|
| `virt-install` + `virt-customize` | Packer (`vmware-iso`), mesmo kickstart e mesmo `finalize.sh` |
| Terraform (libvirt) | PowerShell + `vmrun` (fase 2) |
| Ansible no host | Ansible na workstation, como controladora temporária (fase 3) |
| Rede libvirt `192.168.56.0/24` | Rede NAT do VMware, endereços traduzidos por `ip-map.yaml` |

## Estado

- [x] **Fase 1**: configuração, tradução de IPs, imagem golden
- [x] **Fase 2**: `up` / `down` / `status` / `ssh` da infraestrutura (clones vinculados)
- [ ] Fase 3: provisionamento com o Ansible original
- [ ] Fase 4: snapshot, reset, desregistro da subscription

## Requisitos

Windows 11, VMware Workstation Pro (testado na 26H1), PowerShell 7.2+,
Git for Windows (com `core.autocrlf=false`), Packer, módulo
`powershell-yaml`, cliente OpenSSH do Windows, ISO DVD do RHEL 10.

## Rede

O lab usa uma rede NAT existente do VMware (aqui, a VMnet1 em
`172.16.0.0/24`, gateway `172.16.0.1`). Como o projeto original usa
`192.168.56.0/24`, o arquivo `ip-map.yaml` define a tradução, aplicada só em
memória e na cópia enviada às VMs, nunca nos arquivos versionados:

| Original | VMware | Papel |
|---|---|---|
| `192.168.56.1` | `172.16.0.1` | gateway e DNS (NAT do VMware) |
| `192.168.56.10` | `172.16.0.10` | workstation |
| `192.168.56.20` | `172.16.0.11` | servera |
| `192.168.56.30` | `172.16.0.12` | serverb |
| `192.168.56.91` | `172.16.0.91` | IP do exercício `examsim-network` |

Os endereços do lab precisam estar livres na rede e fora da faixa DHCP do
VMware. Se o upstream passar a usar um IP novo, `lab.ps1 check` acusa.

## Fase 1: imagem golden

Todos os comandos no PowerShell 7 (`pwsh`), na raiz do repositório.

**1. Configuração local**

```powershell
Copy-Item vmware\settings.example.psd1 vmware\settings.psd1
code vmware\settings.psd1
```

Ajuste pelo menos `IsoPath`, `IsoChecksum` (recomendado), `VmRoot`,
`VmNet`, `HostIp` e `StudentPassword`.

**2. Configuração única do Windows (como administrador)**

Abra um PowerShell 7 **como administrador** e rode:

```powershell
.\vmware\setup-host.ps1
```

Cria a regra de firewall do Packer e as reservas DHCP do lab no
`vmnetdhcp.conf` do VMware (com backup do original).

**3. Conferência**

```powershell
.\vmware\lab.ps1 check
```

Só o item "Imagem golden" pode aparecer como aviso nesta etapa.

**4. Construir a golden**

```powershell
.\vmware\lab.ps1 image
```

O Packer cria uma VM temporária na VMnet1, digita no menu de boot da ISO o
endereço do kickstart, espera a instalação, entra por SSH para rodar o
`image\finalize.sh`, desliga a VM e o script tira o snapshot `base`. Leva de
10 a 20 minutos. Com `PackerHeadless = $false` você acompanha tudo pela
janela da VM.

O resultado fica em `<VmRoot>\golden\rhel10-rhcsa-base\`. **Não ligue essa
VM**: ela é só a base dos clones.

## Fase 2: infraestrutura efêmera

```powershell
.\vmware\lab.ps1 up          # cria e liga as 3 VMs (em segundo plano)
.\vmware\lab.ps1 up -Gui     # idem, abrindo as janelas no Workstation
.\vmware\lab.ps1 status      # estado, IP e SSH de cada VM
.\vmware\lab.ps1 ssh servera # entra como student (sudo sem senha)
.\vmware\lab.ps1 down        # desliga e apaga as 3 VMs (pede confirmação)
```

O `up` é idempotente: VMs que já existem não são recriadas, só ligadas.
Cada VM é um **clone vinculado** do snapshot `base` da golden, então nasce
em segundos e guarda só as diferenças. O script ajusta o `.vmx` de cada
clone a partir de `machines.yaml`:

| VM | CPU / RAM | NICs (MAC fixo, VMnet do lab) | Discos extra (SCSI, nesta ordem) |
|---|---|---|---|
| workstation | 2 / 2048 | ens18 | - |
| servera | 2 / 2048 | ens18, ens19 | 2 GiB, 3 GiB |
| serverb | 2 / 2048 | ens18 | 6 GiB, 1 GiB, 2 GiB, 3 GiB |

Os nomes `ens18`/`ens19` só aparecem depois do provisionamento (fase 3);
até lá as placas têm o nome padrão do kernel. No fim, o `up` entra por SSH
em cada VM e confere se os MACs e os tamanhos dos discos batem com
`machines.yaml`.

Nesta fase as VMs ainda são o RHEL "cru" da golden: sem registro na Red
Hat, sem exercícios e sem dashboard.

## Problemas comuns na fase 1

**O boot_command não edita o menu da ISO.** O Packer digita as teclas logo
depois do boot. Se o menu tiver outro formato:

- Menu com fundo preto e entradas de texto, onde `e` edita: é GRUB (padrão).
  Se a edição cair na linha errada, ajuste o número de `<down>` em
  `boot_grub` no `packer\rhel10-golden.pkr.hcl`.
- Menu onde `Tab` abre os parâmetros: use `BootMenu = 'isolinux'`.

**A instalação não acha o kickstart.** Confira se a VM recebeu IP na VMnet1
e se o Windows responde em `http://<HostIp>:<PackerHttpPort>/ks.cfg`
(firewall: `setup-host.ps1`). O log completo do Packer fica em
`vmware\.work\packer-build.log`.

**O Packer não consegue digitar no menu (erro de VNC).** O Packer usa VNC
local para enviar as teclas. Se a sua versão do Workstation recusar, me
avise: a alternativa é digitar o parâmetro manualmente uma vez.

## Arquivos

| Arquivo | Papel |
|---|---|
| `lab.ps1` | Comando principal (`check`, `image`; próximas fases: `up`, `down`...) |
| `setup-host.ps1` | Configuração única do Windows (administrador) |
| `settings.example.psd1` | Modelo da configuração local |
| `ip-map.yaml` | Tradução de endereços da rede do lab |
| `lib/LabCommon.ps1` | Funções compartilhadas |
| `packer/rhel10-golden.pkr.hcl` | Template da imagem golden |
| `.work/` | Gerado: chave SSH do student, logs, variáveis (ignorado pelo Git) |
