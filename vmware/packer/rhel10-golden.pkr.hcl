# Imagem golden "rhel10-rhcsa-base" para o backend VMware Workstation.
#
# Equivale a scripts/build-image.sh do backend Linux (virt-install +
# virt-customize): instala o RHEL 10 desassistido com o MESMO kickstart
# (kickstart/ks.cfg.tpl, renderizado e adaptado por vmware\lib\LabCommon.ps1)
# e roda o MESMO sysprep (image/finalize.sh). A VM resultante fica desligada
# e serve de base para os clones vinculados das 3 VMs do lab.
#
# Não rode o packer direto: use `.\vmware\lab.ps1 image`, que gera a chave,
# renderiza o kickstart, preenche estas variáveis e tira o snapshot "base".

packer {
  required_plugins {
    vmware = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/vmware"
    }
  }
}

variable "iso_path" { type = string }
variable "iso_checksum" { type = string }
variable "output_dir" { type = string }
variable "vm_name" { type = string }
variable "network" { type = string }          # ex.: VMnet1
variable "host_ip" { type = string }          # IP do Windows na rede da VM
variable "http_dir" { type = string }         # pasta com o ks.cfg renderizado
variable "http_port" { type = number }
variable "student_user" { type = string }
variable "ssh_key_file" { type = string }
variable "finalize_script" { type = string }
variable "headless" { type = bool }
variable "boot_menu" { type = string }        # grub | isolinux

locals {
  ks_url = "http://${var.host_ip}:${var.http_port}/ks.cfg"

  # RHEL 10 em BIOS mostra um menu GRUB com "Test this media & install" já
  # selecionado. <up> vai para "Install Red Hat Enterprise Linux", "e" abre a
  # edição, duas descidas chegam à linha "linux ...", <end> vai ao fim dela,
  # e Ctrl+X dá boot com os parâmetros acrescentados.
  boot_grub = [
    "<up><wait>e<wait><down><down><end><wait>",
    " inst.text inst.ks=${local.ks_url}",
    "<leftCtrlOn>x<leftCtrlOff>",
  ]

  # Alternativa para menu isolinux (tela azul/preta com texto centralizado):
  # <tab> abre a linha de parâmetros da entrada selecionada.
  boot_isolinux = [
    "<up><wait><tab><wait>",
    " inst.text inst.ks=${local.ks_url}",
    "<enter>",
  ]
}

source "vmware-iso" "rhel10" {
  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  vm_name          = var.vm_name
  output_directory = var.output_dir

  # Hardware igual ao das VMs do homelab: 2 vCPU, 2 GiB, disco do SO SCSI
  # de 20 GiB, firmware BIOS (o kickstart cria partição biosboot, não ESP).
  guest_os_type        = "rhel9-64"
  version              = "21"
  cpus                 = 2
  memory               = 2048
  disk_size            = 20480
  disk_adapter_type    = "pvscsi"
  disk_type_id         = "0"
  network              = var.network
  network_adapter_type = "vmxnet3"

  vmx_data = {
    "firmware"       = "bios"
    # Disco primeiro: no reboot pós-instalação a VM não volta ao instalador.
    # Com o disco ainda vazio (1o boot), cai para o CD normalmente.
    "bios.bootOrder" = "hdd,cdrom"
  }

  http_directory = var.http_dir
  http_port_min  = var.http_port
  http_port_max  = var.http_port

  boot_wait    = "10s"
  boot_command = var.boot_menu == "isolinux" ? local.boot_isolinux : local.boot_grub

  communicator         = "ssh"
  ssh_username         = var.student_user
  ssh_private_key_file = var.ssh_key_file
  ssh_timeout          = "60m"

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "10m"

  headless = var.headless
}

build {
  sources = ["source.vmware-iso.rhel10"]

  # Mesmo sysprep do backend Linux, aqui rodado com a VM ligada (lá roda
  # offline via virt-customize): restorecon, remove chaves de host SSH,
  # limpa logs de instalação e zera o machine-id.
  provisioner "shell" {
    script          = var.finalize_script
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
