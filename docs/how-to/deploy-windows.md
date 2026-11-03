# Como fazer o deploy do lab no Windows

> **Sem virtualização aninhada:** o lab também roda direto no Hyper-V, no
> VMware Workstation ou no VirtualBox do Windows, pelo `infra/`. Ver
> [escolher onde rodar](escolher-o-host.md). Este guia descreve a
> alternativa com o backend KVM dentro de uma VM Linux.

> **Opção B com Hyper-V: testada** em 2026-10-26 (Windows 11 Pro 26200,
> i5-13400, VM RHEL 10.2 Gen2 com 6 vCPU/12 GB): `make deploy-offline`
> terminou com 0 falhas em ~17 min, `lab start/grade/finish` funcionou e o
> dashboard abriu no navegador do Windows pelo túnel SSH.
> **Opção A (WSL2), VMware e VirtualBox: não testados.**

O lab precisa de KVM/libvirt: o Terraform cria as 3 VMs via
`qemu:///system`. O Windows não oferece isso nativamente, então o deploy
roda num Linux que, por sua vez, precisa de **virtualização aninhada**
(VMs dentro de uma VM).

| | Opção A: WSL2 | Opção B: VM Linux |
|---|---|---|
| Requisito | Windows 11 + CPU com nested virtualization no WSL | Hyper-V, VMware Workstation ou VirtualBox 7 com nested |
| Consumo | menor | maior (uma VM a mais) |
| Previsibilidade | menor (WSL tem quirks) | igual à homologação |

Nos dois casos a máquina física precisa de ~16 GB de RAM (12 GB para o
Linux) e ~100 GB livres.

## Opção A: WSL2

### 1. Ligar a virtualização aninhada no WSL

Crie ou edite `%UserProfile%\.wslconfig`:

```ini
[wsl2]
nestedVirtualization=true
memory=12GB
processors=6
```

Sem `memory`, o WSL usa só metade da RAM física e as 3 VMs podem não
caber.

### 2. Instalar o Ubuntu e ligar o systemd

No PowerShell:

```powershell
wsl --install -d Ubuntu-24.04
```

Dentro do Ubuntu, crie `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

De volta ao PowerShell:

```powershell
wsl --shutdown
```

### 3. Conferir o KVM

Abra o Ubuntu de novo e rode:

```bash
ls -l /dev/kvm
```

Se `/dev/kvm` não existir, a CPU ou a versão do Windows não expõe
virtualização aninhada ao WSL: use a opção B.

### 4. Fazer o deploy

Siga o [deploy em Linux](deploy-linux.md) a partir do passo 1, na variante
Ubuntu/Debian. Dois cuidados:

- Guarde **o repositório e a ISO dentro do WSL** (por exemplo `~/` ou
  `/var/lib/libvirt/images/`), não em `/mnt/c/...`. O disco do Windows é
  lento pelo WSL e o usuário `qemu` não consegue lê-lo.
- Para copiar a ISO baixada no Windows:
  `sudo cp /mnt/c/Users/<voce>/Downloads/rhel-10*-dvd.iso /var/lib/libvirt/images/`

### 5. Abrir o dashboard no navegador do Windows

O Windows não enxerga a rede `192.168.56.0/24`, que só existe dentro do
WSL. Dentro do Ubuntu, na pasta do repositório, abra um túnel e deixe-o
rodando:

```bash
ssh -N -i output/student_key -o StrictHostKeyChecking=no \
  -L 8421:192.168.56.10:8421 student@192.168.56.10
```

O WSL repassa o `localhost` para o Windows: abra
`http://localhost:8421` no navegador.

Os exercícios continuam pelo terminal do Ubuntu: `make ssh-workstation`.

## Opção B: VM Linux com virtualização aninhada

### 1. Criar a VM

- Sistema: Rocky Linux 10 (o host da homologação), RHEL 10, Fedora ou
  Ubuntu 24.04.
- 6 vCPUs, 10–12 GB de RAM, disco de 100 GB.
- Rede em modo NAT ou bridge, com internet.

### 2. Ligar a virtualização aninhada (com a VM desligada)

Hyper-V (PowerShell como administrador). Exemplo completo, criando a VM
Gen2 já com tudo que o lab precisa:

```powershell
$vm = 'rhcsa-host'
New-VM -Name $vm -Generation 2 -MemoryStartupBytes 12GB `
  -NewVHDPath "C:\Hyper-V\$vm.vhdx" -NewVHDSizeBytes 100GB -SwitchName 'Default Switch'
Set-VMMemory    -VMName $vm -DynamicMemoryEnabled $false        # memória fixa: nested não aceita dinâmica
Set-VMProcessor -VMName $vm -Count 6 -ExposeVirtualizationExtensions $true
Set-VMFirmware  -VMName $vm -SecureBootTemplate MicrosoftUEFICertificateAuthority  # senão Linux não boota
Add-VMDvdDrive  -VMName $vm -Path 'C:\caminho\rhel-10.x-x86_64-dvd.iso'
Set-VMFirmware  -VMName $vm -FirstBootDevice (Get-VMDvdDrive -VMName $vm)
Start-VM $vm
```

Instale o Linux pelo console do Hyper-V. No RHEL, o particionamento
automático limita a raiz a 70 GB — suficiente para o lab (~45 GB).

Depois da instalação, mantenha a DVD ISO conectada na VM: ela vira o
repositório de pacotes de um RHEL sem subscription e a fonte do
`RHEL_ISO_PATH` (`sudo cp /dev/sr0 /var/lib/libvirt/images/rhel-10-dvd.iso`),
sem precisar copiar o arquivo pela rede.

Para descobrir o IP da VM (a `Default Switch` usa DHCP e o IP pode mudar
depois de reiniciar o Windows):

```powershell
(Get-VMNetworkAdapter -VMName $vm).IPAddresses
```

VMware Workstation: *VM Settings → Processors →* marque
**Virtualize Intel VT-x/EPT or AMD-V/RVI**.

VirtualBox 7: *Configurações → Sistema → Processador →* marque
**Habilitar VT-x/AMD-V aninhado**. Com o Hyper-V ativo no Windows, o
VirtualBox perde desempenho e pode não expor o KVM; nesse caso prefira o
Hyper-V.

### 3. Conferir o KVM

Dentro da VM:

```bash
ls -l /dev/kvm
grep -cE 'vmx|svm' /proc/cpuinfo   # precisa ser > 0
```

### 4. Fazer o deploy

Siga o [deploy em Linux](deploy-linux.md) inteiro dentro da VM. Num RHEL
recém-instalado, atenção a dois pontos do guia: usar o DVD como
repositório (sem subscription) e o `setfacl` no `$HOME`.

### 5. Abrir o dashboard no navegador do Windows

Do PowerShell (o OpenSSH já vem no Windows 10/11):

```powershell
ssh -N -L 8421:192.168.56.10:8421 <usuario>@<ip-da-vm-linux>
```

deixe a janela aberta e acesse `http://localhost:8421`. Se a porta 8421 já
estiver em uso no Windows, troque o primeiro número (ex.: `18421:...`).

## Desmontar

Dentro do Linux (WSL ou VM): `make destroy`. Para liberar o disco do WSL
inteiro: `wsl --unregister Ubuntu-24.04` (apaga tudo dessa distribuição).

Algo deu errado? Veja [Resolver problemas comuns](resolver-problemas.md).
