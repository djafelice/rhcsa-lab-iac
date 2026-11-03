# Tutorial: do zero ao primeiro exercício no Windows com VMware Workstation

Neste tutorial você vai montar o laboratório RHCSA num **Windows** com o
**VMware Workstation**, sem virtualização aninhada, e resolver um
exercício de ponta a ponta. Não precisa conhecer este repositório, Packer
nem Ansible: siga os passos na ordem.

É o caminho testado do `infra/`. Para Hyper-V, VirtualBox ou VMware no
Linux, os passos são parecidos: veja [escolher o host](../how-to/escolher-o-host.md).

No fim você terá:

- três VMs RHEL 10 (`workstation`, `servera`, `serverb`) no VMware;
- o dashboard de progresso aberto no navegador do Windows;
- o exercício `examsim-grupos` resolvido e corrigido;
- um snapshot para voltar ao lab limpo em um ou dois minutos.

Tempo total: cerca de 1h30, a maior parte esperando instalações.

## 1. Conferir o computador

Você precisa de Windows 10 ou 11, ~16 GB de RAM (as VMs usam 6 GB), ~60 GB
livres num SSD e a virtualização ligada na BIOS/UEFI. Para conferir a
última, abra o Gerenciador de Tarefas → Desempenho → CPU: "Virtualização:
Habilitado".

## 2. Conta Red Hat e ISO

