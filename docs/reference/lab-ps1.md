# Referência: `infra/lab.ps1` e `infra/setup-host.ps1`

Comandos dos providers do `infra/` (VMware Workstation, VirtualBox,
Hyper-V). O equivalente do backend KVM é o [`Makefile`](makefile.md).

Sintaxe: `.\infra\lab.ps1 <comando> [nome] [-Force] [-Gui] [-NoProvision]`
no Windows; `pwsh infra/lab.ps1 ...` no Linux. Rode sempre na raiz do
repositório, numa sessão **sem** administrador. O provider vem de
`Provider` no [`settings.psd1`](configuracao-infra.md).

## Comandos

| Comando | O que faz | Opções | Idempotente |
|---|---|---|---|
| `check` | Confere ferramentas, quebras de linha, `settings.psd1`, ISO, subscription, tradução de IPs, o host do provider e a golden. Avisa se o provider não foi testado neste sistema | — | sim |
| `image` | Gera a chave SSH (se faltar), renderiza o kickstart e constrói a golden com o Packer | `-Force`: reconstrói (exige o lab apagado) | não reconstrói sem `-Force` |
| `up` | Cria as VMs que faltam (clones da golden), liga, confere MACs e discos e, se o lab ainda não foi provisionado, roda `provision`. Lab já provisionado: só liga | `-NoProvision`: só infraestrutura. `-Gui`: liga com janela | sim |
| `provision` | Provisiona com o Ansible do projeto (ver abaixo) e refaz o snapshot `pronto` | `-Gui` | sim |
| `stop` | Desliga as VMs (limpo; "na tomada" após 90 s) | — | sim |
| `start` | Liga as VMs e espera o SSH | `-Gui` | sim |
| `snapshot` | Desliga, substitui o snapshot `pronto` pelo estado atual e religa | — | sim |
| `reset` | Volta as VMs ao snapshot `pronto` e religa. Pede confirmação | `-Force`: sem confirmação | sim |
| `down` | Desregistra cada VM ligada da Red Hat e apaga as VMs (com snapshots). Mantém a golden. Pede confirmação | `-Force`: sem confirmação | sim |
| `status` | Tabela das VMs (estado, endereço SSH, snapshot), provisionamento, golden e dashboard | — | — |
| `ssh <vm>` | SSH interativo como `student` em `workstation`, `servera` ou `serverb` | — | — |
| `help` | Ajuda | — | — |

`check` termina com código 1 se houver algum `ERRO`. Os demais terminam
com erro (código diferente de 0) na primeira falha, com a mensagem da
causa.

## O que o `provision` faz

| Etapa | Onde | Detalhe |
|---|---|---|
| ISO no CD da workstation | host | confere a mídia **dentro** da VM (`blkid /dev/sr0`); sem mídia, desliga, conecta a ISO e religa |
| Cópia do repositório | host | arquivos do Git (rastreados e novos não ignorados), sem `infra/` e `terraform/`, com IPs traduzidos; `output/inventory.yml` no formato do Terraform; tudo em `.work/stage` |
| Envio | host → workstation | `scp` para `/root/rhcsa-provision`; segredos pelo stdin do `ssh` (nunca em disco no host) |
| `prepare` | workstation | monta a ISO, instala `ansible-core` da ISO, `ansible-galaxy` das collections, valida o catálogo e aplica só a rede do role `common` na workstation, sem reboot |
| reboot | host | reinicia a workstation, que volta com `ens18` |
| `site` | workstation | `ansible-playbook ansible/site.yml -e lab_iso_url=file:///mnt/rhcsa-lab-iso` |
| `cleanup` | workstation | remove `ansible-core`, a chave e os segredos; o host guarda os logs em `.work/logs` |
| marcador e snapshot | host | grava `.provisionado` e tira o snapshot `pronto` |

As fases `prepare` e `site` rodam via `systemd-run` (sobrevivem a quedas do
SSH). Logs na workstation enquanto rodam:
`/var/log/rhcsa-lab-provision-<fase>.log`.

## `setup-host.ps1`

Configuração única do host para o provider escolhido. Idempotente: rode de
novo ao mudar `machines.yaml`, o `ip-map` ou a rede do hypervisor.

| Provider | Privilégio | O que faz |
|---|---|---|
| `vmware` (Windows) | administrador | regra de firewall para a porta do Packer; reservas DHCP por MAC em `%ProgramData%\VMware\vmnetdhcp.conf` (com backup); reinicia o `VMnetDHCP` |
| `vmware` (Linux) | root | reservas em `/etc/vmware/<vmnet>/dhcpd/dhcpd.conf`; reinicia com `vmware-networks`; regra no firewalld ou ufw, se ativo |
| `hyperv` | administrador | ativa o Hyper-V (pede reboot), grupo Hyper-V Administrators, switch interno com o Windows no gateway, `New-NetNat`, firewall (Packer, ping, DNS 53/udp) |
| `virtualbox` | nenhum | NAT Network, faixa DHCP `.100-.200`, IP fixo por MAC, redirecionamentos de porta |

Windows elevado: `sudo pwsh -NoProfile -File .\infra\setup-host.ps1`.
Linux: `sudo pwsh -NoProfile -File infra/setup-host.ps1` (só `vmware`).

## Arquivos gerados

| Caminho | Conteúdo |
|---|---|
| `infra/.work/student_key`, `.pub` | par SSH do `student`. A pública vai **dentro da golden**: não apague sem reconstruí-la |
| `infra/.work/known_hosts` | chaves de host das VMs (apagado no `down`) |
| `infra/.work/packer-build.log` | log detalhado do último `image` |
| `infra/.work/logs/` | logs das fases de provisionamento |
| `<VmRoot>/golden/<provider>/` | a golden (VMware: VM com snapshot `base`; Hyper-V: VHDX somente leitura + `rhcsa-netspec.json`; VirtualBox: arquivos da VM registrada com snapshot `base`) |
| `<VmRoot>/lab/<provider>/` | as 3 VMs e o marcador `.provisionado` |

Tudo em `infra/.work/` e o `settings.psd1` são ignorados pelo Git.
