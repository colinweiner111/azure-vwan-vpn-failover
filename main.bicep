targetScope = 'subscription'

// =============================================================================
// vWAN ExpressRoute/VPN Failover Lab - FRR/strongSwan Edition
// =============================================================================
// This lab demonstrates the route preference behavior between two S2S VPN 
// connections simulating ExpressRoute (preferred) and VPN backup scenarios.
//
// Architecture:
// - Two on-prem VMs running FRRouting + strongSwan (6 IPsec tunnels total, 2 per hub)
//   * VM1 (frr-router): ER-path tunnels to Hub1/Hub2/Hub3 VPN GW Instance 0
//     - Advertises aggregate 10.0.0.0/16 via BGP
//   * VM2 (frr-router-backup): VPN-backup tunnels to Hub1/Hub2/Hub3 VPN GW Instance 1
//     - Advertises specific 10.0.1.0/24, 10.0.2.0/24 via BGP
// - Shows how LPM (Longest Prefix Match) causes VPN routes to win
// - Demonstrates Route Maps as the solution
// =============================================================================

@description('Primary region for deployment')
param location string = 'westus3'

@description('Resource group name')
param resourceGroupName string = 'vwan-failover-lab'

@description('Virtual WAN name')
param vwanName string = 'vwan-failover'

@description('Hub name')
param hubName string = 'hub1-westus3'

@description('Secondary hub name')
param hub2Name string = 'hub2-eastus2'

@description('Secondary hub region')
param hub2Location string = 'eastus2'

@description('Tertiary hub name')
param hub3Name string = 'hub3-westus'

@description('Tertiary hub region')
param hub3Location string = 'westus'

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('SSH public key for the FRR VM')
param sshPublicKey string = ''

@description('VM size for FRR router')
param vmSize string = 'Standard_B2s'

@description('Deploy Azure Firewall with Routing Intent (adds ~15 min to deployment)')
param enableFirewall bool = false

@description('Deploy Azure Bastion for VM access (adds ~5 min to deployment)')
param enableBastion bool = false

@description('Azure Firewall SKU (if enabled)')
@allowed(['Standard', 'Premium'])
param firewallSku string = 'Standard'

@description('Enable Route Maps to fix failback (deploy after initial testing)')
param enableRouteMaps bool = false

@description('Pre-shared key for VPN tunnels')
@secure()
param vpnPsk string

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}

// Network Infrastructure (vWAN, Hub1, Hub2, Hub3, On-Prem VNet)
module network 'modules/network.bicep' = {
  scope: rg
  name: 'network-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubName: hubName
    hub2Name: hub2Name
    hub2Location: hub2Location
    hub3Name: hub3Name
    hub3Location: hub3Location
  }
}

// Hub VPN Gateway (deploy early as it takes ~30 mins)
module vpnGateway 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-deployment'
  params: {
    location: location
    hubName: hubName
    hubId: network.outputs.hubId
  }
}

// Hub2 VPN Gateway (deploy in parallel with hub1 gateway)
module vpnGatewayHub2 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-hub2-deployment'
  params: {
    location: hub2Location
    hubName: hub2Name
    hubId: network.outputs.hub2Id
  }
}

// Hub3 VPN Gateway (deploy in parallel with hub1/hub2 gateways)
module vpnGatewayHub3 'modules/vpn-gateway.bicep' = {
  scope: rg
  name: 'vpngw-hub3-deployment'
  params: {
    location: hub3Location
    hubName: hub3Name
    hubId: network.outputs.hub3Id
  }
}

// FRR/strongSwan VM 1 - ER Path (on-prem router with tunnels to all 3 hubs)
module frrVm 'modules/frr-vm.bicep' = {
  scope: rg
  name: 'frr-vm-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp0: vpnGateway.outputs.bgpPeeringAddress0
    hubVpnGwPublicIp0: vpnGateway.outputs.publicIpAddress0
    hub2VpnGwBgpIp0: vpnGatewayHub2.outputs.bgpPeeringAddress0
    hub2VpnGwPublicIp0: vpnGatewayHub2.outputs.publicIpAddress0
    hub3VpnGwBgpIp0: vpnGatewayHub3.outputs.bgpPeeringAddress0
    hub3VpnGwPublicIp0: vpnGatewayHub3.outputs.publicIpAddress0
  }
}

