# rhcsa-lab-iac

Infraestrutura como código para um laboratório de estudos para o exame
**RHCSA (EX200)** da Red Hat, totalmente reproduzível a partir de uma ISO
RHEL 10 própria: três VMs (`workstation`, `servera`, `serverb`) criadas por
**Terraform** sobre libvirt/KVM e configuradas por **Ansible**. É uma cópia
fiel do lab RHCSA do homelab do autor: 25 exercícios avulsos `examsim-*`
com correção automática, a prova completa `examsim-full` (24 questões), o
exame dinâmico `examsim-dinamico` (24 questões sorteadas de um pool de 166),
um mirror de pacotes/flatpak no estilo "classroom" e um dashboard web de
acompanhamento. Um comando (`make deploy`) faz tudo.

O caminho original roda num **Linux com KVM**. O lab também sobe, **sem
virtualização aninhada**, num host Windows ou Linux com **Hyper-V, VMware
Workstation ou VirtualBox**, pela pasta [`infra/`](infra/) — os mesmos
exercícios, comando `lab`, dashboard e simulados.

**Primeira vez aqui? Siga o [tutorial completo](docs/tutorials/primeiro-lab-fim-a-fim.md)**
— ele assume zero conhecimento prévio deste repositório e cobre cada passo,
do zero até resolver o primeiro exercício.

> Aviso de direitos autorais: este projeto **não contém** nenhum conteúdo do
> material oficial de treinamento da Red Hat. Ver [NOTICE.md](NOTICE.md).

## Onde rodar

| Máquina física | Hypervisor | Como | Status |
|---|---|---|---|
| Linux | KVM | `make deploy` (abaixo) | testado |
| Windows | VMware Workstation | `infra/lab.ps1` | testado |
| Windows | Hyper-V | `infra/lab.ps1` | não testado |
| Windows | VirtualBox | `infra/lab.ps1` | não testado |
| Linux | VMware Workstation | `infra/lab.ps1` | não testado |
| Linux | VirtualBox | `infra/lab.ps1` | não testado |

Como decidir, requisitos e o guia de cada um:
[escolher onde rodar](docs/how-to/escolher-o-host.md). No Windows, comece
pelo [tutorial Windows + VMware](docs/tutorials/primeiro-lab-windows-vmware.md).
As seções a seguir descrevem o caminho original (Linux + KVM).

## Pré-requisitos

No host onde as VMs vão rodar (Linux com suporte a KVM):

- **KVM/libvirt** habilitado (`/dev/kvm` presente, virtualização ligada na
  BIOS/UEFI) e o storage pool `default` do libvirt
- **Terraform** ≥ 1.5 (o provider `dmacvicar/libvirt` é baixado sozinho no
  primeiro `make deploy`)
- **virt-install** e **guestfs-tools** (`libguestfs-tools` em Debian/Ubuntu
  e em distribuições mais antigas) para construir a imagem golden
- **Ansible** (`ansible-core`) + a collection em `ansible/requirements.yml`
  (`ansible-galaxy collection install -r ansible/requirements.yml`)
- **python3** (com PyYAML), **envsubst** (pacote `gettext`), **qemu-img**,
  **xorriso**, **openssl**
- **Recursos**: ~8 GB de RAM livres (3 VMs de 2 GB + o host) e ~45 GB de
  disco; **internet** no deploy para o mirror flatpak (~1,6 GB, desligável
  com `FLATPAK_MIRROR_ENABLED=false`)
- A **ISO oficial do RHEL 10** (DVD, não a boot ISO) baixada da sua própria
  conta Red Hat — este repositório nunca inclui ou redistribui a ISO
- Uma conta **Red Hat Developer Subscription for Individuals** (gratuita),
  com org ID e activation key — ou nada disso, se for usar o modo offline de
  teste (`make deploy-offline`)

Rode `make check-env` para validar tudo isso automaticamente antes de
continuar. Detalhes de como obter a conta/ISO estão no
[tutorial completo](docs/tutorials/primeiro-lab-fim-a-fim.md).

## Passo a passo resumido

```bash
cp .env.example .env
# edite .env: RHEL_ISO_PATH, STUDENT_PASSWORD, RHSM_ORG_ID, RHSM_ACTIVATION_KEY

make check-env      # valida binários, libvirt, .env
make deploy         # imagem golden (se ainda não existir) + 3 VMs + Ansible
```

`make deploy` encadeia, sem pausa:

1. `make build-image` — instala a imagem golden `rhel10-rhcsa-base` via
   `virt-install` + kickstart (só na primeira vez, ~10 min)
2. `make infra` — `terraform apply`: rede NAT `192.168.56.0/24`, discos e as
   3 VMs, e gera o inventário do Ansible em `output/inventory.yml`
3. `make provision` — Ansible: registra cada VM na subscription, deixa rede,
   discos e pacotes iguais ao homelab, monta o classroom na workstation,
   instala exercícios, provas, o comando `lab` e o dashboard, e termina
   **desabilitando todos os repositórios** (como no homelab)

Sem conta Red Hat (só para testar a infraestrutura), use `make deploy-offline`:
os pacotes vêm da própria ISO, sem updates.

Cada etapa também roda sozinha (útil para depurar ou reaplicar só o
Ansible). O Ansible é idempotente: `make provision` pode ser rodado de novo
a qualquer momento.

