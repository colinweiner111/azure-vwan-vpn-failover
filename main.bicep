targetScope = 'subscription'

// =============================================================================
// vWAN ExpressRoute/VPN Failover Lab
// =============================================================================
// This lab demonstrates the route preference behavior between two S2S VPN 
// connections simulating ExpressRoute (preferred) and VPN backup scenarios.
//
// Lab Design:
// - Branch1 ("Simulated ExpressRoute"): Advertises aggregate routes (10.0.0.0/16)
// - Branch2 ("VPN Backup"): Advertises more-specific routes (10.0.1.0/24, 10.0.2.0/24)
// - Shows how LPM (Longest Prefix Match) can cause VPN to win over "ER"
// - Demonstrates Route Maps as the solution
// =============================================================================

@description('Primary region for deployment')
param location string = 'westus3'

@description('Resource group name')
param resourceGroupName string = 'vwan-failover-lab'

@description('Virtual WAN name')
param vwanName string = 'vwan-failover'

@description('Hub name')
param hubName string = 'hub1'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('VM size')
param vmSize string = 'Standard_DS1_v2'

@description('Azure Firewall SKU')
@allowed(['Standard', 'Premium'])
param firewallSku string = 'Standard'

@description('Enable Route Maps to fix failback (deploy after initial testing)')
param enableRouteMaps bool = false

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// Network Infrastructure (vWAN, Hub, VNets)
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubName: hubName
  }
}

// Virtual Machines
module vms 'modules/vms.bicep' = {
  scope: rg
  name: 'vms-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    hubName: hubName
  }
  dependsOn: [
    network
  ]
}

// VPN Infrastructure (both branch sites)
module vpn 'modules/vpn.bicep' = {
  scope: rg
  name: 'vpn-deployment'
  params: {
    location: location
    hubName: hubName
    vwanName: vwanName
    branch1VnetId: network.outputs.branch1VnetId
    branch2VnetId: network.outputs.branch2VnetId
    hubId: network.outputs.hubId
  }
}

// Azure Firewall and Routing Intent
module firewall 'modules/firewall.bicep' = {
  scope: rg
  name: 'firewall-deployment'
  params: {
    location: location
    hubName: hubName
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpn
  ]
}

// Azure Bastion
module bastion 'modules/bastion.bicep' = {
  scope: rg
  name: 'bastion-deployment'
  params: {
    location: location
    hubName: hubName
  }
  dependsOn: [
    network
    firewall
  ]
}

// Route Maps (optional - deploy after demonstrating the problem)
module routeMaps 'modules/route-maps.bicep' = if (enableRouteMaps) {
  scope: rg
  name: 'routemaps-deployment'
  params: {
    hubName: hubName
  }
  dependsOn: [
    vpn
  ]
}

output vwanId string = network.outputs.vwanId
output hubId string = network.outputs.hubId
output bastionName string = bastion.outputs.bastionName
output branch1VpnGwId string = vpn.outputs.branch1VpnGatewayId
output branch2VpnGwId string = vpn.outputs.branch2VpnGatewayId