// FRR/strongSwan VM 2 - VPN Backup (on-prem router with tunnels to all 3 hubs)
module frrVmBackup 'modules/frr-vm-backup.bicep' = {
  scope: rg
  name: 'frr-vm-backup-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.onpremSubnetId
    vpnPsk: vpnPsk
    hubVpnGwBgpIp1: vpnGateway.outputs.bgpPeeringAddress1
    hubVpnGwPublicIp1: vpnGateway.outputs.publicIpAddress1
    hub2VpnGwBgpIp1: vpnGatewayHub2.outputs.bgpPeeringAddress1
    hub2VpnGwPublicIp1: vpnGatewayHub2.outputs.publicIpAddress1
    hub3VpnGwBgpIp1: vpnGatewayHub3.outputs.bgpPeeringAddress1
    hub3VpnGwPublicIp1: vpnGatewayHub3.outputs.publicIpAddress1
  }
}

// VPN Sites and Connections (link on-prem to hub - 2 sites for ER/VPN simulation)
module vpnSites 'modules/vpn-sites.bicep' = {
  scope: rg
  name: 'vpn-sites-deployment'
  params: {
    location: location
    vwanName: vwanName
    hubVpnGwName: vpnGateway.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress      // ER-path VM PIP
    onpremPublicIp2: frrVmBackup.outputs.publicIpAddress  // VPN-backup VM PIP
    onpremBgpIp: frrVm.outputs.privateIpAddress        // ER-path VM private IP
    onpremBgpIp2: frrVmBackup.outputs.privateIpAddress   // VPN-backup VM private IP
    vpnPsk: vpnPsk
  }
}

// VPN Sites and Connections for Hub2 (same 2 on-prem VMs, different hub)
module vpnSitesHub2 'modules/vpn-sites-hub2.bicep' = {
  scope: rg
  name: 'vpn-sites-hub2-deployment'
  params: {
    location: location
    vwanName: vwanName
    hub2VpnGwName: vpnGatewayHub2.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress
    onpremPublicIp2: frrVmBackup.outputs.publicIpAddress
    onpremBgpIp: frrVm.outputs.privateIpAddress
    onpremBgpIp2: frrVmBackup.outputs.privateIpAddress
    vpnPsk: vpnPsk
  }
}

// VPN Sites and Connections for Hub3 (same 2 on-prem VMs, different hub)
module vpnSitesHub3 'modules/vpn-sites-hub3.bicep' = {
  scope: rg
  name: 'vpn-sites-hub3-deployment'
  params: {
    location: location
    vwanName: vwanName
    hub3VpnGwName: vpnGatewayHub3.outputs.vpnGatewayName
    onpremPublicIp: frrVm.outputs.publicIpAddress
    onpremPublicIp2: frrVmBackup.outputs.publicIpAddress
    onpremBgpIp: frrVm.outputs.privateIpAddress
    onpremBgpIp2: frrVmBackup.outputs.privateIpAddress
    vpnPsk: vpnPsk
  }
}

// Azure Firewall and Routing Intent (optional - not needed for LPM demo)
module firewall 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-deployment'
  params: {
    location: location
    hubName: hubName
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpnGateway
  ]
}

// Azure Firewall and Routing Intent for Hub2 (optional)
module firewallHub2 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-hub2-deployment'
  params: {
    location: hub2Location
    hubName: hub2Name
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpnGatewayHub2
  ]
}

// Azure Firewall and Routing Intent for Hub3 (optional)
module firewallHub3 'modules/firewall.bicep' = if (enableFirewall) {
  scope: rg
  name: 'firewall-hub3-deployment'
  params: {
    location: hub3Location
    hubName: hub3Name
    firewallSku: firewallSku
  }
  dependsOn: [
    network
    vpnGatewayHub3
  ]
}

// Azure Bastion (optional - for management access)
module bastion 'modules/bastion.bicep' = if (enableBastion) {
  scope: rg
  name: 'bastion-deployment'
  params: {
    location: location
    vnetName: network.outputs.onpremVnetName
  }
  dependsOn: [
    network
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
    vpnSites
  ]
}

// Route Maps for Hub2 (optional)
module routeMapsHub2 'modules/route-maps.bicep' = if (enableRouteMaps) {
  scope: rg
  name: 'routemaps-hub2-deployment'
  params: {
    hubName: hub2Name
  }
  dependsOn: [
    vpnSitesHub2
  ]
}

