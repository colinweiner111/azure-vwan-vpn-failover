# =============================================================================
# vWAN ExpressRoute/VPN Failover Lab - Deployment Script
# =============================================================================
# This lab demonstrates route preference behavior using a single on-prem
# FRRouting/strongSwan VM with two IPsec tunnels to simulate ExpressRoute
# (preferred) and VPN backup scenarios.
#
# REQUIREMENTS: PowerShell 7+ (run with 'pwsh', not 'powershell')
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "vwan-failover-lab",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westus3",
    
    [Parameter(Mandatory=$false)]
    [string]$AdminUsername = "azureuser",
    
    [Parameter(Mandatory=$false)]
    [string]$AdminPassword,
    
    [Parameter(Mandatory=$false)]
    [string]$VpnPsk,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet('Standard', 'Premium')]
    [string]$FirewallSku = "Standard",

    [Parameter(Mandatory=$false)]
    [switch]$EnableFirewall = $false,

    [Parameter(Mandatory=$false)]
    [switch]$EnableBastion = $false,

    [Parameter(Mandatory=$false)]
    [switch]$EnableRouteMaps = $false
)

# Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "ERROR: This script requires PowerShell 7+. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Write-Host "Please run this script using 'pwsh' instead of 'powershell'" -ForegroundColor Yellow
    Write-Host "Install PowerShell 7: https://aka.ms/PSWindows" -ForegroundColor Cyan
    exit 1
}