Depois que o deploy terminar, acesse o dashboard no endereço impresso no
final (por padrão `http://192.168.56.10:8421`) para ver o catálogo de
exercícios e o progresso.

Todo o trabalho com exercícios é feito de dentro da `workstation`:

```bash
make ssh-workstation

lab list                       # lista os exercícios
lab start examsim-grupos       # prepara o exercício (na servera)
# ... resolva em servera/serverb: ssh servera ...
lab grade examsim-grupos       # avalia sem destruir e registra no dashboard
lab finish examsim-grupos      # avalia de novo e limpa

lab start examsim-dinamico     # prova sorteada: 24 questões, nota só no finish
```

Para destruir as VMs, os discos e a rede (sem remover a imagem golden já
construída):

```bash
make destroy
```

Lista completa de targets do `Makefile`: `make help`.

## Arquitetura resumida

- **3 VMs**, não 4: o dashboard web (porta 8421) é um **serviço systemd
  dentro da `workstation`**, não uma VM separada — evita o custo de mais uma
  VM só para servir uma página que só faz sentido junto do dispatcher `lab`.
- **Terraform + Ansible, sem Vagrant**: o Terraform (provider
  `dmacvicar/libvirt`) cria e destrói a infraestrutura com estado próprio —
  nada fica para trás depois de um `make destroy` — e o Ansible configura
  tudo dentro das VMs. `machines.yaml` é a única fonte de verdade da
  topologia para os dois.
- **Sem Packer**: a imagem golden `rhel10-rhcsa-base` é construída direto por
  `virt-install` + kickstart (`scripts/build-image.sh`), decisão deliberada para
  reduzir dependências — quem for rodar isto só precisa apontar o caminho de
  uma ISO que já baixou da própria conta Red Hat, sem instalar e aprender
  mais uma ferramenta de build de imagem. (Os providers de [`infra/`](infra/)
  usam Packer, porque fora do libvirt não há um `virt-install`; o
  kickstart e o sysprep são os mesmos — ver
  [providers do `infra/`](docs/explanation/infra-hypervisors.md).)
- **RHEL 10 real**, não uma distribuição derivada, porque o objetivo é
  praticar para um exame que é aplicado sobre RHEL de verdade (registro via
  Red Hat Developer Subscription for Individuals, gratuita). Há uma
  [guia para usar Rocky Linux](docs/how-to/usar-rocky-linux.md), mas
  não é o caminho testado/mantido com o mesmo rigor.
- **Comando `lab` em três camadas:** wrapper na workstation (registra no
  dashboard) → dispatcher → `ssh root@servera|serverb lab ...`; se o host
  estiver inacessível, falha explicitamente (código 2).
- **"Classroom" na workstation:** o mirror `content.example.com:8091`, o
  repositório flatpak e o NTP, que no homelab são uma LXC separada, aqui
  são serviços da própria workstation, com os mesmos nomes e caminhos.

Detalhes completos, diagrama da topologia e as decisões de design com o
porquê: [docs/explanation/arquitetura.md](docs/explanation/arquitetura.md).

## Documentação

A documentação segue o [Diátaxis](https://diataxis.fr) — índice completo em
[docs/README.md](docs/README.md):

| Quero… | Comece por |
|---|---|
| escolher onde rodar (Linux/Windows, KVM/Hyper-V/VMware/VirtualBox) | [Escolher o host](docs/how-to/escolher-o-host.md) |
| montar o lab pela primeira vez | [Tutorial Linux + KVM](docs/tutorials/primeiro-lab-fim-a-fim.md), [Tutorial Windows + VMware](docs/tutorials/primeiro-lab-windows-vmware.md) |
| fazer uma tarefa específica | [Deploy em Linux](docs/how-to/deploy-linux.md), [Deploy no Windows](docs/how-to/deploy-windows.md), [Revisão por IA](docs/how-to/ativar-revisao-ia.md), [Operar o lab](docs/how-to/operar-o-lab.md), [Modo offline](docs/how-to/deploy-offline.md), [Resolver problemas](docs/how-to/resolver-problemas.md), [Criar um exercício](docs/how-to/criar-exercicio.md) |
| usar o `infra/` no dia a dia | [Operar o lab (`infra/`)](docs/how-to/operar-o-lab-infra.md), [Resolver problemas (`infra/`)](docs/how-to/resolver-problemas-infra.md) |
| consultar comandos e valores | [`infra/lab.ps1`](docs/reference/lab-ps1.md), [Configuração do `infra/`](docs/reference/configuracao-infra.md), [Makefile](docs/reference/makefile.md), [Configuração](docs/reference/configuracao.md), [Comando `lab`](docs/reference/comando-lab.md), [Catálogo](docs/reference/catalogo-exercicios.md) |
| entender o porquê | [Arquitetura](docs/explanation/arquitetura.md), [Providers do `infra/`](docs/explanation/infra-hypervisors.md), [Problemas conhecidos](docs/explanation/problemas-conhecidos.md) |

## Direitos autorais

Este projeto **não inclui** nenhum trecho do material oficial de treinamento
da Red Hat ("RH199 Rapid Track Student Workbook" ou qualquer outro). Os
exercícios vêm de um simulado público e de material MIT de terceiros,
creditados no NOTICE. Ver
[NOTICE.md](NOTICE.md) e [docs/explanation/direitos-autorais.md](docs/explanation/direitos-autorais.md)
para o contexto completo.
