# Azure vWAN ExpressRoute/VPN Failover Lab

> **Lab Purpose**: Demonstrate route preference behavior between ExpressRoute and VPN backup connections, specifically the "failback" issue caused by Longest Prefix Match (LPM) when VPN advertises more-specific routes than ExpressRoute.

This lab uses **two S2S VPN connections** to simulate ExpressRoute and VPN backup scenarios, making it deployable without actual ExpressRoute circuits.

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
                              │  └───────────┬───────────┬────────┘  │
                              │              │           │           │
                              │   ┌──────────┴───┐   ┌───┴─────────┐ │
                              │   │  Spoke1      │   │   Spoke2    │ │
                              │   │ 172.16.1.0/24│   │172.16.2.0/24│ │
                              │   │     VM       │   │     VM      │ │
                              │   └──────────────┘   └─────────────┘ │
                              └──────────────────────────────────────┘
                                          │              │
                    S2S VPN #1            │              │         S2S VPN #2
                ("ExpressRoute")          │              │        ("VPN Backup")
                  ASN 65010               │              │          ASN 65020
                                          │              │
                ┌─────────────────────────┼──────────────┼────────────────────────┐
                │                         │              │                        │
        ┌───────▼───────┐                 │              │              ┌─────────▼─────┐
        │   Branch1     │                 │              │              │   Branch2     │
        │  (Sim. ER)    │                 │              │              │ (VPN Backup)  │
        │ 10.100.0.0/16 │                 │              │              │ 10.200.0.0/16 │
        │               │                 │              │              │               │
        │ Advertises:   │                 │              │              │ Advertises:   │
        │ 10.0.0.0/16   │◄────────────────┼──────────────┼──────────────┤ 10.0.1.0/24   │
        │ (aggregate)   │                 │              │              │ 10.0.2.0/24   │
        └───────┬───────┘                 │              │              │(more-specific)│
                │                         │              │              └───────┬───────┘
                │                         │              │                      │
                │         ┌───────────────┴──────────────┴───────────────┐      │
                │         │                                              │      │
                └─────────┤           On-Prem Backend                    ├──────┘
                          │            10.0.0.0/16                       │
                          │                                              │
                          │    ┌───────────┐      ┌───────────┐          │
                          │    │10.0.1.0/24│      │10.0.2.0/24│          │
                          │    │    VM     │      │  (subnet) │          │
                          │    │ 10.0.1.10 │      │           │          │
                          │    └───────────┘      └───────────┘          │
                          └──────────────────────────────────────────────┘
```

## Why This Happens

| Route Source | Prefix Advertised | Prefix Length |
|--------------|-------------------|---------------|
| Branch1 ("ER") | 10.0.0.0/16 | /16 |
| Branch2 ("VPN") | 10.0.1.0/24 | /24 |

When traffic is destined for `10.0.1.10`:
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
- Sufficient quota for: VPN Gateways, Azure Firewall, VMs

## Deployment

```powershell
# Clone the repository
git clone https://github.com/YOUR-USERNAME/vwan-er-vpn-failover-lab.git
cd vwan-er-vpn-failover-lab

# Deploy the lab (takes ~45-60 minutes)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3

# Optional: Deploy with Route Maps enabled (to demonstrate the fix)
.\deploy-bicep.ps1 -ResourceGroupName vwan-failover-lab -Location westus3 -EnableRouteMaps
```

## Lab Testing Scenarios

### Scenario 1: Observe LPM Behavior (The Problem)

1. Connect to `hub1-spoke1-vm` via Azure Bastion (IP-based connection)
2. Ping the on-prem backend: `ping 10.0.1.10`
3. Run traceroute: `traceroute 10.0.1.10`
4. Check effective routes in Azure Portal for the spoke VM NIC
5. **Expected**: Traffic goes via Branch2 (VPN) even though both connections are active

### Scenario 2: Failover Test

1. In Azure Portal, disable the Branch2 VPN connection (site-branch2-vpn-conn)
2. Wait for BGP to reconverge (~2-3 minutes)
3. Re-run `ping` and `traceroute` from spoke VM
4. **Expected**: Traffic now goes via Branch1 ("ExpressRoute")

### Scenario 3: Failback Test (The Issue)

1. Re-enable the Branch2 VPN connection
2. Wait for BGP to reconverge
3. Re-run `ping` and `traceroute`
4. **Expected (without fix)**: Traffic stays on Branch2 (VPN) — no automatic failback to "ER"

### Scenario 4: Apply Route Maps (The Fix)

1. Deploy with `-EnableRouteMaps` or manually apply route maps
2. Associate `filter-vpn-more-specifics` route map with the Branch2 VPN connection:
   - Portal: vWAN → Hub → VPN (Site to site) → site-branch2-vpn-conn → Edit → Inbound Route Map
3. Wait for route table to update
4. **Expected**: Traffic now prefers Branch1 ("ExpressRoute") when both are active

## VM Network Information

| VM Name | VNet | Subnet | Expected IP |
|---------|------|--------|-------------|
| branch1-er-vm | branch1-er | main (10.100.0.0/24) | 10.100.0.x |
| branch2-vpn-vm | branch2-vpn | main (10.200.0.0/24) | 10.200.0.x |
| onprem-backend-vm | onprem-backend | main (10.0.1.0/24) | 10.0.1.10 |
| hub1-spoke1-vm | hub1-spoke1 | main (172.16.1.0/27) | 172.16.1.x |
| hub1-spoke2-vm | hub1-spoke2 | main (172.16.2.0/27) | 172.16.2.x |

## Key Azure Concepts Demonstrated

1. **Longest Prefix Match (LPM)** — Always wins over AS-PATH or route preference
2. **Hub Routing Preference** — Only effective when prefix lengths are equal
3. **AS-PATH Prepending** — Only effective when prefix lengths are equal
4. **vWAN Route Maps** — Filter or modify routes learned from VPN connections
5. **BGP Route Advertisement** — Different prefix lengths cause route selection issues

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

## Cost Considerations

This lab deploys cost-incurring resources:
- 3 VPN Gateways (VpnGw1 SKU)
- 1 Azure Firewall (Standard SKU by default)
- 1 Azure Bastion (Standard SKU)
- 5 VMs (Standard_DS1_v2)

**Delete resources when done testing to avoid ongoing charges.**

## References

- [Virtual WAN Hub Routing Preference](https://learn.microsoft.com/azure/virtual-wan/about-virtual-hub-routing-preference)
- [Virtual WAN Route Maps](https://learn.microsoft.com/azure/virtual-wan/route-maps-about)
- [ExpressRoute and VPN coexistence](https://learn.microsoft.com/azure/expressroute/expressroute-howto-coexist-resource-manager)
- [BGP Best Path Selection](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-faq#how-does-the-virtual-hub-in-a-virtual-wan-select-the-best-path-for-a-route-from-multiple-hubs)

## Credits

Inspired by real-world customer scenarios and based on the [azure-vwan-secure-hub-lab](https://github.com/colinweiner111/azure-vwan-secure-hub-lab) repository.

© MIT Licensed
