# Configuração local dos backends nativos (sem virtualização aninhada).
# Copie para infra/settings.psd1 (nunca commitado, ver .gitignore) e ajuste.
@{
    # Hypervisor do host físico (sem virtualização aninhada):
    #   Windows: 'vmware' (Workstation) | 'hyperv' | 'virtualbox'
    #   Linux:   'vmware' | 'virtualbox'; com KVM use o backend original do
    #            projeto (make deploy), não esta pasta.
    Provider        = 'vmware'

    # ISO DVD oficial do RHEL 10 (x86_64), baixada da sua conta Red Hat.
    # IsoChecksum: 'sha256:<hash da página de download>' ou 'none'.
    IsoPath         = 'D:\rhcsa-lab\iso\rhel-10.2-x86_64-dvd.iso'
    IsoChecksum     = 'none'

    # Raiz das VMs: <VmRoot>/golden/<provider> (persistente) e
    # <VmRoot>/lab/<provider> (efêmeras).
    VmRoot          = 'D:\rhcsa-lab\vms'

    # IP do host na rede do lab (de onde o Packer serve o kickstart) e a
    # porta desse servidor HTTP temporário.
    # Usado pelo vmware (o IP do Windows na VMnet do lab, ex.: 172.16.0.254).
    # O hyperv ignora: lá o Windows é o próprio gateway (192.168.56.1).
    HostIp          = '172.16.0.254'
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
    # Só a seção do Provider escolhido é lida; as outras podem ficar.

    # VMware Workstation. No Linux: InstallDir = '/usr/bin', VmNet = 'vmnet8'
    # (ou a vmnet NAT que você dedicar ao lab).
    VMware = @{
        InstallDir = 'C:\Program Files\VMware\VMware Workstation'
        VmNet      = 'VMnet1'    # rede NAT do VMware usada pelo lab
    }

    # Hyper-V: o setup-host.ps1 cria o switch interno, põe o Windows no
    # gateway (192.168.56.1) e liga o NAT do Windows.
    HyperV = @{
        SwitchName = 'rhcsa-lab'
        NatName    = 'rhcsa-lab'
        GoldenIp   = '192.168.56.250'   # IP só da VM de build da golden
    }

    # VirtualBox 7.x. A NAT Network do lab não é alcançável direto pelo
    # host: SSH e dashboard passam por 127.0.0.1 (portas abaixo).
    # No Linux: InstallDir = '/usr/bin'.
    VirtualBox = @{
        InstallDir    = 'C:\Program Files\Oracle\VirtualBox'
        NatNetwork    = 'rhcsa-lab'
        SshPortBase   = 2210    # workstation=2210, servera=2211, serverb=2212
        DashboardPort = 8421    # http://127.0.0.1:8421
    }
}
