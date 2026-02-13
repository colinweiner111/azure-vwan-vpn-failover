# Azure vWAN ExpressRoute/VPN Failover Lab

> **Lab Purpose**: Demonstrate route preference behavior between ExpressRoute and VPN backup connections, specifically the "failback" issue caused by Longest Prefix Match (LPM) when VPN advertises more-specific routes than ExpressRoute.

This lab uses **two on-prem FRRouting/strongSwan VMs** with dedicated IPsec tunnels to simulate ExpressRoute and VPN backup scenarios, making it deployable without actual ExpressRoute circuits.

## Problem Statement

When using ExpressRoute as the primary path and S2S VPN as backup:

1. **Failover works** ✅ — When ExpressRoute goes down, traffic fails over to VPN
2. **Failback fails** ❌ — When ExpressRoute is restored, traffic stays on VPN

**Root Cause**: If ExpressRoute advertises aggregate prefixes (e.g., `10.0.0.0/16`) and VPN advertises more-specific prefixes (e.g., `10.0.1.0/24`, `10.0.2.0/24`), **Longest Prefix Match (LPM) always selects the VPN route**.

LPM is evaluated before any "prefer ExpressRoute" behavior can help.

## Architecture

```
                              ┌──────────────────────────────────────┐
                              │           Azure vWAN                 │
                              │  ┌────────────────────────────────┐  │
                              │  │         Secured Hub            │  │
                              │  │   (Azure Firewall + Routing    │  │
                              │  │         Intent)                │  │
                              │  │                                │  │
                              │  │    VPN Gateway (ASN 65515)     │  │
                              │  │     Instance 0   Instance 1    │  │
                              │  └────────┬─────────────┬─────────┘  │
                              │           │             │            │
                              │   er-path-site    vpn-backup-site   │
                              │   (conn-er-path)  (conn-vpn-backup)  │
                              │           │             │            │
                              └───────────┼─────────────┼────────────┘
                                          │             │
                  BGP: 10.0.0.0/16        │             │       BGP: 10.0.1.0/24
                    (aggregate)           │             │            10.0.2.0/24
                                          │             │          (more-specific)
                                  IPsec Tunnel      IPsec Tunnel
                                          │             │
                              ┌───────────┴─────────────┴────────────┐
                              │                                      │
                              │        On-Prem VNet (10.0.0.0/16)    │
                              │                                      │
                              │   ┌────────────┐   ┌────────────┐    │
                              │   │ frr-router │   │frr-router- │    │
                              │   │ (ER-PATH)  │   │  backup    │    │
                              │   │            │   │(VPN-BACKUP)│    │
                              │   │ ASN 65001  │   │ ASN 65001  │    │
                              │   │            │   │            │    │
                              │   │ BGP Peer:  │   │ BGP Peer:  │    │
                              │   │192.168.1.12│   │192.168.1.13│    │
                              │   │            │   │            │    │
                              │   │ Advertises │   │ Advertises │    │
                              │   │10.0.0.0/16 │   │10.0.1.0/24 │    │
                              │   │            │   │10.0.2.0/24 │    │
                              │   └────────────┘   └────────────┘    │
                              │                                      │

                              └──────────────────────────────────────┘
```

## Why Two VMs?

Using separate VMs for each tunnel avoids Linux XFRM (IPsec policy) conflicts that occur when multiple tunnels have overlapping traffic selectors on the same host. Each VM has its own dedicated:
- Public IP
- IPsec tunnel to a specific VPN Gateway instance
- BGP session with distinct route advertisements

## Why This Happens

| Route Source | Prefix Advertised | Prefix Length |
|--------------|-------------------|---------------|
| Tunnel 0 ("ER") | 10.0.0.0/16 | /16 |
| Tunnel 1 ("VPN") | 10.0.1.0/24, 10.0.2.0/24 | /24 |

When traffic is destined for `10.0.1.x`:
- Both routes match the destination
- **LPM selects /24 (VPN) over /16 (ER)** — regardless of AS-PATH, Hub Routing Preference, or any other attribute

## The Fix: Route Maps with Summarization