# Check if logged into Azure
Write-Host "Checking Azure login..." -ForegroundColor Cyan
$account = az account show 2>$null | ConvertFrom-Json
if (!$account) {
    Write-Host "Not logged in. Please login to Azure..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host "Using subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Prompt for password if not provided
if (-not $AdminPassword) {
    $SecurePassword = Read-Host -Prompt "Enter VM admin password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $AdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

# Prompt for VPN PSK if not provided
if (-not $VpnPsk) {
    $SecurePsk = Read-Host -Prompt "Enter VPN Pre-Shared Key" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePsk)
    $VpnPsk = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "vWAN ExpressRoute/VPN Failover Lab" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nDeployment Parameters:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Location: $Location"
Write-Host "  Admin Username: $AdminUsername"
Write-Host "  Firewall: $(if ($EnableFirewall) { $FirewallSku } else { 'Disabled' })"
Write-Host "  Bastion: $(if ($EnableBastion) { 'Enabled' } else { 'Disabled' })"
Write-Host "  Route Maps: $EnableRouteMaps"

Write-Host "`nLab Architecture:" -ForegroundColor Yellow
Write-Host "  Hub1 (westus3) + Hub2 (eastus2) + Hub3 (westus) in single vWAN"
Write-Host "  - 2 FRR VMs with 6 total IPsec tunnels (2 per hub):"
Write-Host "    * frr-router (ER-PATH): 3 tunnels to Hub1/Hub2/Hub3 VPN GW Instance 0"
Write-Host "      Advertises aggregate 10.0.0.0/16 via BGP"
Write-Host "    * frr-router-backup (VPN): 3 tunnels to Hub1/Hub2/Hub3 VPN GW Instance 1"
Write-Host "      Advertises specific /24 routes via BGP"
Write-Host "  - LPM causes /24 routes to win over /16 aggregate"
Write-Host "  - Demonstrates failover/failback behavior across all 3 hubs"

Write-Host "`nComponents to deploy:" -ForegroundColor Cyan
Write-Host "  - Virtual WAN with Hub1 (westus3) + Hub2 (eastus2) + Hub3 (westus)"
Write-Host "  - On-Prem VNet (10.0.0.0/16)"
Write-Host "  - 2 FRR/strongSwan Router VMs (Ubuntu) - 6 tunnels total (2 per hub)"
Write-Host "  - 3 vWAN VPN Gateways (2 instances each)"
Write-Host "  - Spoke1/Spoke2 connected to Hub1"
Write-Host "  - Spoke3/Spoke4 connected to Hub2"
Write-Host "  - Spoke5/Spoke6 connected to Hub3"
if ($EnableBastion) {
    Write-Host "  - Azure Bastion for VM access"
}
if ($EnableFirewall) {
    Write-Host "  - Azure Firewall ($FirewallSku SKU)" -ForegroundColor Yellow
}
if ($EnableRouteMaps) {
    Write-Host "  - Route Maps (for demonstrating the fix)" -ForegroundColor Green
}

$extraTime = 0
if ($EnableFirewall) { $extraTime += 15 }
if ($EnableBastion) { $extraTime += 5 }
$estimatedMin = 35 + $extraTime
$estimatedMax = 55 + $extraTime
Write-Host "`nEstimated deployment time: $estimatedMin-$estimatedMax minutes" -ForegroundColor Yellow
Write-Host "  (3 VPN Gateways deploy in parallel: ~30 min)`n"

$deploymentName = "vwan-failover-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    Write-Host "Starting deployment..." -ForegroundColor Cyan
    
    az deployment sub create `
        --name $deploymentName `
        --location $Location `
        --template-file "$PSScriptRoot\main.bicep" `
        --parameters resourceGroupName=$ResourceGroupName `
                     location=$Location `
                     adminUsername=$AdminUsername `
                     adminPassword=$AdminPassword `
                     vpnPsk=$VpnPsk `
                     firewallSku=$FirewallSku `
                     enableFirewall=$($EnableFirewall.ToString().ToLower()) `
                     enableBastion=$($EnableBastion.ToString().ToLower()) `
                     enableRouteMaps=$($EnableRouteMaps.ToString().ToLower())
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n✓ Deployment completed successfully!" -ForegroundColor Green
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Lab Testing Instructions" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`nFRR Router VMs:" -ForegroundColor Yellow
        Write-Host "  frr-router (ER-PATH):     3 tunnels to Hub1/Hub2/Hub3 Instance 0"
        Write-Host "    Advertises 10.0.0.0/16 aggregate via BGP"
        Write-Host "  frr-router-backup (VPN):  3 tunnels to Hub1/Hub2/Hub3 Instance 1"
        Write-Host "    Advertises 10.0.1.0/24, 10.0.2.0/24 specifics via BGP"
        if ($EnableBastion) {
            Write-Host "  Access: Azure Bastion in onprem-vnet"
        } else {
            Write-Host "  Access: SSH to public IP (see deployment outputs)"
        }
        
        Write-Host "`nUseful FRR Commands:" -ForegroundColor Yellow
        Write-Host "  sudo vtysh -c 'show ip bgp summary'       # BGP status"
        Write-Host "  sudo vtysh -c 'show ip bgp'               # BGP routes"
        Write-Host "  sudo ipsec status                         # IPsec tunnel status"
        
        Write-Host "`nTest Scenario:" -ForegroundColor Yellow
        Write-Host "1. Connect to each FRR VM (SSH or Bastion)"
        Write-Host "2. Verify IPsec tunnels up: sudo ipsec status"
        Write-Host "3. Verify BGP sessions up: sudo vtysh -c 'show ip bgp summary'"
        Write-Host "4. Check vWAN effective routes in Azure Portal"
        Write-Host "5. Observe /24 routes (VPN) win over /16 (ER) due to LPM"
        Write-Host "6. Disable VPN tunnel: sudo ipsec down azure-vwan (on backup VM)"
        Write-Host "7. Traffic fails over to ER path (/16 route)"
        Write-Host "8. Re-enable VPN tunnel: sudo ipsec up azure-vwan"
        Write-Host "9. Traffic stays on ER path (failback issue!)"
        
        if ($EnableRouteMaps) {
            Write-Host "`nRoute Maps Deployed:" -ForegroundColor Green
            Write-Host "  Apply to the VPN backup connection to fix failback"
        }
        else {
            Write-Host "`nTo deploy Route Maps (the fix):" -ForegroundColor Yellow
            Write-Host "  .\deploy-bicep.ps1 -EnableRouteMaps"
        }
        
        Write-Host "`nCleanup:" -ForegroundColor Yellow
        Write-Host "  az group delete -n $ResourceGroupName --yes --no-wait"
    }
    else {
        Write-Host "`n✗ Deployment failed" -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "`n✗ Deployment error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    # Clear sensitive data from memory
    $AdminPassword = $null
    $VpnPsk = $null
    [System.GC]::Collect()
}
