// =============================================================================
// VPN Module - Dual Branch VPN Connections
// =============================================================================
// Creates:
// - Branch1 VPN Gateway (ASN 65010) - "Simulated ExpressRoute"
// - Branch2 VPN Gateway (ASN 65020) - "VPN Backup"
// - Hub VPN Gateway
// - VPN Sites and Connections
// - Local Network Gateways for on-prem route advertisements
//
// KEY DIFFERENCE (demonstrates the customer issue):
// - Branch1 ("ER"): Advertises aggregate 10.0.0.0/16
// - Branch2 ("VPN"): Advertises more-specific 10.0.1.0/24, 10.0.2.0/24
// - LPM causes Branch2 routes to win even when both are active
// =============================================================================

param location string
param vwanName string
param hubName string
param branch1VnetId string
param branch2VnetId string
param hubId string

// =============================================================================
// Branch1 VPN Gateway - "Simulated ExpressRoute" (ASN 65010)
// =============================================================================
resource branch1PublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'branch1-er-vpngw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource branch1VpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: 'branch1-er-vpngw'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    enableBgp: true
    bgpSettings: {
      asn: 65010  // "ExpressRoute" ASN
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${branch1VnetId}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: branch1PublicIp.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Branch2 VPN Gateway - "VPN Backup" (ASN 65020)
// =============================================================================
resource branch2PublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'branch2-vpn-vpngw-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource branch2VpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: 'branch2-vpn-vpngw'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    enableBgp: true
    bgpSettings: {
      asn: 65020  // "VPN Backup" ASN
    }
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${branch2VnetId}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: branch2PublicIp.id
          }
        }
      }
    ]
  }
}

// =============================================================================
// Hub VPN Gateway
// =============================================================================
resource hubVpnGw 'Microsoft.Network/vpnGateways@2023-11-01' = {
  name: '${hubName}-vpngw'
  location: location
  properties: {
    virtualHub: {
      id: hubId
    }
    bgpSettings: {
      asn: 65515  // Azure default ASN for vWAN
    }
  }
}

// =============================================================================
// VPN Site for Branch1 ("Simulated ExpressRoute")
// =============================================================================
resource vpnSiteBranch1 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'site-branch1-er'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'Simulated-ExpressRoute'
      deviceModel: 'Azure-VPN-GW'
      linkSpeedInMbps: 100
    }
    vpnSiteLinks: [
      {
        name: 'link1'
        properties: {
          ipAddress: branch1PublicIp.properties.ipAddress
          bgpProperties: {
            asn: 65010
            bgpPeeringAddress: branch1VpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
          }
          linkProperties: {
            linkSpeedInMbps: 100
          }
        }
      }
    ]
  }
}

// =============================================================================
// VPN Site for Branch2 ("VPN Backup")
// =============================================================================
resource vpnSiteBranch2 'Microsoft.Network/vpnSites@2023-11-01' = {
  name: 'site-branch2-vpn'
  location: location
  properties: {
    virtualWan: {
      id: resourceId('Microsoft.Network/virtualWans', vwanName)
    }
    deviceProperties: {
      deviceVendor: 'VPN-Backup'
      deviceModel: 'Azure-VPN-GW'
      linkSpeedInMbps: 50
    }
    vpnSiteLinks: [
      {
        name: 'link1'
        properties: {
          ipAddress: branch2PublicIp.properties.ipAddress
          bgpProperties: {
            asn: 65020
            bgpPeeringAddress: branch2VpnGateway.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
          }
          linkProperties: {
            linkSpeedInMbps: 50
          }
        }
      }
    ]
  }
}

