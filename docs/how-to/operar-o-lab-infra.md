# Como operar o lab no dia a dia (`infra/`: VMware, VirtualBox, Hyper-V)

Tarefas comuns depois do primeiro `up`. Vale para os três providers do
`infra/`; com KVM, ver [operar o lab](operar-o-lab.md). Lista completa de
comandos na [referência do `lab.ps1`](../reference/lab-ps1.md).

Windows: `.\infra\lab.ps1 <comando>`. Linux: `pwsh infra/lab.ps1 <comando>`.
Sempre numa sessão **normal** (sem administrador).

## Os três níveis

| Quero… | Comando | Perde o que foi feito? | Tempo |
|---|---|---|---|
| parar por hoje e continuar amanhã | `stop`, depois `start` | não | ~1 min |
| voltar ao lab recém-provisionado | `reset` | **sim**, tudo depois do snapshot | 1-2 min |
| um lab totalmente novo | `down`, depois `up` | **sim**, tudo | ~30 min |

## Ver o estado

```powershell
.\infra\lab.ps1 status
```

Mostra cada VM (ligada, desligada, não criada), o endereço do SSH, o
snapshot `pronto`, se o lab foi provisionado, a golden e o dashboard.

## Entrar numa VM

```powershell
.\infra\lab.ps1 ssh workstation     # ou servera / serverb
```

Entra como `student` (`sudo` sem senha). Os exercícios se fazem a partir
da workstation (`lab start ...`); de lá, `ssh root@servera` entra direto.

## Parar e continuar

```powershell
.\infra\lab.ps1 stop
.\infra\lab.ps1 start
```

Desligamento limpo (com fallback para desligar "na tomada" após 90 s).
Nada se perde: exercício em andamento, arquivos e histórico do dashboard.
`up` num lab já provisionado faz o mesmo que `start`.

## Voltar ao estado limpo

```powershell
.\infra\lab.ps1 reset
```

Volta as 3 VMs ao snapshot `pronto`, tirado automaticamente no fim do
provisionamento. Ideal para refazer o `examsim-full` do zero. Pede
confirmação (`-Force` pula), porque descarta **tudo** desde o snapshot,
inclusive o histórico do dashboard, que mora na workstation.

## Mudar o ponto de partida do reset

```powershell
.\infra\lab.ps1 snapshot
```

Desliga as VMs, substitui o snapshot `pronto` pelo estado atual e religa.

## Reaplicar o Ansible

Depois de mudar um role, um exercício em `labs/` ou o `settings.psd1`:

```powershell
.\infra\lab.ps1 provision
```

Envia de novo a cópia do repositório, roda o `site.yml` e refaz o snapshot
`pronto`. É idempotente.

## Destruir e recriar

```powershell
.\infra\lab.ps1 down
.\infra\lab.ps1 up
```

O `down` **desregistra cada VM da Red Hat** antes de apagá-la (para os
ciclos não acumularem sistemas na sua conta) e mantém a golden. Se as VMs
estiverem desligadas, ele não consegue desregistrar: confira em
console.redhat.com → Inventory → Systems e remova as sobras.

## Reconstruir a golden

Necessário depois de mudar `kickstart/ks.cfg.tpl`, `image/finalize.sh`, a
ISO, a `StudentPassword` ou, no Hyper-V, MACs/IPs do `machines.yaml`:

```powershell
.\infra\lab.ps1 down
.\infra\lab.ps1 image -Force
.\infra\lab.ps1 up
```

## Trocar de hypervisor

Mude `Provider` no `settings.psd1` (e preencha a seção do novo). Cada
provider tem a sua golden, o seu lab e os seus snapshots em
`<VmRoot>\golden\<provider>` e `<VmRoot>\lab\<provider>`: nada se mistura.
Lembre que hypervisors disputam o processador
([detalhes](escolher-o-host.md#hypervisors-no-mesmo-host)).

## Abrir o console de uma VM

Necessário no exercício `examsim-rootpw-recover-node2` (interromper o boot
da serverb no GRUB), porque o `up` liga as VMs sem janela:

| Provider | Como |
|---|---|
| vmware | VMware Workstation → File → Open → `<VmRoot>\lab\vmware\serverb\serverb.vmx` |
| hyperv | Gerenciador do Hyper-V, ou `vmconnect.exe localhost rhcsa-lab-serverb` |
| virtualbox | VirtualBox → `rhcsa-lab-serverb` → **Mostrar** |

Ou ligue já com janelas: `.\infra\lab.ps1 start -Gui`.
