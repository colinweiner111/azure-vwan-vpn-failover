# =============================================================================
# vWAN ExpressRoute/VPN Failover Lab - Deployment Script
# =============================================================================
# This lab demonstrates route preference behavior between two S2S VPN
# connections simulating ExpressRoute (preferred) and VPN backup scenarios.
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
    [ValidateSet('Standard', 'Premium')]
    [string]$FirewallSku = "Standard",

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

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "vWAN ExpressRoute/VPN Failover Lab" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nDeployment Parameters:" -ForegroundColor Yellow
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Location: $Location"
Write-Host "  Admin Username: $AdminUsername"
Write-Host "  Firewall SKU: $FirewallSku"
Write-Host "  Enable Route Maps: $EnableRouteMaps"

Write-Host "`nLab Architecture:" -ForegroundColor Yellow
Write-Host "  - Branch1 ('Simulated ExpressRoute'): Advertises 10.0.0.0/16 aggregate"
Write-Host "  - Branch2 ('VPN Backup'): Advertises 10.0.1.0/24, 10.0.2.0/24 more-specifics"
Write-Host "  - Hub with Azure Firewall and Routing Intent"
Write-Host "  - On-Prem Backend network (shared destination for testing)"
Write-Host "  - 2 Spoke VNets with test VMs"

Write-Host "`nComponents to deploy:" -ForegroundColor Cyan
Write-Host "  - Virtual WAN with 1 secure hub"
Write-Host "  - 6 Virtual Networks (2 Branch, 1 On-Prem, 1 Bastion, 2 Spokes)"
Write-Host "  - 5 Ubuntu VMs (Branch1, Branch2, On-Prem, Spoke1, Spoke2)"
Write-Host "  - 3 VPN Gateways (Branch1, Branch2, Hub)"
Write-Host "  - Azure Firewall with Routing Intent"
Write-Host "  - Azure Bastion for VM access"
if ($EnableRouteMaps) {
    Write-Host "  - Route Maps (for demonstrating the fix)" -ForegroundColor Green
}

Write-Host "`nEstimated deployment time: 45-60 minutes" -ForegroundColor Yellow
Write-Host "  (VPN Gateway provisioning takes ~30 minutes each)`n"

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
                     firewallSku=$FirewallSku `
                     enableRouteMaps=$($EnableRouteMaps.ToString().ToLower())
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n✓ Deployment completed successfully!" -ForegroundColor Green
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host "Lab Testing Instructions" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        
        Write-Host "`nVM IP Addresses:" -ForegroundColor Yellow
        Write-Host "  branch1-er-vm:      10.100.0.x (Branch1 - 'ExpressRoute')"
        Write-Host "  branch2-vpn-vm:     10.200.0.x (Branch2 - 'VPN Backup')"
        Write-Host "  onprem-backend-vm:  10.0.1.10  (Shared on-prem destination)"
        Write-Host "  hub1-spoke1-vm:     172.16.1.x (Azure workload)"
        Write-Host "  hub1-spoke2-vm:     172.16.2.x (Azure workload)"
        
        Write-Host "`nTest Scenario:" -ForegroundColor Yellow
        Write-Host "1. Connect to hub1-spoke1-vm via Bastion"
        Write-Host "2. Ping 10.0.1.10 (on-prem backend) and observe route via traceroute"
        Write-Host "3. Check effective routes in Azure Portal - note the next hop"
        Write-Host "4. Observe that traffic goes via Branch2 (VPN) due to more-specific /24 routes"
        Write-Host "5. Shut down Branch2 VPN connection - traffic should fail over to Branch1"
        Write-Host "6. Restore Branch2 VPN - traffic stays on VPN (failback issue!)"
        
        if ($EnableRouteMaps) {
            Write-Host "`nRoute Maps Deployed:" -ForegroundColor Green
            Write-Host "  - filter-vpn-more-specifics: Denies /24 routes from VPN"
            Write-Host "  - prepend-vpn-routes: Prepends AS-PATH to VPN routes"
            Write-Host "`n  Apply the route map to the Branch2 VPN connection to fix failback:"
            Write-Host "  Portal: vWAN > Hub > VPN > site-branch2-vpn-conn > Inbound Route Map"
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
    # Clear password from memory
    $AdminPassword = $null
    [System.GC]::Collect()
}
