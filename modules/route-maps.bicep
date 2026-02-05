// =============================================================================
// Route Maps Module - Fix for LPM Override Issue
// =============================================================================
// This module demonstrates how to use vWAN Route Maps to solve the
// ExpressRoute/VPN failback issue described in the customer scenario.
//
// PROBLEM:
// - "ExpressRoute" (branch1) advertises aggregates like 10.0.0.0/16
// - "VPN Backup" (branch2) advertises more-specifics like 10.0.1.0/24, 10.0.2.0/24
// - LPM (Longest Prefix Match) causes VPN to win even when ER is available
// - Traffic doesn't fail back to ER after ER is restored
//
// SOLUTION:
// Apply a Route Map to the VPN connection (branch2) that:
// - Option A: Filters/denies the more-specific routes from VPN
// - Option B: Summarizes VPN routes to match ER aggregate lengths
//
// This ensures prefix lengths are equal, allowing:
// - Hub Routing Preference (ExpressRoute) to take effect
// - AS-PATH prepending to influence route selection
// =============================================================================

param hubName string

// =============================================================================
// Route Map: Filter VPN More-Specifics
// =============================================================================
// This route map denies the more-specific /24 routes learned from the VPN
// backup connection, allowing only aggregate routes (or no routes from this
// specific prefix range). This ensures ER's aggregate wins via LPM equality.
// =============================================================================
resource hub 'Microsoft.Network/virtualHubs@2023-11-01' existing = {
  name: hubName
}

resource routeMapFilterVpn 'Microsoft.Network/virtualHubs/routeMaps@2023-11-01' = {
  parent: hub
  name: 'filter-vpn-more-specifics'
  properties: {
    rules: [
      {
        name: 'deny-onprem-more-specifics'
        matchCriteria: [
          {
            matchCondition: 'Contains'
            routePrefix: [
              '10.0.1.0/24'
              '10.0.2.0/24'
            ]
          }
        ]
        actions: [
          {
            type: 'Drop'
          }
        ]
        nextStepIfMatched: 'Terminate'
      }
      {
        name: 'allow-all-other'
        matchCriteria: [
          {
            matchCondition: 'Contains'
            routePrefix: [
              '0.0.0.0/0'
            ]
          }
        ]
        actions: [
          {
            type: 'Continue'
          }
        ]
        nextStepIfMatched: 'Continue'
      }
    ]
  }
}

// =============================================================================
// Route Map: AS-PATH Prepend for VPN (Alternative/Additional)
// =============================================================================
// This route map prepends additional AS numbers to routes learned from VPN,
// making them less preferred when prefix lengths are equal.
// =============================================================================
resource routeMapPrependVpn 'Microsoft.Network/virtualHubs/routeMaps@2023-11-01' = {
  parent: hub
  name: 'prepend-vpn-routes'
  properties: {
    rules: [
      {
        name: 'prepend-as-path'
        matchCriteria: [
          {
            matchCondition: 'Contains'
            routePrefix: [
              '10.0.0.0/8'  // Match all 10.x.x.x routes
            ]
          }
        ]
        actions: [
          {
            type: 'Replace'
            parameters: [
              {
                asPath: [
                  '65020'  // Prepend the VPN ASN multiple times
                  '65020'
                  '65020'
                ]
              }
            ]
          }
        ]
        nextStepIfMatched: 'Continue'
      }
    ]
  }
}

// =============================================================================
// Outputs
// =============================================================================
output routeMapFilterId string = routeMapFilterVpn.id
output routeMapPrependId string = routeMapPrependVpn.id

// =============================================================================
// USAGE INSTRUCTIONS
// =============================================================================
// After deploying this module, you need to manually associate the route map
// with the VPN connection in the Azure portal or via CLI:
//
// 1. Navigate to Virtual WAN > Hub > VPN (Site to site) > site-branch2-vpn-conn
// 2. Edit the connection
// 3. Under "Inbound Route Map", select "filter-vpn-more-specifics"
// 4. Save
//
// CLI equivalent:
// az network vpn-gateway connection update \
//   --gateway-name hub1-vpngw \
//   --name site-branch2-vpn-conn \
//   --resource-group vwan-failover-lab \
//   --associated-inbound-routemap /subscriptions/<sub>/resourceGroups/vwan-failover-lab/providers/Microsoft.Network/virtualHubs/hub1/routeMaps/filter-vpn-more-specifics
// =============================================================================
