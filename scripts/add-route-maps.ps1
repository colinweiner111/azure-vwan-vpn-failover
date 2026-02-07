# =============================================================================
# Add Route Maps to vWAN Hub - Quick Script
# =============================================================================
# This script adds Route Maps directly via Azure CLI, much faster than 
# re-running the full Bicep deployment.
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName = "vwan-failover-lab_rg",
    
    [Parameter(Mandatory=$false)]
    [string]$HubName = "hub1"
)

Write-Host "Adding Route Maps to vWAN Hub..." -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host "  Hub: $HubName"

# Create Route Map that filters /24 routes from VPN backup
Write-Host "`nCreating Route Map 'filter-vpn-specifics'..." -ForegroundColor Yellow

az network vhub route-map create `
    --resource-group $ResourceGroupName `
    --vhub-name $HubName `
    --name "filter-vpn-specifics" `
    --rules '[{
        "name": "deny-slash24",
        "matchCriteria": [{
            "matchCondition": "Contains",
            "routePrefix": ["10.0.1.0/24", "10.0.2.0/24"]
        }],
        "actions": [{
            "type": "Drop"
        }],
        "nextStepIfMatched": "Terminate"
    }, {
        "name": "allow-all-else", 
        "matchCriteria": [{
            "matchCondition": "Contains",
            "routePrefix": ["0.0.0.0/0"]
        }],
        "actions": [{
            "type": "Continue"
        }],
        "nextStepIfMatched": "Continue"
    }]'

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ Route Map created successfully!" -ForegroundColor Green
    
    Write-Host "`nNext Steps:" -ForegroundColor Yellow
    Write-Host "1. Go to Azure Portal → Virtual WAN → $HubName → VPN (Site to site)"
    Write-Host "2. Click on 'conn-vpn-backup' connection"
    Write-Host "3. Under 'Propagate routes to route tables', set Inbound Route Map to 'filter-vpn-specifics'"
    Write-Host "4. Save and wait for update (~1-2 min)"
    Write-Host ""
    Write-Host "After applying, the /24 routes will be filtered and only /16 remains."
    Write-Host "Traffic will now prefer the ER-PATH!"
}
else {
    Write-Host "`n✗ Failed to create Route Map" -ForegroundColor Red
    exit 1
}
