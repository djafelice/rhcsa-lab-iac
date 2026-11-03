# Imagem golden "rhel10-rhcsa-base" para o provider hyperv (Hyper-V).
#
# Mesmo kickstart (kickstart/ks.cfg.tpl) e mesmo sysprep (image/finalize.sh)
# dos outros backends. Diferenças do Hyper-V:
#   - VM Geração 1 (BIOS): o kickstart cria partição biosboot, não ESP;
#   - o switch interno do lab não tem DHCP: a instalação usa um IP fixo
#     (golden_ip), passado ao instalador pelo boot_command (ip=) e ao
#     sistema instalado pelo kickstart (ajustado em providers/hyperv.ps1);
#   - no fim, net_script troca esse IP de build por um perfil de rede por
#     MAC de gerência de machines.yaml (os clones sobem com o IP certo).
# Resultado: só o VHDX em <output_dir>/Virtual Hard Disks/, disco-pai dos
# clones diferenciais.
#
# Não rode o packer direto: use `infra/lab.ps1 image` (Provider = hyperv).

packer {
  required_plugins {
    hyperv = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "iso_path" { type = string }
variable "iso_checksum" { type = string }
variable "output_dir" { type = string }
variable "vm_name" { type = string }
variable "host_ip" { type = string }
variable "http_dir" { type = string }
variable "http_port" { type = number }
variable "student_user" { type = string }
variable "ssh_key_file" { type = string }
variable "finalize_script" { type = string }
variable "headless" { type = bool }
variable "boot_menu" { type = string }
variable "switch_name" { type = string }
variable "golden_ip" { type = string }
variable "gateway" { type = string }
variable "netmask" { type = string }
variable "net_script" { type = string }

locals {
  ks_url = "http://${var.host_ip}:${var.http_port}/ks.cfg"
  # Rede do instalador: ip=<ip>::<gw>:<máscara>:<hostname>:<nic>:none.
  # No Hyper-V a NIC sintética aparece como eth0 no instalador.
  boot_args = "inst.text inst.ks=${local.ks_url} ip=${var.golden_ip}::${var.gateway}:${var.netmask}:rhcsa-lab-base:eth0:none nameserver=8.8.8.8"

  boot_grub = [
    "<up><wait>e<wait><down><down><end><wait>",
    " ${local.boot_args}",
    "<leftCtrlOn>x<leftCtrlOff>",
  ]
  boot_isolinux = [
    "<up><wait><tab><wait>",
    " ${local.boot_args}",
    "<enter>",
  ]
}

source "hyperv-iso" "rhel10" {
  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  vm_name          = var.vm_name
  output_directory = var.output_dir

  generation            = 1
  cpus                  = 2
  memory                = 2048
  enable_dynamic_memory = false
  disk_size             = 20480
  switch_name           = var.switch_name

  http_directory = var.http_dir
  http_port_min  = var.http_port
  http_port_max  = var.http_port

  boot_wait    = "10s"
  boot_command = var.boot_menu == "isolinux" ? local.boot_isolinux : local.boot_grub

  communicator         = "ssh"
  ssh_host             = var.golden_ip
  ssh_username         = var.student_user
  ssh_private_key_file = var.ssh_key_file
  ssh_timeout          = "60m"

  shutdown_command = "sudo shutdown -P now"
  shutdown_timeout = "10m"

  headless    = var.headless
  skip_export = true
}

build {
  sources = ["source.hyperv-iso.rhel10"]

  provisioner "shell" {
    scripts         = [var.finalize_script, var.net_script]
    execute_command = "sudo -E bash '{{ .Path }}'"
  }
}