**Solution**: Apply a Route Map to the VPN connection that:

1. **Summarizes routes**: Uses `RoutePrefix Replace` action to aggregate VPN's `/24` routes into a `/16` (matching ExpressRoute)
2. **Prepends AS-path**: Adds `132, 132` to make the VPN route less preferred (longer AS-path)

This ensures:
- Prefix lengths are equal (both `/16`) so LPM no longer favors VPN
- AS-path is longer on VPN, so BGP prefers ExpressRoute when both are up
- **Failover works**: When ER is down, VPN's summarized `/16` provides backup
- **Failback works**: When ER is restored, shorter AS-path wins

### Route Map Configuration

```json
{
  "rules": [
    {
      "name": "rule1-summarize",
      "matchCriteria": [{"matchCondition": "Contains", "routePrefix": ["10.0.0.0/16"]}],
      "actions": [{"type": "Replace", "parameters": [{"routePrefix": ["10.0.0.0/16"]}]}],
      "nextStepIfMatched": "Continue"
    },
    {
      "name": "rule2-prepend",
      "matchCriteria": [{"matchCondition": "Contains", "routePrefix": ["10.0.0.0/16"]}],
      "actions": [{"type": "Add", "parameters": [{"asPath": ["132", "132"]}]}],
      "nextStepIfMatched": "Continue"
    }
  ]
}
```

> **Important - ASN Restrictions**:
> - **Private ASNs (64512-65534)**: ❌ Rejected by Azure Route Maps
> - **Microsoft ASN (12076)**: ❌ Rejected (reserved)
> - **Documentation ASNs (64496-64511)**: ⚠️ May work but not tested
> - **Public ASNs (1-64495)**: ✅ Use any value (e.g., `132`, `174`, `3356`)

## Prerequisites

- **PowerShell 7+** — Install from https://aka.ms/PSWindows (run with `pwsh`)
- **Azure CLI** — Logged in with `az login`
- **Azure Subscription** with Contributor/Owner access
- Sufficient quota for: VPN Gateway (vWAN), Azure Firewall, VMs, Public IPs

## Deployment

```powershell
# Clone the repository
git clone https://github.com/YOUR-USERNAME/vwan-er-vpn-failover-lab.git
cd vwan-er-vpn-failover-lab

# Deploy the lab (takes ~40 minutes without optional components)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3 -VpnPsk "YourPreSharedKey123!"

# Optional: Deploy with Azure Bastion for VM access (adds ~5 min)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3 -VpnPsk "YourPreSharedKey123!" -EnableBastion

# Optional: Deploy with Azure Firewall (adds ~15 min)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3 -VpnPsk "YourPreSharedKey123!" -EnableFirewall

# Optional: Deploy with Route Maps enabled (to demonstrate the fix)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3 -VpnPsk "YourPreSharedKey123!" -EnableRouteMaps
```

### Default Credentials

| Setting | Value |
|---------|-------|
| VM Username | `azureuser` |
| VM Password | (prompted during deployment or via `-AdminPassword`) |
| VPN PSK | (provided via `-VpnPsk` parameter) |

### Deployment Outputs

After deployment, note these key values:

| Resource | Output Name | Description |
|----------|-------------|-------------|
| frr-router | `frrVmPublicIp` | SSH to ER-PATH VM |
| frr-router-backup | `frrVmBackupPublicIp` | SSH to VPN-BACKUP VM |
| VPN GW Instance 0 | `hubVpnGwPublicIp0` | ER-PATH tunnel endpoint |
| VPN GW Instance 1 | `hubVpnGwPublicIp1` | VPN-BACKUP tunnel endpoint |

**BGP Peer IPs** (check with `az network vpn-gateway show`):
- Instance 0: `192.168.1.12` → conn-er-path (ER simulator)
- Instance 1: `192.168.1.13` → conn-vpn-backup (VPN backup)

## Lab Testing Scenarios

### Scenario 1: Observe LPM Behavior (The Problem)

