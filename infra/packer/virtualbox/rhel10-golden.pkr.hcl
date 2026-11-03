# Imagem golden "rhel10-rhcsa-base" para o provider virtualbox (VirtualBox 7.x).
#
# Mesmo kickstart (kickstart/ks.cfg.tpl) e mesmo sysprep (image/finalize.sh)
# dos outros backends. A instalação usa a rede NAT padrão do Packer: o
# kickstart vem do servidor HTTP do Packer via o endereço do host visto
# pela VM ({{ .HTTPIP }}) e o SSH chega por redirecionamento de porta
# automático. A VM fica REGISTRADA no VirtualBox (sem exportar OVF): o
# script tira o snapshot "base" e os clones vinculados partem dele.
#
# Não rode o packer direto: use `infra/lab.ps1 image` (Provider = virtualbox).

packer {
  required_plugins {
    virtualbox = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/virtualbox"
    }
  }
}

variable "iso_path" { type = string }
variable "iso_checksum" { type = string }
variable "output_dir" { type = string }
variable "vm_name" { type = string }
variable "host_ip" { type = string }   # não usado: o VirtualBox fornece o IP do host
variable "http_dir" { type = string }
variable "http_port" { type = number }
variable "student_user" { type = string }
variable "ssh_key_file" { type = string }
variable "finalize_script" { type = string }
variable "headless" { type = bool }
variable "boot_menu" { type = string }

locals {
  ks_url = "http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg"

  boot_grub = [
    "<up><wait>e<wait><down><down><end><wait>",
    " inst.text inst.ks=${local.ks_url}",
    "<leftCtrlOn>x<leftCtrlOff>",
  ]
  boot_isolinux = [
    "<up><wait><tab><wait>",
    " inst.text inst.ks=${local.ks_url}",
    "<enter>",
  ]
}

source "virtualbox-iso" "rhel10" {
  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  vm_name          = var.vm_name
  output_directory = var.output_dir

  guest_os_type        = "RedHat_64"
  firmware             = "bios"
  cpus                 = 2
  memory               = 2048
  disk_size            = 20480
  hard_drive_interface = "sata"
  iso_interface        = "ide"
  guest_additions_mode = "disable"

  # virtio-net em vez da Intel e1000 emulada por padrão: o driver e1000 está
  # descontinuado no RHEL, e o virtio é o recomendado para VMs.
  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--nictype1", "virtio"],
  ]

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

  headless        = var.headless
  keep_registered = true
  skip_export     = true
}

build {
  sources = ["source.virtualbox-iso.rhel10"]

  provisioner "shell" {
    script          = var.finalize_script
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
