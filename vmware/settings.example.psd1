# Configuração local do backend VMware.
# Copie para vmware\settings.psd1 (nunca commitado, ver .gitignore) e ajuste.
@{
    # Pasta de instalação do VMware Workstation (vmrun.exe, vmware-vdiskmanager.exe).
    VmwareDir       = 'C:\Program Files\VMware\VMware Workstation'

    # ISO DVD oficial do RHEL 10 (x86_64), baixada da sua conta Red Hat.
    # IsoChecksum: 'sha256:<hash da página de download>' ou 'none' para pular.
    IsoPath         = 'D:\rhcsa-lab\iso\rhel-10.0-x86_64-dvd.iso'
    IsoChecksum     = 'none'

    # Raiz das VMs: <VmRoot>\golden (persistente) e <VmRoot>\lab (efêmeras).
    VmRoot          = 'D:\rhcsa-lab\vms'

    # Rede VMware do lab (NAT) e o IP do Windows nessa rede.
    VmNet           = 'VMnet1'
    HostIp          = '172.16.0.254'

    # Porta fixa do servidor HTTP do Packer que entrega o kickstart à VM.
    # Liberada no firewall do Windows pelo vmware\setup-host.ps1.
    PackerHttpPort  = 8519

    # true = constrói a golden sem abrir a janela da VM. Na primeira vez,
    # deixe false para acompanhar a instalação.
    PackerHeadless  = $false

    # Menu de boot da ISO: 'grub' (padrão do RHEL 10) ou 'isolinux'.
    # Só mude se o boot_command não conseguir editar o menu (ver README).
    BootMenu        = 'grub'

    # Senha do usuário "student" em todas as VMs (uso apenas local/lab).
    StudentPassword = 'troque-esta-senha'

    # Subscription Red Hat Developer: cada VM se registra no provisionamento
    # e é desregistrada no `lab.ps1 down`. Gere em
    # https://console.redhat.com/insights/connector/activation-keys
    RhsmOrgId         = ''
    RhsmActivationKey = ''

    # Senha de root das 3 VMs (login de console, como no homelab).
    # Vazia = root travado, só entra por chave (padrão do projeto).
    RootPassword      = ''

    # Mirror flatpak "myrepo" (~1,6 GB baixados do Flathub a cada provisionamento).
    # $false = provisionamento mais rápido, mas examsim-flatpak e dyn-flatpak-* não funcionam.
    FlatpakMirror     = $true

    # Gravação dos terminais em /var/log/rhcsa-rec (pré-requisito da revisão por IA).
    RecordingEnabled  = $false
}
