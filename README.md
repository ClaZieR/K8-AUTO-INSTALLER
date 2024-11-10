# Kubernetes Node Setup with Docker, containerd, and CRI Installation Automation

This repository provides an automated script to set up Kubernetes nodes using Docker, containerd, and the CRI (Container Runtime Interface). The script is designed for CentOS, AlmaLinux, or compatible distributions.

## Prerequisites

- CentOS, AlmaLinux, or compatible distributions.
- Root or sudo privileges on the target machine.

## Overview

The script automates the following tasks:

1. **Install Docker and containerd**: It installs Docker and containerd as container runtimes for Kubernetes.
2. **Configure Kubernetes**: It sets up the necessary configuration files and installs Kubernetes components (`kubeadm`, `kubelet`, and `kubectl`).
3. **Calico Network Plugin**: The script installs the Calico network plugin to manage networking within the Kubernetes cluster. Ensure that your network setup is compatible with the CIDR range `192.168.0.0/16` or adjust as needed.
4. **Join Cluster**: The script prepares the node to join an existing Kubernetes cluster.

## Installation

1. Clone this repository to your machine:
   ```bash
   git clone https://github.com/your-username/k8s-node-setup.git
   cd k8s-node-setup ```

2. Give executable permissions to the script:
    ```bash
    chmod +x slave.sh```

3. Run the script:
     ```bash
    sudo ./setup-k8s-node.sh
    
    ```

4. Manual Steps
    Copy Configuration from Master to Slave: After running the script, you will need to manually copy the configuration from the master node to the slave node for proper cluster setup.

## Notes

If you wish to modify the network setup or CIDR range for Calico, adjust the script accordingly.
Conclusion
The script will automatically set up Kubernetes on your node, configure the network, and install the required container runtimes. Ensure that the manual step of copying the configuration from the master to the slave node is performed to complete the node setup.