1. SSH to both FRR routers (IPs shown in deployment output)
2. Verify BGP sessions on each:
   ```bash
   # On frr-router (ER-PATH)
   sudo vtysh -c "show ip bgp summary"
   sudo vtysh -c "show ip bgp neighbors 192.168.1.13 advertised-routes"
   
   # On frr-router-backup (VPN-BACKUP)
   sudo vtysh -c "show ip bgp summary"
   sudo vtysh -c "show ip bgp neighbors 192.168.1.12 advertised-routes"
   ```
3. Check vWAN effective routes in Azure Portal:
   - Navigate to **Virtual WAN** → **hub1** → **Routing** → **Effective Routes**
4. **Expected**: The /24 routes from VPN-BACKUP are preferred for 10.0.1.x and 10.0.2.x due to LPM

### Scenario 2: Failover Test

1. On `frr-router-backup`, disable the VPN-BACKUP tunnel:
   ```bash
   sudo ipsec down vpn-backup
   ```
   > **Note**: The tunnel will NOT auto-restart (dpdaction=clear). Use `sudo ipsec up vpn-backup` to bring it back.
2. Wait for BGP to reconverge (~1-2 minutes)
3. Check vWAN effective routes in Portal
4. **Expected**: Traffic now uses the /16 route via ER-PATH (frr-router)

### Scenario 3: Failback Test (The Issue)

1. Re-enable the VPN-BACKUP tunnel:
   ```bash
   sudo ipsec up vpn-backup
   ```
2. Wait for BGP to reconverge
3. Check vWAN routes
4. **Expected (without fix)**: /24 routes return and win due to LPM — no automatic failback to "ER"

### Scenario 4: Apply Route Maps (The Fix)

1. Create the Route Map with summarization + AS-path prepending:
   ```powershell
   .\scripts\add-route-maps.ps1 -ResourceGroupName "vwan-failover-lab" -HubName "hub1"
   ```
   
   Or manually via Azure CLI:
   ```powershell
   # Create route map with two rules
   az network vhub route-map create -g vwan-failover-lab --vhub-name hub1 -n summarize-vpn --rules '[
     {
       "name": "rule1-summarize",
       "matchCriteria": [{"matchCondition": "Contains", "routePrefix": ["10.0.0.0/16"]}],
       "actions": [{"type": "Replace", "parameters": [{"routePrefix": ["10.0.0.0/16"]}]}],
       "nextStepIfMatched": "Continue"
     },
     {
       "name": "rule2-prepend",
       "matchCriteria": [{"matchCondition": "Contains", "routePrefix": ["10.0.0.0/16"]}],
       "actions": [{"type": "Add", "parameters": [{"asPath": ["132", "132"]}]}],
       "nextStepIfMatched": "Continue"
     }
   ]'
   
   # Get route map ID
   $routeMapId = az network vhub route-map show -g vwan-failover-lab --vhub-name hub1 -n summarize-vpn --query id -o tsv
   
   # Apply to VPN-backup connection inbound
   az network vpn-gateway connection update -g vwan-failover-lab --gateway-name hub1-vpngw -n conn-vpn-backup --set routingConfiguration.inboundRouteMap.id=$routeMapId
   ```

2. Wait 2-3 minutes for the route map to take effect
3. Verify routes show VPN-backup with longer AS-path:
   ```powershell
   az network vhub get-effective-routes -g vwan-failover-lab -n hub1 --resource-type VpnConnection --resource-id (az network vpn-gateway connection show -g vwan-failover-lab --gateway-name hub1-vpngw -n conn-vpn-backup --query id -o tsv) -o table
   ```
4. **Expected**: Traffic now prefers ER-PATH (192.168.1.12) due to shorter AS-path

### Scenario 5: Verify Failover with Route Maps

1. Stop the ER-PATH connection:
   ```bash
   # On frr-router
   sudo systemctl stop ipsec frr
   ```
2. Wait 30-60 seconds for BGP timeout
3. Check effective routes on spoke VM:
   ```powershell
   az network nic show-effective-route-table -g vwan-failover-lab -n spoke1-vm-nic -o table | Select-String "10.0.0.0/16"
   ```
