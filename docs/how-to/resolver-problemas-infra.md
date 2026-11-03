# Como resolver problemas comuns do `infra/` (VMware, VirtualBox, Hyper-V)

Sintoma → o que fazer. Problemas das VMs e dos exercícios em si (comuns a
todos os backends) estão em [resolver problemas](resolver-problemas.md).
Os itens marcados com **(visto)** aconteceram de verdade durante a
homologação no Windows + VMware.

Logs úteis: `infra/.work/packer-build.log` (build da golden) e
`infra/.work/logs/` (provisionamento, copiados no fim de cada `provision`).

## Preparação do host

### `packer` não é reconhecido logo depois do `winget install` **(visto)**

O terminal foi aberto antes da instalação e não tem o `PATH` novo. Feche e
abra o terminal.

### `Install-Module` falha com "NuGet provider is required" / `TypeInitializationException` **(visto)**

O `Install-Module` (PowerShellGet 2.x) depende de um provider NuGet que
quebra em versões recentes do PowerShell 7. Use o substituto que já vem
nele:

```powershell
Install-PSResource powershell-yaml -Scope AllUsers -TrustRepository
```

### O `powershell-yaml` está instalado, mas "não foi encontrado" **(visto)**

Algo (normalmente um perfil personalizado do PowerShell) reduziu o
`$env:PSModulePath` e tirou dele as pastas de módulos do PowerShell 7. O
`lab.ps1` compensa sozinho, procurando nas pastas padrão. Para corrigir a
causa:

```powershell
$env:PSModulePath -split [IO.Path]::PathSeparator
Select-String -Path $PROFILE -Pattern PSModulePath
```

Se o perfil **atribui** um valor novo ao `PSModulePath`, troque por um que
acrescente ao existente.

### `check` acusa "arquivos com CRLF"

O clone foi feito com `core.autocrlf=true`. Configure o Git e reescreva a
cópia de trabalho (depois de commitar o que tiver pendente):

```powershell
git config --global core.autocrlf false
git rm -r --cached . -q
git reset --hard
```

### `check`: "Endereços sem tradução em infra/ip-map.<provider>.yaml"

Um arquivo do projeto usa um `192.168.56.X` que não está na tabela
(normalmente um exercício novo do upstream). Acrescente o endereço ao
`ip-map` do seu provider.

### `check`: "infra/ip-map.yaml não é mais lido"

A tradução agora é uma por provider. Renomeie para
`infra/ip-map.<provider>.yaml` (por exemplo, `ip-map.vmware.yaml`).

### `status` mostra uma VM "desligada", mas ela está rodando

Ela foi ligada por uma sessão de **administrador**, e a sessão atual é
normal (ou o contrário): o hypervisor separa as VMs por contexto. Rode o
`lab.ps1` sempre numa sessão normal; só o `setup-host.ps1` é elevado.

## Imagem golden (`image`)

### O instalador fica em loop: "failed to fetch kickstart ... Could not connect ... after 0 ms" **(visto)**

A VM de build está **sem rede** (falha instantânea, não timeout). Quando
o instalador desistir, ele cai num shell (`dracut:/#`); rode `ip -4 addr`:
se só aparecer o `lo`, a placa não está na rede do lab.

- VMware: confira no `.vmx` da VM de build se a placa está na VMnet certa
  (`ethernet0.connectionType = "custom"` e `ethernet0.vnet = "<VmNet>"`).
  O template já força isso; o plugin do Packer, sozinho, gerava "bridged".
- Teste o servidor do Packer pelo próprio host enquanto o build roda:
  `Invoke-WebRequest http://<HostIp>:<PackerHttpPort>/ks.cfg`.
- Falha com timeout (e não instantânea) aponta para o firewall do host:
  rode o `setup-host.ps1` de novo.

### O Packer edita a linha errada do menu de boot

