# Como fazer o deploy do lab num host Linux

Use quando já sabe o que o lab é e só quer subir as 3 VMs num host Linux
com KVM. Para um passo a passo didático, desde obter a conta Red Hat e a
ISO, siga o [tutorial](../tutorials/primeiro-lab-fim-a-fim.md).

Prefere VMware Workstation ou VirtualBox no Linux? Ver
[escolher onde rodar](escolher-o-host.md).

Caminho testado: host Rocky/RHEL 10 (homologação T1–T13). Fedora e
Ubuntu/Debian usam os mesmos passos com os nomes de pacote abaixo.

## Antes de começar

- CPU com virtualização ligada na BIOS/UEFI: `ls /dev/kvm` precisa existir.
- ~8 GB de RAM livres e ~45 GB de disco livres.
- A **DVD ISO** do RHEL 10 (não a boot ISO), baixada da sua conta Red Hat.
- Para o modo com updates: `RHSM_ORG_ID` e `RHSM_ACTIVATION_KEY` da
  Developer Subscription for Individuals. Sem elas, use o
  [modo offline](deploy-offline.md).

## 1. Instalar as dependências

RHEL/Rocky/Fedora:

```bash
sudo dnf install -y qemu-kvm libvirt virt-install guestfs-tools qemu-img \
  xorriso gettext python3-pyyaml ansible-core git make openssl
sudo dnf install -y dnf-plugins-core
sudo dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
sudo dnf install -y terraform
```

Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst libguestfs-tools \
  qemu-utils xorriso gettext-base python3-yaml ansible-core git make openssl \
  gnupg curl lsb-release
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

Terraform precisa ser ≥ 1.5 (`terraform version`).

Host RHEL **sem subscription** (por exemplo, recém-instalado só para o
lab): o `dnf` não tem repositórios. Monte a própria DVD ISO e use-a como
repositório antes do primeiro `dnf install`:

```bash
sudo mkdir -p /mnt/dvd && sudo mount -o ro /dev/sr0 /mnt/dvd   # ou -o loop <iso>
sudo tee /etc/yum.repos.d/dvd.repo <<'EOF'
[dvd-baseos]
name=DVD BaseOS
baseurl=file:///mnt/dvd/BaseOS
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
[dvd-appstream]
name=DVD AppStream
baseurl=file:///mnt/dvd/AppStream
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
EOF
```

O repositório da HashiCorp continua vindo da internet.

## 2. Liberar o libvirt para o seu usuário

```bash
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
```

Saia e entre de novo na sessão (ou `newgrp libvirt`) para o grupo valer.

Se `virsh -c qemu:///system pool-info default` falhar, crie o pool
`default`:

```bash
sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-build default
sudo virsh pool-start default
sudo virsh pool-autostart default
```

## 3. Clonar e configurar

```bash
git clone git@github.com:dbaricardo/rhcsa-lab-iac.git
cd rhcsa-lab-iac
ansible-galaxy collection install -r ansible/requirements.yml
cp .env.example .env
```

Edite o `.env`. O mínimo é:

| Variável | Valor |
|---|---|
| `RHEL_ISO_PATH` | caminho **absoluto** da DVD ISO |
| `STUDENT_PASSWORD` | senha do usuário `student` nas VMs |
| `RHSM_ORG_ID` / `RHSM_ACTIVATION_KEY` | da subscription (vazias no modo offline) |

Opcionais: `LAB_ROOT_PASSWORD`, `FLATPAK_MIRROR_ENABLED=false` (pula o
download de ~1,6 GB do Flathub), `AI_REVIEW_*`. A lista completa está em
[Configuração](../reference/configuracao.md).

O usuário `qemu` precisa alcançar a ISO **e** o repositório (a imagem
golden nasce em `output/`). Deixe a ISO em `/var/lib/libvirt/images/` e,
se o repositório estiver num `$HOME` com modo `700` (padrão do RHEL),
libere só a travessia:

```bash
setfacl -m u:qemu:--x "$HOME"
```

Sem isso o `virt-install` falha só no final; o `check-env` avisa antes.

## 4. Validar e subir

```bash
make check-env
make deploy           # com subscription
# ou
make deploy-offline   # sem subscription, pacotes só da ISO
```

Na primeira vez o `make deploy` também constrói a imagem golden (~10 min).
Nas próximas ele a reaproveita.

## 5. Conferir

```bash
make status           # estado das VMs e URL do dashboard
make ssh-workstation
lab list
```

Abra o dashboard em `http://192.168.56.10:8421` num navegador do próprio
host.

## Abrir o dashboard de outra máquina

A rede `192.168.56.0/24` é NAT do libvirt e só existe dentro do host. Da
sua máquina, faça um túnel pelo host:

```bash
ssh -L 8421:192.168.56.10:8421 usuario@ip-do-host
```

e abra `http://localhost:8421`.

## Desmontar

```bash
make destroy          # remove VMs, discos e rede; mantém a imagem golden
```

Algo deu errado? Veja [Resolver problemas comuns](resolver-problemas.md).
