# Contrato dos providers

Cada arquivo `<provider>.ps1` desta pasta é carregado (dot-source) pelo
`infra/lab.ps1` e pelo `infra/setup-host.ps1` conforme
`Provider = '<provider>'` em `infra/settings.psd1`. O núcleo
(`infra/lib/LabCommon.ps1` e `infra/lab.ps1`) só fala com o hypervisor
pelas funções abaixo; todo o resto (tradução de IPs, kickstart, SSH,
provisionamento pela workstation, ciclo de vida) é comum.

`$Settings` é o `settings.psd1` carregado; `$Settings.P` é a seção do
provider (ex.: `VMware = @{...}`). `$Machines` é o `machines.yaml` já
traduzido. VMs são identificadas pelo nome em `machines.yaml`
(`workstation`, `servera`, `serverb`).

| Função | Responsabilidade |
|---|---|
| `$script:ProviderLabel` | Nome legível do hypervisor |
| `Test-ProviderEnvironment $S $M` | Itens do `check` (`New-CheckItem ok/warn/fail`) |
| `Test-ProviderHostNeedsElevation` | `$true` se o `setup-host.ps1` precisa de administrador/root |
| `Initialize-ProviderHost $S $M` | Configuração única do host (rede, DHCP, firewall) |
| `Get-ProviderKickstartPackages` | Pacotes de integração acrescentados ao kickstart |
| `Edit-ProviderKickstart $S $M $Ks` | Ajustes finais no kickstart renderizado (ex.: IP fixo na instalação sem DHCP); devolve o texto |
| `Build-ProviderGolden $S $M` | Constrói a golden (Packer) e a deixa pronta para clones |
| `Test-ProviderGolden $S $M` / `Get-ProviderGoldenLabel` | Golden pronta? / onde está |
| `New-ProviderVm $S $M $Name $Spec $IsController` | Clone + CPU/RAM, NICs com os MACs de `machines.yaml`, discos extra na ordem, ISO no CD da controladora |
| `Test-ProviderVmExists` / `Test-ProviderVmRunning` | Estado da VM |
| `Start-ProviderVm $S $Name $Gui` | Liga |
| `Stop-ProviderVm $S $Name $Hard` | Desliga (limpo, ou "na tomada" com `$Hard`) |
| `Remove-ProviderVm $S $Name` | Apaga a VM e seus discos |
| `Set-ProviderVmIso $S $Name $IsoPath` | Com a VM desligada: ISO no CD (`''` = sem mídia) |
| `Get-ProviderIsoFailureReason $S $Name` | Pista de por que o CD ligou vazio |
| `Test-/New-/Restore-ProviderSnapshot $S $Name $Snap` | Snapshot (VM desligada; `New` substitui o existente) |
| `Get-ProviderEndpoint $S $M $Name` | `{Host; Port}` do SSH visto pelo host |
| `Get-ProviderDashboardUrl $S $M` | URL do dashboard vista pelo host |
| `Get-ProviderConsoleHint $S $Name` | Como abrir o console da VM (exercícios de boot) |

Regras que todo provider precisa garantir, porque os exercícios dependem
delas:

- **MACs fixos** de `machines.yaml` (o role `common` renomeia as NICs para
  `ens18`/`ens19` pelo MAC) e o IP de gerência de cada VM já no primeiro
  boot: reserva DHCP por MAC (vmware, virtualbox) ou perfil NM por MAC
  embutido na golden (hyperv, cujo switch interno não tem DHCP).
- **Discos extra brutos com o tamanho exato** em GiB (os exercícios acham
  os discos por tamanho em bytes).
- **Firmware BIOS** (o kickstart cria partição `biosboot`).
- Gateway da rede do lab respondendo a **ping** no endereço `.1` (o
  `examsim-network` confere).
- **Sem virtualização aninhada**: as 3 VMs rodam direto no hypervisor do host.
