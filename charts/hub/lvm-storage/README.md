# LVM Storage Chart

This Helm chart deploys and configures LVMS storage for baremetal OpenShift clusters using the LVMS Operator.

## Overview

This chart creates an `LVMCluster` custom resource that automatically discovers and configures available storage devices on baremetal nodes to provide persistent volume storage.

## Features

- **Automatic Disk Discovery**: Automatically detects available storage devices (`/dev/nvme*`, `/dev/sd*`, `/dev/vd*`, `/dev/xvd*`)
- **Thin Provisioning**: Configures thin pool for efficient storage utilization
- **Configurable**: Allows customization of device classes, node selectors, and storage parameters

## Configuration

Key configuration options in `values.yaml`:

```yaml
lvmCluster:
  name: "lvmcluster"               # Name of the LVMCluster resource
  deviceClass: "vg1"               # Device class name
  thinPoolName: "thin-pool-1"      # Thin pool name
  thinPoolSizePercent: 90          # Percentage of VG to use for thin pool
  overprovisionRatio: 10           # Overprovisioning ratio
```

## Storage Class

The LVMS operator automatically creates a storage class named `lvms-vg1` (following the pattern `lvms-<deviceclass>`) that can be used for persistent volume claims.

## Integration

This chart is designed to work with the validated pattern framework and is deployed automatically when the `lvm-storage` application is enabled in the cluster group configuration.
