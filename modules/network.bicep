// =============================================================================
// Network Module - vWAN Hub, Branch VNets, Spoke VNets
// =============================================================================
// Creates:
// - Virtual WAN with single hub
// - Branch1 VNet (simulates "ExpressRoute" connection)
// - Branch2 VNet (simulates "VPN Backup" connection)
// - Spoke VNets connected to hub
// - Bastion VNet for management access
// =============================================================================

param location string
param vwanName string
param hubName string

// =============================================================================
// Virtual WAN
// =============================================================================
resource vwan 'Microsoft.Network/virtualWans@2023-11-01' = {
  name: vwanName
  location: location
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
  }
}

// =============================================================================
// Virtual Hub
// =============================================================================
resource hub 'Microsoft.Network/virtualHubs@2023-11-01' = {
  name: hubName
  location: location
  properties: {
    addressPrefix: '192.168.1.0/24'
    virtualWan: {
      id: vwan.id
    }
    sku: 'Standard'
    // Hub routing preference - set to ExpressRoute to prefer ER when prefix lengths match
    // Note: LPM still wins regardless of this setting
    hubRoutingPreference: 'ExpressRoute'
  }
}

// =============================================================================
// Branch1 VNet - "Simulated ExpressRoute" (preferred path)
// Advertises aggregate prefix: 10.0.0.0/16
// =============================================================================
resource branch1Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'branch1-er'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.100.0.0/16']
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: '10.100.0.0/24'
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.100.255.0/27'
        }
      }
    ]
  }
}

// =============================================================================
// Branch2 VNet - "VPN Backup" (backup path)
// Advertises more-specific prefixes: 10.0.1.0/24, 10.0.2.0/24
// =============================================================================
resource branch2Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'branch2-vpn'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.200.0.0/16']
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: '10.200.0.0/24'
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.200.255.0/27'
        }
      }
    ]
  }
}

// =============================================================================
// On-Prem Simulation VNet (shared backend reachable via both branches)
// This represents the "on-prem" network that both branches advertise routes for
// =============================================================================
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'onprem-backend'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: '10.0.1.0/24'
        }
      }
      {
        name: 'secondary'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

// VNet peering: onprem-backend <-> branch1-er
resource branch1ToOnprem 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: branch1Vnet
  name: 'branch1-to-onprem'
  properties: {
    remoteVirtualNetwork: {
      id: onpremVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
  dependsOn: [
    branch1Nsg
    onpremNsg
  ]
}

resource onpremToBranch1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: onpremVnet
  name: 'onprem-to-branch1'
  properties: {
    remoteVirtualNetwork: {
      id: branch1Vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false // Will be true after gateway deployed
  }
  dependsOn: [
    branch1ToOnprem
  ]
}

// VNet peering: onprem-backend <-> branch2-vpn
resource branch2ToOnprem 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: branch2Vnet
  name: 'branch2-to-onprem'
  properties: {
    remoteVirtualNetwork: {
      id: onpremVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
  }
  dependsOn: [
    branch2Nsg
    onpremNsg
    onpremToBranch1  // Serialize peerings to avoid concurrent updates
  ]
}

resource onpremToBranch2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: onpremVnet
  name: 'onprem-to-branch2'
  properties: {
    remoteVirtualNetwork: {
      id: branch2Vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    useRemoteGateways: false // Will be true after gateway deployed
  }
  dependsOn: [
    branch2ToOnprem
  ]
}

// =============================================================================
// Bastion VNet
// =============================================================================
resource bastionVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'bastion-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.250.0.0/24']
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.250.0.0/26'
        }
      }
    ]
  }
}

// =============================================================================
// Spoke VNets
// =============================================================================
resource spoke1 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${hubName}-spoke1'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['172.16.1.0/24']
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: '172.16.1.0/27'
        }
      }
    ]
  }
}

resource spoke2 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${hubName}-spoke2'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['172.16.2.0/24']
    }
    subnets: [
      {
        name: 'main'
        properties: {
          addressPrefix: '172.16.2.0/27'
        }
      }
    ]
  }
}

// =============================================================================
// NSGs
// =============================================================================
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'default-nsg-${location}'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow inbound SSH'
        }
      }
      {
        name: 'allow-bastion-ssh'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.250.0.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow SSH from Bastion'
        }
      }
      {
        name: 'allow-icmp'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Icmp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow ICMP for ping tests'
        }
      }
    ]
  }
}

// NSG Associations
resource spoke1Nsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: spoke1
  name: 'main'
  properties: {
    addressPrefix: '172.16.1.0/27'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource spoke2Nsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: spoke2
  name: 'main'
  properties: {
    addressPrefix: '172.16.2.0/27'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource branch1Nsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: branch1Vnet
  name: 'main'
  properties: {
    addressPrefix: '10.100.0.0/24'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource branch2Nsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: branch2Vnet
  name: 'main'
  properties: {
    addressPrefix: '10.200.0.0/24'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource onpremNsg 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: onpremVnet
  name: 'main'
  properties: {
    addressPrefix: '10.0.1.0/24'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

// =============================================================================
// Hub Virtual Network Connections (Spokes)
// =============================================================================
resource hubSpoke1Conn 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  parent: hub
  name: 'spoke1-conn'
  properties: {
    remoteVirtualNetwork: {
      id: spoke1.id
    }
    enableInternetSecurity: true
  }
}

resource hubSpoke2Conn 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2023-11-01' = {
  parent: hub
  name: 'spoke2-conn'
  properties: {
    remoteVirtualNetwork: {
      id: spoke2.id
    }
    enableInternetSecurity: true
  }
}

// =============================================================================
// Outputs
// =============================================================================
output vwanId string = vwan.id
output hubId string = hub.id
output branch1VnetId string = branch1Vnet.id
output branch2VnetId string = branch2Vnet.id
output onpremVnetId string = onpremVnet.id
output bastionVnetId string = bastionVnet.id
output spoke1Id string = spoke1.id
output spoke2Id string = spoke2.id
output nsgId string = nsg.id
