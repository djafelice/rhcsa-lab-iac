# Como escolher onde rodar o lab

Use para decidir **em qual máquina física e com qual hypervisor** subir as
3 VMs do lab. Todos os caminhos entregam o mesmo lab: os mesmos
exercícios, o comando `lab`, o dashboard e os simulados. O que muda é a
ferramenta que cria as VMs.

## Os caminhos

| Máquina física | Hypervisor | Ferramenta | Status | Guia |
|---|---|---|---|---|
| Linux | **KVM** (nativo) | `make deploy` (Terraform + Ansible) | testado | [deploy-linux.md](deploy-linux.md) |
| Linux | VMware Workstation | `infra/lab.ps1`, `Provider = 'vmware'` | não testado | [deploy-linux-vmware.md](deploy-linux-vmware.md) |
| Linux | VirtualBox | `infra/lab.ps1`, `Provider = 'virtualbox'` | não testado | [deploy-linux-virtualbox.md](deploy-linux-virtualbox.md) |
| Windows | **Hyper-V** (nativo) | `infra/lab.ps1`, `Provider = 'hyperv'` | não testado | [deploy-windows-hyperv.md](deploy-windows-hyperv.md) |
| Windows | VMware Workstation | `infra/lab.ps1`, `Provider = 'vmware'` | testado | [deploy-windows-vmware.md](deploy-windows-vmware.md) |
| Windows | VirtualBox | `infra/lab.ps1`, `Provider = 'virtualbox'` | não testado | [deploy-windows-virtualbox.md](deploy-windows-virtualbox.md) |

Em todos eles as 3 VMs rodam **direto** no hypervisor da máquina física,
sem virtualização aninhada. A alternativa antiga para Windows, com uma VM
Linux rodando o backend KVM por dentro (aninhada), continua disponível em
[deploy-windows.md](deploy-windows.md).

"Não testado" quer dizer que o código existe, implementa o mesmo contrato
do caminho testado e foi revisado, mas ninguém rodou o ciclo completo
naquele host ainda. O `infra/lab.ps1 check` avisa quando você usa um
desses caminhos. Se testar, relate o resultado numa issue.

**macOS não é suportado.** Os Macs com Apple Silicon (M1 em diante) só
rodam VMs ARM, e o lab é x86_64.

## Como decidir

1. **Linux?** Prefira o KVM: é o caminho original, o mais testado, e não
   exige nenhuma ferramenta além das do guia.
2. **Windows Pro, Enterprise ou Education e nenhum outro hypervisor em uso?**
   O Hyper-V já vem no Windows, sem instalar nada.
3. **Já usa VMware Workstation ou VirtualBox?** Use o mesmo, para não ter
   dois hypervisors disputando o processador.
4. **Windows Home?** Não tem Hyper-V: use VMware Workstation ou VirtualBox.

## Requisitos comuns

- CPU com virtualização (VT-x/AMD-V) ligada na BIOS/UEFI.
- ~8 GB de RAM livres só para as VMs (3 × 2 GB); 16 GB no total é o
  confortável.
- ~60 GB livres em SSD (golden, 3 clones e o mirror flatpak).
- A **DVD ISO** do RHEL 10 x86_64 (não a boot ISO), da sua conta Red Hat.
- Conta **Red Hat Developer Subscription for Individuals** com Org ID e
  activation key ([como obter](../tutorials/primeiro-lab-fim-a-fim.md#2-conta-red-hat-developer--activation-key)).
  O `infra/` ainda não tem modo offline (sem conta).
- Internet durante o provisionamento (registro, pacotes, mirror flatpak).

## Hypervisors no mesmo host

Dois hypervisors disputam o mesmo recurso do processador:

- **Windows com Hyper-V ligado**: o VMware Workstation e o VirtualBox
  passam a rodar por cima dele. Funcionam, mas mais lentos (o VirtualBox
  bem mais).
- **Linux com KVM carregado**: o VirtualBox e o VMware Workstation podem
  não conseguir usar VT-x/AMD-V. Descarregue `kvm_intel`/`kvm_amd` antes
  de usá-los (ver o guia de cada um).

## Diferenças que você vai notar

| | KVM | VMware | Hyper-V | VirtualBox |
|---|---|---|---|---|
| Comando | `make ...` | `infra/lab.ps1 ...` | `infra/lab.ps1 ...` | `infra/lab.ps1 ...` |
| Rede do lab | `192.168.56.0/24` (libvirt) | a rede NAT do VMware, com tradução de IPs se preciso | `192.168.56.0/24` (switch interno) | `192.168.56.0/24` (NAT Network) |
| SSH do host nas VMs | IP direto | IP direto | IP direto | `127.0.0.1:2210-2212` |
| Dashboard | `http://192.168.56.10:8421` | IP da workstation `:8421` | `http://192.168.56.10:8421` | `http://127.0.0.1:8421` |
| Pausar/retomar e snapshot | `make destroy`/`deploy` | `stop`/`start`, `snapshot`/`reset` | idem | idem |

Os comandos do `infra/lab.ps1` estão na [referência](../reference/lab-ps1.md);
o porquê de cada diferença, na
[explicação dos providers](../explanation/infra-hypervisors.md).
