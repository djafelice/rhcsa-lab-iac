# infra/: as 3 VMs do lab direto no hypervisor do host (sem virtualização aninhada)

As 3 VMs do lab criadas **direto** no hypervisor do host, com os mesmos
exercícios, comando `lab`, dashboard e simulados do backend Linux (KVM).

| Host físico | Hypervisor | Como sobe | Estado |
|---|---|---|---|
| Linux | KVM/libvirt (nativo) | backend original: `make deploy` (Terraform + Ansible) | testado pelo autor |
| Linux | VMware Workstation | `infra/`, `Provider = 'vmware'` | planejado |
| Linux | VirtualBox | `infra/`, `Provider = 'virtualbox'` | planejado |
| Windows | Hyper-V (nativo) | `infra/`, `Provider = 'hyperv'` | em desenvolvimento |
| Windows | VMware Workstation | `infra/`, `Provider = 'vmware'` | testado (Windows 11 Pro, Workstation 26H1) |
| Windows | VirtualBox | `infra/`, `Provider = 'virtualbox'` | planejado |

Alternativa do autor para Windows, mantida: uma VM Linux com
virtualização aninhada rodando o backend original
(`docs/how-to/deploy-windows.md`).

Uso: `infra/settings.example.psd1` → `infra/settings.psd1`,
`infra/setup-host.ps1` (administrador, uma vez), `infra/lab.ps1 check`,
`image`, `up`. Comandos: `infra/lab.ps1 help`.

Arquitetura: `lib/LabCommon.ps1` (núcleo comum), `lab.ps1` (comandos),
`providers/<provider>.ps1` (contrato em `providers/README.md`),
`packer/<provider>/` (golden), `provision/` (roda na workstation).

A documentação completa entra em `docs/` quando todos os providers
estiverem prontos.
