# Como fazer o deploy no Linux com VMware Workstation

> **Status: não testado.** O provider `vmware` foi testado no Windows; no
> Linux muda só a parte do host (caminhos, DHCP em `/etc/vmware/`,
> firewall). Ninguém rodou o ciclo completo no Linux ainda. Se testar,
> relate numa issue.

Se o seu Linux pode usar KVM, prefira o [caminho original](deploy-linux.md).
Este guia é para quem já usa o VMware Workstation no Linux e não quer dois
hypervisors disputando o processador.

## Antes de começar

- Ferramentas comuns instaladas: [preparar o host](preparar-host-infra.md#linux).
- [Requisitos comuns](escolher-o-host.md#requisitos-comuns).
- Módulos do KVM descarregados enquanto usar o VMware:

  ```bash
  lsmod | grep -E '^kvm_(intel|amd)' && sudo modprobe -r kvm_intel kvm_amd kvm
  ```

## 1. Instalar o VMware Workstation Pro

Baixe o `.bundle` para Linux no portal da Broadcom e instale:

```bash
sudo sh VMware-Workstation-Full-*.bundle
```

Os módulos do kernel (`vmmon`, `vmnet`) são compilados no primeiro uso e a
cada atualização de kernel. Com **Secure Boot** ligado, eles precisam ser
assinados com uma chave sua (MOK) para carregar; sem isso, o VMware não
liga nenhuma VM.

## 2. Escolher a rede NAT do lab

Abra o Virtual Network Editor (`sudo vmware-netcfg`) e anote, da rede NAT
(normalmente a `vmnet8`):

| Dado | Onde | Exemplo |
|---|---|---|
| Subnet | Subnet IP | `192.168.150.0` |
| Gateway | NAT Settings → Gateway IP | `192.168.150.2` |
| IP do host | `ip -4 addr show vmnet8` | `192.168.150.1` |
| Faixa DHCP | DHCP Settings | `.128` a `.254` |

Como o projeto usa `192.168.56.0/24` com gateway em `.1`, crie
`infra/ip-map.vmware.yaml` a partir do `infra/ip-map.example.yaml`, com a
sua subnet e o gateway (exemplo completo no
[guia do Windows](deploy-windows-vmware.md#2-escolher-a-rede-nat-do-lab)).
Os IPs das VMs precisam estar livres e fora da faixa DHCP.

## 3. Configurar o lab

```bash
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
cp infra/settings.example.psd1 infra/settings.psd1
```

Edite `infra/settings.psd1`:

```powershell
Provider          = 'vmware'
IsoPath           = '/home/<você>/iso/rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<hash>'
VmRoot            = '/home/<você>/rhcsa-lab'
HostIp            = '192.168.150.1'
StudentPassword   = '<sua senha>'
RhsmOrgId         = '<Org ID>'
RhsmActivationKey = '<activation key>'
VMware = @{
    InstallDir = '/usr/bin'
    VmNet      = 'vmnet8'
}
```

## 4. Configurar o host (uma vez, como root)

```bash
sudo pwsh -NoProfile -File infra/setup-host.ps1
```

Grava as reservas DHCP em `/etc/vmware/vmnet8/dhcpd/dhcpd.conf` (com
backup), reinicia a rede do VMware (`vmware-networks`) e, se houver
firewalld ou ufw ativo, libera a porta do Packer para a subnet do lab.

## 5. Conferir, construir a golden e subir

```bash
pwsh infra/lab.ps1 check
pwsh infra/lab.ps1 image
pwsh infra/lab.ps1 up
pwsh infra/lab.ps1 ssh workstation
```

Rode como o **seu usuário**, não como root: a chave SSH do lab e as VMs
ficam no seu nome.

Dia a dia: [operar o lab](operar-o-lab-infra.md). Problemas:
[resolver problemas](resolver-problemas-infra.md).