4. Test connectivity:
   ```powershell
   az vm run-command invoke -g vwan-failover-lab -n spoke1-vm --command-id RunShellScript --scripts "nc -zv 10.0.1.10 22 -w 5 2>&1"
   ```
5. **Expected**: Route changes to 192.168.1.13 (VPN-backup), connectivity succeeds

### Scenario 6: Verify Failback with Route Maps

1. Restore the ER-PATH connection:
   ```bash
   # On frr-router
   sudo systemctl start ipsec frr
   ```
2. Wait 30-60 seconds for BGP to reconverge
3. Check effective routes again
4. **Expected**: Route returns to 192.168.1.12 (ER-path preferred due to shorter AS-path)

## FRR Router Commands

Connect via SSH:
```bash
# ER-PATH VM (check deployment output for IP)
ssh azureuser@<frr-router-public-ip>

# VPN-BACKUP VM (check deployment output for IP)
ssh azureuser@<frr-router-backup-public-ip>
```

Common commands:
```bash
# Show BGP summary
sudo vtysh -c "show ip bgp summary"

# Show BGP neighbors
sudo vtysh -c "show ip bgp neighbors"

# Show routes advertised to specific neighbor
sudo vtysh -c "show ip bgp neighbors <bgp-peer-ip> advertised-routes"

# Show routes received from neighbor
sudo vtysh -c "show ip bgp neighbors <bgp-peer-ip> received-routes"

# Show all BGP routes
sudo vtysh -c "show ip bgp"

# Show IPsec tunnel status
sudo ipsec status
sudo ipsec statusall

# Restart IPsec tunnel
sudo ipsec restart

# View FRR configuration
sudo vtysh -c "show running-config"
```

## Key Azure Concepts Demonstrated

1. **Longest Prefix Match (LPM)** — Always wins over AS-PATH or route preference
2. **Hub Routing Preference** — Only effective when prefix lengths are equal
3. **AS-PATH Prepending** — Only effective when prefix lengths are equal
4. **vWAN Route Maps** — Filter or modify routes learned from VPN connections
5. **Per-neighbor BGP Policies** — Different routes advertised per BGP peer (via FRRouting)

## Best Practices for Production

Based on this lab scenario, the recommended approach for ExpressRoute/VPN coexistence:

1. **Use Route Map Summarization** — Use `RoutePrefix Replace` to aggregate VPN routes to match ExpressRoute prefix lengths (e.g., `/24` → `/16`)
2. **AS-path Prepending with Public ASN** — Add entries like `132, 132` to VPN routes to deprioritize them (Azure rejects private ASNs and Microsoft's 12076)
3. **Set Hub Routing Preference to ExpressRoute** — When prefixes are equal, this provides additional bias
4. **Configure both VPN Gateway instances** — For VPN backup resiliency
5. **Avoid Filtering** — Don't use `Drop` action on VPN routes, as this breaks failover when ER is down

### Why Summarize Instead of Filter?

| Approach | Failover (ER down) | Failback (ER restored) |
|----------|-------------------|------------------------|
| **Filter /24s** | ❌ No backup route | ✅ ER used |
| **Summarize to /16** | ✅ VPN backup works | ✅ ER preferred (shorter AS-path) |

**Important**: For mission-critical workloads, Microsoft recommends **dual ExpressRoute circuits in different peering locations** rather than ExpressRoute + VPN coexistence.

## Cleanup

```powershell
az group delete -n vwan-failover-lab --yes --no-wait
```

## References

- [Virtual WAN Hub Routing Preference](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing-preference)
- [Virtual WAN Route Maps](https://learn.microsoft.com/azure/virtual-wan/route-maps-about)
- [ExpressRoute and VPN coexistence](https://learn.microsoft.com/azure/expressroute/expressroute-howto-coexist-resource-manager)
- [FRRouting Documentation](https://docs.frrouting.org/)
- [strongSwan Documentation](https://docs.strongswan.org/)

## Credits

Inspired by real-world customer scenarios demonstrating LPM behavior with ExpressRoute/VPN failover.

© MIT Licensed
