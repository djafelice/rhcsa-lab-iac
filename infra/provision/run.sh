#!/bin/bash
# Roda NA WORKSTATION, como root, disparado por `infra\lab.ps1 provision`
# via systemd-run (o playbook sobrevive a uma queda da sessão SSH do Windows).
#
# A workstation é a controladora Ansible temporária dos backends nativos: o
# Windows não roda Ansible, então o lab.ps1 envia para cá a cópia do
# repositório (com os IPs traduzidos por infra\ip-map.yaml, se houver), a
# chave do student e as variáveis da subscription, e chama este script.
#
#   run.sh unpack   (rodado de /tmp/rhcsa-provision-upload) instala em
#                   /root/rhcsa-provision o repositório, a chave e este script.
#   run.sh prepare  monta a ISO do CD-ROM, instala ansible-core (da ISO) e as
#                   collections, e aplica SÓ a parte de rede do role common na
#                   própria workstation (.link ens18 + perfil NM), sem o
#                   reboot. O lab.ps1 reinicia a workstation em seguida.
#   run.sh site     roda o ansible/site.yml original contra as 3 VMs.
#   run.sh cleanup  remove ansible-core, collections, chave e segredos.
#
# Por que o "prepare": o role common reinicia cada VM para renomear a NIC
# (ens18/ens19). A controladora não pode reiniciar a si mesma no meio do
# playbook. Aplicando antes os mesmos arquivos que o role geraria, no
# site.yml a tarefa não vê mudança e não reinicia a workstation.
#
# Saída: /var/log/rhcsa-lab-provision-<fase>.log; código de saída em
# /var/log/rhcsa-lab-provision-<fase>.rc (lido pelo lab.ps1).
set -uo pipefail

PHASE="${1:?uso: run.sh unpack|prepare|site|cleanup}"
BASE=/root/rhcsa-provision
REPO="$BASE/repo"
ISO_MNT=/mnt/rhcsa-lab-iso
RC_FILE="/var/log/rhcsa-lab-provision-${PHASE}.rc"
MARK_ANSIBLE="$BASE/.ansible-core-instalado-pelo-lab"

export HOME=/root
export ANSIBLE_CONFIG="$REPO/ansible/ansible.cfg"
export ANSIBLE_COLLECTIONS_PATH="$BASE/collections"
export ANSIBLE_FORCE_COLOR=0
export ANSIBLE_NOCOLOR=1
export PYTHONUNBUFFERED=1

trap 'echo $? > "$RC_FILE"' EXIT

log() { printf '\n==> %s\n' "$*"; }

# shellcheck disable=SC1091
[ -f "$BASE/lab.env" ] && . "$BASE/lab.env"

mount_iso() {
  mkdir -p "$ISO_MNT"
  if ! mountpoint -q "$ISO_MNT"; then
    log "Montando a ISO do CD-ROM em $ISO_MNT"
    mount -o ro /dev/sr0 "$ISO_MNT" || {
      echo "ERRO: não consegui montar /dev/sr0. A ISO do RHEL está conectada ao CD da workstation?" >&2
      lsblk -o NAME,SIZE,TYPE,LABEL /dev/sr0 >&2 || true
      exit 1
    }
  fi
  for d in BaseOS AppStream; do
    [ -f "$ISO_MNT/$d/repodata/repomd.xml" ] || {
      echo "ERRO: $ISO_MNT/$d/repodata ausente (a ISO é a DVD completa?)" >&2
      exit 1
    }
  done
}

# dnf só com os repositórios da ISO (a workstation ainda não está registrada).
dnf_iso() {
  dnf -y -q --disablerepo='*' \
    --repofrompath="lab-iso-baseos,file://$ISO_MNT/BaseOS" \
    --repofrompath="lab-iso-appstream,file://$ISO_MNT/AppStream" \
    --setopt=lab-iso-baseos.gpgcheck=0 \
    --setopt=lab-iso-appstream.gpgcheck=0 \
    "$@"
}

phase_prepare() {
  set -e
  mount_iso

  if ! rpm -q ansible-core >/dev/null 2>&1; then
    log 'Instalando ansible-core a partir da ISO'
    dnf_iso install ansible-core
    touch "$MARK_ANSIBLE"
  fi
  ansible --version | head -1

  log 'Instalando as collections (ansible/requirements.yml)'
  ansible-galaxy collection install -r "$REPO/ansible/requirements.yml" -p "$ANSIBLE_COLLECTIONS_PATH"

  log 'Validando labs/catalog.json (equivale ao make catalog)'
  python3 "$REPO/scripts/build-catalog.py"

  cd "$REPO"
  log 'Aplicando a rede (ens18) na própria workstation, sem reboot'
  ansible-playbook -i output/inventory.yml ansible/infra-bootstrap-ws.yml \
    -e common_net_reboot=false

  log 'Regenerando initramfs com os .link (o reboot vem do Windows)'
  dracut -f --regenerate-all
}

phase_site() {
  set -e
  mount_iso
  cd "$REPO"
  log 'ansible-playbook ansible/site.yml (o mesmo do make provision)'
  ansible-playbook -i output/inventory.yml ansible/site.yml \
    -e "lab_iso_url=file://$ISO_MNT"
}

phase_cleanup() {
  if mountpoint -q "$ISO_MNT"; then umount "$ISO_MNT" || true; fi
  rmdir "$ISO_MNT" 2>/dev/null || true
  if [ -f "$MARK_ANSIBLE" ]; then
    log 'Removendo ansible-core (não existe na workstation do homelab)'
    dnf -y -q remove ansible-core || true
  fi
  rm -rf /root/.ansible
  # Último passo: apaga a chave, os segredos e a cópia do repositório.
  cd /
  rm -rf "$BASE"
}

phase_unpack() {
  set -e
  local up=/tmp/rhcsa-provision-upload
  rm -rf "$BASE"
  install -d -m 0700 "$BASE"
  # -m: ignora as datas do Windows (evita "time stamp in the future").
  tar --no-same-owner -m -xzf "$up/repo.tgz" -C "$BASE"
  install -m 0600 "$up/student_key" "$BASE/student_key"
  install -m 0700 "$up/run.sh" "$BASE/run.sh"
  # O checkout no Windows não guarda o bit +x: restaura pela lista do Git.
  (cd "$REPO" && xargs -r -d '\n' -a "$up/executables.txt" chmod +x --)
  rm -rf "$up"
  echo "Repositório em $REPO ($(find "$REPO" -type f | wc -l) arquivos)."
}

case "$PHASE" in
  unpack) phase_unpack ;;
  prepare) phase_prepare ;;
  site) phase_site ;;
  cleanup) phase_cleanup ;;
  *) echo "fase desconhecida: $PHASE" >&2; exit 2 ;;
esac
