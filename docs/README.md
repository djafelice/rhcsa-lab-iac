# Documentação

Organizada segundo o [Diátaxis](https://diataxis.fr): cada documento tem um
único propósito. Escolha pela sua necessidade no momento.

| Quero… | Tipo | Onde |
|---|---|---|
| aprender, montando o lab pela primeira vez | **Tutorial** | [`tutorials/`](tutorials/) |
| resolver uma tarefa específica | **Guia prático** | [`how-to/`](how-to/) |
| consultar um valor, comando ou formato exato | **Referência** | [`reference/`](reference/) |
| entender como funciona e por que é assim | **Explicação** | [`explanation/`](explanation/) |

## Tutoriais

- [Do zero ao primeiro exercício resolvido](tutorials/primeiro-lab-fim-a-fim.md)
  — host Linux com KVM: pré-requisitos, ISO, `.env`, `make deploy`,
  dashboard e um exercício completo. **Comece por aqui** se usa Linux.
- [Do zero ao primeiro exercício no Windows com VMware Workstation](tutorials/primeiro-lab-windows-vmware.md)
  — o mesmo, sem virtualização aninhada, pelo `infra/`. **Comece por
  aqui** se usa Windows.

## Guias práticos

- [Escolher onde rodar o lab](how-to/escolher-o-host.md) — Linux ou
  Windows; KVM, Hyper-V, VMware Workstation ou VirtualBox; o que foi
  testado.
- [Fazer o deploy num host Linux](how-to/deploy-linux.md) — KVM:
  dependências por distribuição, libvirt, `.env`, `make deploy`.
- Sem virtualização aninhada, pelo `infra/` (primeiro:
  [preparar o host](how-to/preparar-host-infra.md)):
  - [Windows + VMware Workstation](how-to/deploy-windows-vmware.md) (testado)
  - [Windows + Hyper-V](how-to/deploy-windows-hyperv.md) (não testado)
  - [Windows + VirtualBox](how-to/deploy-windows-virtualbox.md) (não testado)
  - [Linux + VMware Workstation](how-to/deploy-linux-vmware.md) (não testado)
  - [Linux + VirtualBox](how-to/deploy-linux-virtualbox.md) (não testado)
- [Fazer o deploy no Windows com virtualização aninhada](how-to/deploy-windows.md)
  — alternativa: WSL2 ou VM Linux rodando o backend KVM (Hyper-V testado;
  WSL2 não).
- [Operar o lab do `infra/` no dia a dia](how-to/operar-o-lab-infra.md) —
  `stop`/`start`, `reset` ao snapshot, `down`/`up`, console das VMs.
- [Resolver problemas do `infra/`](how-to/resolver-problemas-infra.md) —
  sintoma → o que fazer, com os casos vistos na homologação.
- [Operar o lab no dia a dia](how-to/operar-o-lab.md) — SSH, reaplicar o
  Ansible, mudar a topologia, reconstruir a imagem, destruir e recriar.
- [Testar sem subscription (modo offline)](how-to/deploy-offline.md)
- [Ativar a revisão por IA](how-to/ativar-revisao-ia.md) — `make ai-reviewer`
  com Claude Code ou um LLM local/API compatível com OpenAI.
- [Resolver problemas comuns](how-to/resolver-problemas.md) — sintoma → o
  que fazer.
- [Criar um exercício novo](how-to/criar-exercicio.md)
- [Usar Rocky Linux 10 no lugar do RHEL 10](how-to/usar-rocky-linux.md)
  (não testado)

## Referência

- [Alvos do `Makefile`](reference/makefile.md) e arquivos gerados em `output/`
- [`infra/lab.ps1` e `infra/setup-host.ps1`](reference/lab-ps1.md) —
  comandos dos providers, etapas do provisionamento, arquivos gerados
- [Configuração do `infra/`](reference/configuracao-infra.md) —
  `settings.psd1`, `ip-map.<provider>.yaml`, rede de cada provider
- [Configuração](reference/configuracao.md) — `.env`, `machines.yaml`,
  variáveis do Terraform e do Ansible
- [Comando `lab` e dashboard](reference/comando-lab.md) — subcomandos,
  códigos de saída, endpoints
- [Contrato dos exercícios](reference/contrato-exercicios.md) — layout `labs/hosts/`, catálogo, saída do grade, guardas herdadas do homelab
- [Catálogo de exercícios](reference/catalogo-exercicios.md)
- [Testes de aceitação](reference/testes-aceitacao.md) — matriz T1–T11

## Explicação

- [Arquitetura do lab](explanation/arquitetura.md) — topologia, fluxo de
  deploy, subscription, dispatcher `lab`, por que Terraform + Ansible
- [Providers do `infra/`](explanation/infra-hypervisors.md) — como o mesmo
  lab sobe em VMware, VirtualBox e Hyper-V sem virtualização aninhada:
  núcleo + providers, workstation como controladora, tradução de IPs, rede
  e snapshots
- [Imagem golden](explanation/imagem-golden.md) — kickstart, sysprep e
  decisões do build
- [Problemas conhecidos e mitigações](explanation/problemas-conhecidos.md)
  — bugs reais que explicam trechos "estranhos" do código
- [Direitos autorais](explanation/direitos-autorais.md) — o que o projeto
  inclui e o que deliberadamente não inclui

## Onde cada coisa vai (para quem contribui)

- Passo a passo para quem está aprendendo → `tutorials/`
- "Como faço X?", assumindo que a pessoa já conhece o lab → `how-to/`
- Tabelas, flags, formatos, valores padrão → `reference/`
- "Por quê?", histórico de decisões, causas de bugs → `explanation/`

Se um texto mistura dois tipos, separe e ligue os dois com um link.
