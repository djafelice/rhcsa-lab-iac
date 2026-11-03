# Configuração local dos backends nativos (sem virtualização aninhada).
# Copie para infra/settings.psd1 (nunca commitado, ver .gitignore) e ajuste.
@{
    # Hypervisor do host físico (sem virtualização aninhada):
    #   Windows: 'vmware' (Workstation) | 'hyperv' | 'virtualbox'
    #   Linux:   'vmware' | 'virtualbox' (em desenvolvimento); com KVM use
    #            o backend original do projeto (make deploy).
    Provider        = 'vmware'

    # ISO DVD oficial do RHEL 10 (x86_64), baixada da sua conta Red Hat.
    # IsoChecksum: 'sha256:<hash da página de download>' ou 'none'.
    IsoPath         = 'D:\rhcsa-lab\iso\rhel-10.2-x86_64-dvd.iso'
    IsoChecksum     = 'none'

    # Raiz das VMs: <VmRoot>/golden (persistente) e <VmRoot>/lab (efêmeras).
    VmRoot          = 'D:\rhcsa-lab\vms'

    # IP do host na rede do lab (de onde o Packer serve o kickstart) e a
    # porta desse servidor HTTP temporário.
    HostIp          = '192.168.56.254'
    PackerHttpPort  = 8519

    # true = constrói a golden sem janela. Na 1a vez, deixe false.
    PackerHeadless  = $false

    # Menu de boot da ISO: 'grub' (padrão do RHEL 10) ou 'isolinux'.
    BootMenu        = 'grub'

    # Senha do usuário "student" nas VMs (uso local de laboratório).
    StudentPassword = 'troque-esta-senha'

    # Subscription Red Hat Developer: registro no provisionamento,
    # desregistro no `down`.
    RhsmOrgId         = ''
    RhsmActivationKey = ''

    # Senha de root (console). Vazia = root só por chave (padrão do projeto).
    RootPassword      = ''

    # Mirror flatpak (~1,6 GB a cada provisionamento). $false acelera, mas
    # desliga examsim-flatpak e os dyn-flatpak-*.
    FlatpakMirror     = $true

    # Gravação dos terminais (pré-requisito da revisão por IA).
    RecordingEnabled  = $false

    # ---------------------------------------------- seção de cada provider ---
    VMware = @{
        InstallDir = 'C:\Program Files\VMware\VMware Workstation'
        VmNet      = 'VMnet1'    # rede NAT do VMware usada pelo lab
    }
}