Siga os passos 2 e 3 do
[tutorial do backend KVM](primeiro-lab-fim-a-fim.md#2-conta-red-hat-developer--activation-key):
crie a conta gratuita Red Hat Developer, anote o **Organization ID** e o
nome de uma **activation key**, e baixe a **DVD ISO x86_64** do RHEL 10.

Guarde a ISO num lugar definitivo (por exemplo, `D:\iso\`). O lab usa o
arquivo depois da instalação; se ele mudar de lugar, o provisionamento
para.

O `infra/` ainda não tem modo offline: a conta Red Hat é obrigatória.

## 3. Instalar as ferramentas

Siga a seção **Windows** de [preparar o host](../how-to/preparar-host-infra.md).
Em resumo: PowerShell 7, Git (com `core.autocrlf false`), Packer, o módulo
`powershell-yaml` e, recomendado, o `sudo` do Windows.

Depois instale o **VMware Workstation Pro** (gratuito, no portal da
Broadcom) com as opções padrão.

A partir daqui, use sempre o **PowerShell 7** (`pwsh`) numa sessão normal.

## 4. Escolher a rede do lab

As VMs vão numa rede **NAT** do VMware, que dá internet a elas. Abra o
VMware → Edit → **Virtual Network Editor** → **Change Settings** e
selecione a rede do tipo NAT (normalmente a `VMnet8`). Anote:

- o **Subnet IP** (por exemplo, `192.168.150.0`);
- o **Gateway IP**, em NAT Settings (por exemplo, `192.168.150.2`);
- a faixa do DHCP, em DHCP Settings (por exemplo, `.128` a `.254`).

E o IP do Windows nessa rede:

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -match 'VMnet8'
```

Os exercícios do projeto foram escritos para a rede `192.168.56.0/24`. Se a
sua rede NAT for outra, o lab traduz os endereços sozinho; você só precisa
dizer para onde. Isso fica no passo 6.

## 5. Clonar o repositório

```powershell
cd D:\
git clone https://github.com/<você>/rhcsa-lab-iac.git
cd rhcsa-lab-iac
```

## 6. Configurar

Crie a sua configuração a partir do exemplo:

```powershell
Copy-Item infra\settings.example.psd1 infra\settings.psd1
code infra\settings.psd1
```

Preencha com os seus valores (o resto pode ficar como está):

```powershell
Provider          = 'vmware'
IsoPath           = 'D:\iso\rhel-10.2-x86_64-dvd.iso'
IsoChecksum       = 'sha256:<o hash da página de download>'
VmRoot            = 'D:\rhcsa-lab'
HostIp            = '192.168.150.1'        # o IP do Windows na VMnet8
StudentPassword   = '<uma senha sua>'
RhsmOrgId         = '<Organization ID>'
RhsmActivationKey = '<activation key>'
VMware = @{
    InstallDir = 'C:\Program Files\VMware\VMware Workstation'
    VmNet      = 'VMnet8'
}
```

Se a sua rede **não** é `192.168.56.0/24`, crie a tradução:

```powershell
Copy-Item infra\ip-map.example.yaml infra\ip-map.vmware.yaml
code infra\ip-map.vmware.yaml
```

Troque a rede de destino e os endereços: o `.1` do projeto vira o **Gateway
IP** do NAT, e as VMs recebem IPs **livres e fora da faixa do DHCP**:

```yaml
network:
  from: 192.168.56.0/24
  to: 192.168.150.0/24
addresses:
  192.168.56.1: 192.168.150.2
  192.168.56.10: 192.168.150.10
  192.168.56.20: 192.168.150.11
  192.168.56.30: 192.168.150.12
  192.168.56.91: 192.168.150.91
```

## 7. Preparar o Windows (uma vez)

Este é o único passo com administrador:

```powershell
sudo pwsh -NoProfile -File .\infra\setup-host.ps1
```

Ele libera no firewall a porta que o Packer usa para entregar o kickstart
e reserva, no DHCP do VMware, um IP fixo para cada VM do lab. A saída lista
as três reservas (`workstation`, `servera`, `serverb`).

## 8. Conferir

```powershell
.\infra\lab.ps1 check
```

Tudo deve sair `OK`, exceto a imagem golden, que aparece como `AVISO`
porque ainda não existe. Se algo sair `ERRO`, a mensagem diz o que fazer.

## 9. Construir a imagem golden

```powershell
.\infra\lab.ps1 image
```

Uma janela do VMware abre. Nos primeiros segundos, o Packer "digita" no
menu de boot da ISO o endereço do kickstart; depois a instalação do RHEL
segue sozinha em modo texto, a VM reinicia, o Packer entra por SSH, limpa
a imagem e desliga. Leva 10 a 20 minutos.

Essa VM é a **golden**: a base das três VMs do lab. Não a ligue.

## 10. Subir o lab

```powershell
.\infra\lab.ps1 up
```

O que você vai ver, em ordem:

1. as três VMs clonadas e ligadas (segundos);
2. a conferência de placas de rede e discos, toda em verde;
3. a preparação da workstation, que vira a "controladora" do Ansible;
4. o log do Ansible configurando as três VMs: registro na Red Hat,
   pacotes, mirror, exercícios, comando `lab`, dashboard (20 a 35 min);
5. o snapshot `pronto` e o endereço do dashboard.

## 11. Abrir o dashboard

No navegador do Windows, abra o endereço do fim do `up` (o IP da
workstation, porta `8421`). Ele mostra o catálogo de exercícios e, depois,
o seu progresso.

## 12. Resolver um exercício

Entre na workstation:

```powershell
.\infra\lab.ps1 ssh workstation
```

Dentro dela:

```bash
lab list
lab start examsim-grupos
```

O `lab start` prepara o cenário na `servera` e mostra o enunciado. Resolva
lá:

```bash
ssh root@servera
# ... faça o que o enunciado pede ...
exit
```

De volta à workstation, corrija:

```bash
lab grade examsim-grupos     # corrige sem desfazer; repita quantas vezes quiser
lab finish examsim-grupos    # corrige uma última vez e limpa o cenário
```

Atualize o dashboard: o resultado aparece lá.

## 13. Desligar e voltar amanhã

Saia da workstation (`exit`) e, no Windows:

```powershell
.\infra\lab.ps1 stop
```

Amanhã:

```powershell
.\infra\lab.ps1 start
```

Nada se perde. Quando quiser o lab **limpo** de novo (por exemplo, para
fazer a prova completa `examsim-full` do zero):

```powershell
.\infra\lab.ps1 reset
```

## Pronto

Daqui em diante:

- o dia a dia está em [operar o lab](../how-to/operar-o-lab-infra.md);
- as provas completas: `lab start examsim-full` (24 questões, nota no
  `finish`, aprovação com 17) e `lab start examsim-dinamico` (sorteada);
- se algo falhar, [resolver problemas](../how-to/resolver-problemas-infra.md).