O `boot_command` assume o menu GRUB do RHEL 10 em BIOS. Se o menu for
outro, use `BootMenu = 'isolinux'` no `settings.psd1`, ou ajuste o número de
`<down>` em `boot_grub` no template do seu provider
(`infra/packer/<provider>/rhel10-golden.pkr.hcl`).

## Provisionamento (`up` / `provision`)

### "A workstation continua sem mídia no CD" / `mount: /dev/sr0: Can't open blockdev` **(visto)**

O hypervisor não conseguiu abrir a ISO, quase sempre porque o arquivo
**mudou de lugar** depois do build da golden. O VMware, com
`msg.autoAnswer`, liga a VM com o CD vazio sem avisar; a causa fica no
`vmware.log` da VM (`msg.cdromImage.cantOpen ... Could not find the file`),
e o `lab.ps1` mostra essa linha no erro. Corrija `IsoPath` e rode
`provision` de novo: ele religa a workstation com a ISO.

### O registro na Red Hat falha e o Ansible só mostra "censored" **(visto)**

A tarefa usa `no_log` para não expor as credenciais. O erro real fica na
VM:

```bash
sudo grep -iE 'error|fail' /var/log/rhsm/rhsm.log | tail
```

- **`returned status 503`**: o serviço da Red Hat está fora (manutenção ou
  incidente). Confira do próprio host:

  ```powershell
  curl.exe -k -s https://subscription.rhsm.redhat.com/subscription/status
  ```

  Com o serviço normal, a resposta é um JSON com `"mode":"NORMAL"`; fora
  do ar, uma página "We'll be back soon". Quando voltar, rode `provision`
  de novo (VMs já registradas são puladas). Ver também status.redhat.com.
- **Org ID / activation key inválidos**: confira `RhsmOrgId` e
  `RhsmActivationKey` contra console.redhat.com → Activation Keys.

Um `curl` sem `--cacert` dentro da VM reclama de "self-signed certificate
in certificate chain": é normal, o servidor usa a autoridade própria da Red
Hat. Teste com `--cacert /etc/rhsm/ca/redhat-uep.pem`.

### Limite de sistemas da subscription

Ciclos `down`/`up` com as VMs desligadas no `down` deixam sistemas órfãos.
Remova em console.redhat.com → Inventory → Systems.

### `lab: command not found` na workstation, ou hostname `rhcsa-lab-base` **(visto)**

O provisionamento não terminou: o comando `lab` e os hostnames vêm do
`site.yml`. Rode `provision` e veja onde ele para.

### O SSH "caiu" no meio do provisionamento

O playbook roda dentro da workstation via `systemd-run` e continua sem a
sessão; o `lab.ps1` reconecta sozinho. Se ele mesmo foi interrompido, o
log da fase fica em `/var/log/rhcsa-lab-provision-<fase>.log` na
workstation; rode `provision` de novo.

## Por provider

### Hyper-V: "sem acesso ao Hyper-V"

O usuário não está no grupo **Hyper-V Administrators**, ou entrou no
grupo e ainda não saiu/entrou de novo na sessão do Windows. Rode o
`setup-host.ps1` (elevado) e faça logoff/logon.

### Hyper-V: "a golden foi construída com outra rede/MACs"

A golden embute um perfil de rede por MAC do `machines.yaml`. Depois de
mudar MACs ou IPs: `down`, `image -Force`, `up`.

### VirtualBox: VMs não ligam ou ficam muito lentas

- Windows: o Hyper-V está ligado. Desligue-o (`bcdedit /set
  hypervisorlaunchtype off` e reinicie) ou aceite a lentidão.
- Linux: os módulos do KVM estão carregados: `sudo modprobe -r kvm_intel
  kvm_amd kvm`.

### VMware no Linux: nenhuma VM liga

Os módulos `vmmon`/`vmnet` não carregaram (atualização de kernel ou Secure
Boot). Recompile com `sudo vmware-modconfig --console --install-all` e, com
Secure Boot, assine-os com uma chave MOK.