// =============================================================================
// Hub to Branch1 Connection ("ExpressRoute" path)
// =============================================================================
resource hubBranch1Conn 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hubVpnGw
  name: 'site-branch1-er-conn'
  properties: {
    remoteVpnSite: {
      id: vpnSiteBranch1.id
    }
    enableInternetSecurity: true
    vpnLinkConnections: [
      {
        name: 'link1'
        properties: {
          vpnSiteLink: {
            id: '${vpnSiteBranch1.id}/vpnSiteLinks/link1'
          }
          sharedKey: 'LabSharedKey123!'
          enableBgp: true
        }
      }
    ]
  }
}

// =============================================================================
// Hub to Branch2 Connection ("VPN Backup" path)
// =============================================================================
resource hubBranch2Conn 'Microsoft.Network/vpnGateways/vpnConnections@2023-11-01' = {
  parent: hubVpnGw
  name: 'site-branch2-vpn-conn'
  properties: {
    remoteVpnSite: {
      id: vpnSiteBranch2.id
    }
    enableInternetSecurity: true
    vpnLinkConnections: [
      {
        name: 'link1'
        properties: {
          vpnSiteLink: {
            id: '${vpnSiteBranch2.id}/vpnSiteLinks/link1'
          }
          sharedKey: 'LabSharedKey123!'
          enableBgp: true
        }
      }
    ]
  }
}

// =============================================================================
// Local Network Gateways for Branch1 (Aggregate Route Advertisement)
// Advertises: 10.0.0.0/16 (aggregate - simulates ExpressRoute behavior)
// =============================================================================
resource lngHub1FromBranch1 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-hub-gw0-from-branch1'
  location: location
  properties: {
    gatewayIpAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
    // No localNetworkAddressSpace - using BGP only
  }
}

resource lngHub2FromBranch1 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-hub-gw1-from-branch1'
  location: location
  properties: {
    gatewayIpAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// =============================================================================
// Local Network Gateways for Branch2 (More-Specific Route Advertisement)
// Advertises: 10.0.1.0/24, 10.0.2.0/24 (more-specific - simulates VPN behavior)
// =============================================================================
resource lngHub1FromBranch2 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-hub-gw0-from-branch2'
  location: location
  properties: {
    gatewayIpAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]
    }
  }
}

resource lngHub2FromBranch2 'Microsoft.Network/localNetworkGateways@2023-11-01' = {
  name: 'lng-hub-gw1-from-branch2'
  location: location
  properties: {
    gatewayIpAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]
    bgpSettings: {
      asn: 65515
      bgpPeeringAddress: hubVpnGw.properties.bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]
    }
  }
}

// =============================================================================
// VPN Connections from Branch1 to Hub (both instances for HA)
// =============================================================================
resource branch1ToHubGw0Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-er-to-hub-gw0'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branch1VpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub1FromBranch1.id
    }
    sharedKey: 'LabSharedKey123!'
    enableBgp: true
  }
}

resource branch1ToHubGw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch1-er-to-hub-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branch1VpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub2FromBranch1.id
    }
    sharedKey: 'LabSharedKey123!'
    enableBgp: true
  }
}

// =============================================================================
// VPN Connections from Branch2 to Hub (both instances for HA)
// =============================================================================
resource branch2ToHubGw0Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch2-vpn-to-hub-gw0'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branch2VpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub1FromBranch2.id
    }
    sharedKey: 'LabSharedKey123!'
    enableBgp: true
  }
}

resource branch2ToHubGw1Conn 'Microsoft.Network/connections@2023-11-01' = {
  name: 'branch2-vpn-to-hub-gw1'
  location: location
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: branch2VpnGateway.id
    }
    localNetworkGateway2: {
      id: lngHub2FromBranch2.id
    }
    sharedKey: 'LabSharedKey123!'
    enableBgp: true
  }
}

// =============================================================================
// Outputs
// =============================================================================
output branch1VpnGatewayId string = branch1VpnGateway.id
output branch2VpnGatewayId string = branch2VpnGateway.id
output hubVpnGwId string = hubVpnGw.id
output vpnSiteBranch1Id string = vpnSiteBranch1.id
output vpnSiteBranch2Id string = vpnSiteBranch2.id
