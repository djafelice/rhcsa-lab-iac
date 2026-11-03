# Como fazer o deploy no Windows com Hyper-V

> **Status: não testado.** O provider `hyperv` implementa o mesmo contrato
> do provider `vmware` (testado) e foi revisado, mas ninguém rodou o ciclo
> completo ainda. Pontos de maior risco: a rede do instalador
> (`ip=...:eth0:none` no menu de boot) e o firewall do Windows. Se testar,
> relate numa issue.

As 3 VMs rodam direto no Hyper-V, sem virtualização aninhada, num switch
interno dedicado em que o **Windows é o gateway** (`192.168.56.1`) e faz
NAT para a internet, o mesmo papel do host no backend KVM.

## Antes de começar

- **Windows 10/11 Pro, Enterprise ou Education** (o Home não tem Hyper-V).
- Ferramentas comuns instaladas: [preparar o host](preparar-host-infra.md).
- [Requisitos comuns](escolher-o-host.md#requisitos-comuns).
- A rede `192.168.56.0/24` livre no Windows. A rede host-only padrão do
  VirtualBox usa exatamente essa faixa: se o VirtualBox estiver instalado,
  remova o adaptador host-only ou mude a faixa dele.
- Se usa VMware Workstation ou VirtualBox, saiba que eles ficam mais lentos
  com o Hyper-V ligado ([por quê](escolher-o-host.md#hypervisors-no-mesmo-host)).

## 1. Configurar o lab

```powershell
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
Copy-Item infra\settings.example.psd1 infra\settings.psd1
code infra\settings.psd1
```

```powershell
Provider          = 'hyperv'
IsoPath           = 'D:\iso\rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<hash>'
VmRoot            = 'D:\rhcsa-lab'
StudentPassword   = '<sua senha>'
RhsmOrgId         = '<Org ID>'
RhsmActivationKey = '<activation key>'
HyperV = @{
    SwitchName = 'rhcsa-lab'
    NatName    = 'rhcsa-lab'
    GoldenIp   = '192.168.56.250'
}
```

O `HostIp` é ignorado neste provider (o Windows é o próprio gateway). Não
crie `ip-map.hyperv.yaml`: o switch dedicado usa a rede original.

## 2. Configurar o host (como administrador)

```powershell
sudo pwsh -NoProfile -File .\infra\setup-host.ps1
```

Na primeira vez ele **ativa o recurso Hyper-V** e pede para reiniciar.
Reinicie e rode o mesmo comando de novo. Na segunda vez ele:

- adiciona o seu usuário ao grupo **Hyper-V Administrators** (para o
  `lab.ps1` rodar sem administrador);
- cria o switch interno `rhcsa-lab` e coloca o Windows em `192.168.56.1`;
- cria o NAT do Windows (`New-NetNat`) para `192.168.56.0/24`;
- libera no firewall, só nessa interface: a porta do Packer, o **ping** (o
  `examsim-network` confere que o gateway responde) e a porta 53 UDP (o
  Windows não é DNS; liberar a porta faz ele recusar na hora, e as VMs
  passam para o `8.8.8.8` sem esperar o timeout).

**Saia da sessão do Windows e entre de novo** para o grupo valer.

## 3. Conferir

```powershell
.\infra\lab.ps1 check
```

## 4. Construir a imagem golden (uma vez)

```powershell
.\infra\lab.ps1 image
```

A VM de build é Geração 1 (BIOS, como o kickstart exige). Como o switch
não tem DHCP, o Packer passa ao instalador um IP fixo de build
(`GoldenIp`) no menu de boot. Acompanhe na janela: a linha editada deve
terminar com `inst.ks=http://192.168.56.1:8519/ks.cfg ip=192.168.56.250::...:eth0:none`.

No fim, a golden recebe um perfil de rede **por MAC** de cada VM do
`machines.yaml`, já com o IP dela: é assim que os clones sobem com o IP
certo sem DHCP. Mudou MACs ou IPs no `machines.yaml`? O `check` avisa, e
a golden precisa ser reconstruída (`image -Force`, depois do `down`).

## 5. Subir o lab e estudar

```powershell
.\infra\lab.ps1 up
.\infra\lab.ps1 ssh workstation
```

Dashboard: `http://192.168.56.10:8421`. Console de uma VM (para o
exercício de recuperar a senha de root): Gerenciador do Hyper-V ou
`vmconnect.exe localhost rhcsa-lab-serverb`.

Dia a dia: [operar o lab](operar-o-lab-infra.md). Problemas:
[resolver problemas](resolver-problemas-infra.md).

## Se o instalador não achar o kickstart

O nome da placa no instalador pode não ser `eth0`. Depois de algumas
tentativas o instalador cai num shell de emergência (`dracut:/#`) na
janela da VM: rode `ip -br link` para ver o nome real e troque `eth0` em
`boot_args` no `infra/packer/hyperv/rhel10-golden.pkr.hcl`.