// Route Maps for Hub3 (optional)
module routeMapsHub3 'modules/route-maps.bicep' = if (enableRouteMaps) {
  scope: rg
  name: 'routemaps-hub3-deployment'
  params: {
    hubName: hub3Name
  }
  dependsOn: [
    vpnSitesHub3
  ]
}

// Spoke VNets connected to hub
module spokes 'modules/spokes.bicep' = {
  scope: rg
  name: 'spokes-deployment'
  params: {
    location: location
    hubId: network.outputs.hubId
  }
  dependsOn: [
    vpnGateway
  ]
}

// Spoke VNets connected to hub2
module spokesHub2 'modules/spokes-hub2.bicep' = {
  scope: rg
  name: 'spokes-hub2-deployment'
  params: {
    location: hub2Location
    hub2Id: network.outputs.hub2Id
  }
  dependsOn: [
    vpnGatewayHub2
  ]
}

// Spoke VNets connected to hub3
module spokesHub3 'modules/spokes-hub3.bicep' = {
  scope: rg
  name: 'spokes-hub3-deployment'
  params: {
    location: hub3Location
    hub3Id: network.outputs.hub3Id
  }
  dependsOn: [
    vpnGatewayHub3
  ]
}

// Workload VMs (on-prem + spokes)
module workloadVms 'modules/workload-vms.bicep' = {
  scope: rg
  name: 'workload-vms-deployment'
  params: {
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    onpremSubnetId: network.outputs.onpremWorkloadsSubnetId
    spoke1SubnetId: spokes.outputs.spoke1SubnetId
    spoke2SubnetId: spokes.outputs.spoke2SubnetId
  }
}

// Workload VMs for Hub2 spokes
module workloadVmsHub2 'modules/workload-vms-hub2.bicep' = {
  scope: rg
  name: 'workload-vms-hub2-deployment'
  params: {
    location: hub2Location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    spoke3SubnetId: spokesHub2.outputs.spoke3SubnetId
    spoke4SubnetId: spokesHub2.outputs.spoke4SubnetId
  }
}

// Workload VMs for Hub3 spokes
module workloadVmsHub3 'modules/workload-vms-hub3.bicep' = {
  scope: rg
  name: 'workload-vms-hub3-deployment'
  params: {
    location: hub3Location
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    spoke5SubnetId: spokesHub3.outputs.spoke5SubnetId
    spoke6SubnetId: spokesHub3.outputs.spoke6SubnetId
  }
}

output vwanId string = network.outputs.vwanId
output hubId string = network.outputs.hubId
output hub2Id string = network.outputs.hub2Id
output hub3Id string = network.outputs.hub3Id
output frrVmPublicIp string = frrVm.outputs.publicIpAddress
output frrVmPrivateIp string = frrVm.outputs.privateIpAddress
output frrVmBackupPublicIp string = frrVmBackup.outputs.publicIpAddress
output frrVmBackupPrivateIp string = frrVmBackup.outputs.privateIpAddress
output hubVpnGwPublicIp0 string = vpnGateway.outputs.publicIpAddress0
output hubVpnGwPublicIp1 string = vpnGateway.outputs.publicIpAddress1
output hub2VpnGwPublicIp0 string = vpnGatewayHub2.outputs.publicIpAddress0
output hub2VpnGwPublicIp1 string = vpnGatewayHub2.outputs.publicIpAddress1
output hub3VpnGwPublicIp0 string = vpnGatewayHub3.outputs.publicIpAddress0
output hub3VpnGwPublicIp1 string = vpnGatewayHub3.outputs.publicIpAddress1
output onpremVmPrivateIp string = workloadVms.outputs.onpremVmPrivateIp
output spoke1VmPrivateIp string = workloadVms.outputs.spoke1VmPrivateIp
output spoke2VmPrivateIp string = workloadVms.outputs.spoke2VmPrivateIp
output spoke3VmPrivateIp string = workloadVmsHub2.outputs.spoke3VmPrivateIp
output spoke4VmPrivateIp string = workloadVmsHub2.outputs.spoke4VmPrivateIp
output spoke5VmPrivateIp string = workloadVmsHub3.outputs.spoke5VmPrivateIp
output spoke6VmPrivateIp string = workloadVmsHub3.outputs.spoke6VmPrivateIp
