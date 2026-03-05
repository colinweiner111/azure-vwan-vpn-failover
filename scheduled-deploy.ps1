# =============================================================================
# Scheduled Deployment - vWAN ExpressRoute/VPN Failover Lab
# Scheduled for: Sunday 3/1/2026 at 5:00 PM
# =============================================================================

$logFile = "C:\_Demo\azure-vwan-vpn-failover\deploy-log-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
Start-Transcript -Path $logFile -Append

try {
    Write-Host "Starting scheduled deployment at $(Get-Date)" -ForegroundColor Cyan

    & "C:\_Demo\azure-vwan-vpn-failover\deploy-bicep.ps1" `
        -ResourceGroupName "vwan-failover-lab" `
        -Location "westus3" `
        -AdminUsername "azureuser" `
        -AdminPassword "Pcm4loanPcm4loan" `
        -VpnPsk "Pcm4loanPcm4loan" `
        -FirewallSku "Standard" `
        -EnableFirewall `
        -EnableBastion `
        -EnableRouteMaps

    Write-Host "Deployment finished at $(Get-Date)" -ForegroundColor Green
}
catch {
    Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript
}
