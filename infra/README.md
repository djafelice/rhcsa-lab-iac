# infra/: as 3 VMs do lab direto no hypervisor do host (sem virtualização aninhada)

As 3 VMs do lab criadas **direto** no hypervisor do host, com os mesmos
exercícios, comando `lab`, dashboard e simulados do backend Linux (KVM).

| Host físico | Hypervisor | Como sobe | Estado |
|---|---|---|---|
| Linux | KVM/libvirt (nativo) | backend original: `make deploy` (Terraform + Ansible) | testado pelo autor |
| Linux | VMware Workstation | `infra/`, `Provider = 'vmware'` | não testado |
| Linux | VirtualBox | `infra/`, `Provider = 'virtualbox'` | não testado |
| Windows | Hyper-V (nativo) | `infra/`, `Provider = 'hyperv'` | não testado |
| Windows | VMware Workstation | `infra/`, `Provider = 'vmware'` | testado (Windows 11 Pro, Workstation 26H1) |
| Windows | VirtualBox | `infra/`, `Provider = 'virtualbox'` | não testado |

Alternativa do autor para Windows, mantida: uma VM Linux com
virtualização aninhada rodando o backend original
(`docs/how-to/deploy-windows.md`).

Documentação:

- [Escolher onde rodar](../docs/how-to/escolher-o-host.md) e o guia de
  deploy de cada cenário (links na tabela de lá)
- [Tutorial Windows + VMware](../docs/tutorials/primeiro-lab-windows-vmware.md)
- [Operar o lab](../docs/how-to/operar-o-lab-infra.md) e
  [resolver problemas](../docs/how-to/resolver-problemas-infra.md)
- Referência: [`lab.ps1`](../docs/reference/lab-ps1.md),
  [configuração](../docs/reference/configuracao-infra.md)
- [Como funciona](../docs/explanation/infra-hypervisors.md); contrato dos
  providers em [`providers/README.md`](providers/README.md)
