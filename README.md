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

## The Fix: Route Maps

**Solution**: Apply a Route Map to the VPN connection that either:

1. **Option A — Filter more-specifics**: Deny the `/24` routes learned from VPN
2. **Option B — Summarize routes**: Aggregate VPN routes to match ER prefix lengths

This ensures prefix lengths are equal, allowing:
- Hub Routing Preference (ExpressRoute) to take effect
- AS-PATH prepending to influence route selection

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
- Instance 0: typically `192.168.1.13` (ER-PATH)
- Instance 1: typically `192.168.1.12` (VPN-BACKUP)

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

1. Deploy with `-EnableRouteMaps` or manually apply route maps
2. Associate route map with the vpn-backup connection in Portal
3. **Expected**: Traffic now prefers the ER-PATH when both tunnels are active

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

1. **Align prefix advertisement** — Same prefix lengths on both paths
2. **Use vWAN Route Maps** — Filter more-specifics from VPN if needed
3. **Set Hub Routing Preference to ExpressRoute** — When prefixes are equal
4. **AS-PATH prepending on VPN** — Additional bias once prefix lengths aligned
5. **Configure both VPN instances** — For VPN backup resiliency

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
