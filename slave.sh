#!/bin/bash


# Function to validate IP address format
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        echo "Invalid IP address format: $ip"
        return 1
    fi
}

# Function to get user input for slave configuration
read_slave_inputs() {
    # Ask for the current slave's name
    read -p "Enter current slave hostname (default: slave): " slave_hostname
    slave_hostname=${slave_hostname:-slave}

    # Get current slave IP address automatically
    slave_ip=$(hostname -I | awk '{print $1}')
    echo "Current slave IP: $slave_ip"

    # Ask for master name and IP
    read -p "Enter master hostname (default: master): " master_hostname
    master_hostname=${master_hostname:-master}
    
    read -p "Enter master IP: " master_ip
    while ! validate_ip "$master_ip"; do
        read -p "Please enter a valid master IP: " master_ip
    done

    # Ask for the number of other slave nodes
    read -p "How many other slave nodes do you want to configure?: " num_slaves

    # Initialize arrays for slave hostnames and IPs
    declare -ga slave_hostnames=()
    declare -ga slave_ips=()

    # Loop to get each slave's hostname and IP
    for ((i=1; i<=num_slaves; i++)); do
        read -p "Enter hostname for slave $i (default: slave$i): " slave_name
        slave_name=${slave_name:-slave$i}
        slave_hostnames+=("$slave_name")
        
        read -p "Enter IP for slave $i: " slave_ip
        while ! validate_ip "$slave_ip"; do
            read -p "Please enter a valid IP for slave $i: " slave_ip
        done
        slave_ips+=("$slave_ip")
    done

    # Store k8s join information
    read -p "Enter the token: " token
    read -p "Enter the discovery token hash: " ca_cert_hash

    # Export variables for use in other functions
    export slave_hostname master_hostname master_ip token ca_cert_hash
}

# Function to update /etc/hosts file
update_hosts_file() {
    # Backup the original hosts file
    sudo cp /etc/hosts /etc/hosts.backup
    
    echo "Updating /etc/hosts file..."
    
    # Add master entry if not exists
    if ! grep -q "$master_hostname" /etc/hosts; then
        echo "$master_ip $master_hostname" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    # Add current slave entry if not exists
    if ! grep -q "$slave_hostname" /etc/hosts; then
        echo "$slave_ip $slave_hostname" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    # Add other slaves
    for ((i=0; i<${#slave_hostnames[@]}; i++)); do
        if ! grep -q "${slave_hostnames[$i]}" /etc/hosts; then
            echo "${slave_ips[$i]} ${slave_hostnames[$i]}" | sudo tee -a /etc/hosts > /dev/null
        fi
    done
    
    echo "Hosts file has been updated. Backup saved as /etc/hosts.backup"
    echo "Current /etc/hosts content:"
    cat /etc/hosts
}

# Main execution
main() {
    echo "Starting Kubernetes node configuration..."
    
    # Check if script is run with sudo
    if [ "$EUID" -ne 0 ]; then 
        echo "Please run with sudo privileges"
        exit 1
    fi
    
    # Collect all inputs
    read_slave_inputs
    
    # Update hosts file
    update_hosts_file
}

# Run the main function


# Import GPG Key for AlmaLinux
import_gpg_keys() {
  echo "Importing GPG key for AlmaLinux..."
  rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
  curl -o /tmp/RPM-GPG-KEY-AlmaLinux https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux
  rpm --import /tmp/RPM-GPG-KEY-AlmaLinux
  rpm -qa gpg-pubkey*
}

# Disable SELinux
disable_selinux() {
  echo "Disabling SELinux..."
  sudo setenforce 0
  sudo sed -i --follow-symlinks 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/sysconfig/selinux
  sestatus
}

# Configure firewall ports
configure_firewall() {
  echo "Configuring firewall..."
  sudo firewall-cmd --permanent --add-port=179/tcp
  sudo firewall-cmd --permanent --add-port=10250/tcp
  sudo firewall-cmd --permanent --add-port=30000-32767/tcp
  sudo firewall-cmd --permanent --add-port=4789/udp
  sudo firewall-cmd --reload
}

# Set hostname for the slave
set_hostname() {
  echo "Setting hostname..."
  sudo hostnamectl set-hostname $slave_hostname
}

# Disable swap
disable_swap() {
  echo "Disabling swap..."
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
}

# Install necessary packages
install_packages() {
  echo "Installing necessary packages..."
  sudo yum install -y yum-utils
  sudo dnf -y install dnf-plugins-core
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin --allowerasing
}

# Enable and start Docker
enable_start_docker() {
  echo "Enabling and starting Docker..."
  sudo systemctl enable docker
  sudo systemctl start docker
}

# Configure Docker daemon
configure_docker() {
  echo "Configuring Docker..."
  cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

  sudo systemctl daemon-reload
  sudo systemctl restart docker
}

# Install cri-dockerd
install_cri_dockerd() {
  echo "Installing cri-dockerd..."
  wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.15/cri-dockerd-0.3.15.amd64.tgz
  tar xvf cri-dockerd-0.3.15.amd64.tgz
  sudo mv cri-dockerd/cri-dockerd /usr/local/bin/
  cri-dockerd --version
}

# Setup systemd for cri-dockerd
setup_systemd_cri_dockerd() {
  echo "Setting up systemd for cri-dockerd..."
  wget https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.service https://raw.githubusercontent.com/Mirantis/cri-dockerd/master/packaging/systemd/cri-docker.socket
  sudo mv cri-docker.socket cri-docker.service /etc/systemd/system/
  sudo sed -i -e 's,/usr/bin/cri-dockerd,/usr/local/bin/cri-dockerd,' /etc/systemd/system/cri-docker.service
  sudo systemctl daemon-reload
  sudo systemctl enable cri-docker.service
  sudo systemctl enable --now cri-docker.socket
  systemctl status cri-docker.socket
}

# Configure Kubernetes repo
configure_k8s_repo() {
  echo "Configuring Kubernetes repo..."
  cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
}

# Install Kubernetes tools
install_k8s_tools() {
  echo "Installing Kubernetes tools..."
  sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
}

# Enable and start kubelet
enable_start_kubelet() {
  echo "Enabling and starting kubelet..."
  sudo systemctl enable kubelet
  sudo systemctl start kubelet
}

# Join Kubernetes cluster
join_k8s_cluster() {
  echo "Joining Kubernetes cluster..."
  sudo kubeadm join $master_ip:6443 --token $token --discovery-token-ca-cert-hash $ca_cert_hash --cri-socket /var/run/cri-dockerd.sock
}

# Setup kube config
setup_kube_config() {
  echo "Setting up kube config..."
  mkdir -p $HOME/.kube
  sudo cp -p /etc/kubernetes/kubelet.conf $HOME/.kube
  echo "Copy the kubeconfig from master to this slave using: 'cat $HOME/.kube/config'"
  echo "Slave setup completed!"
}

# Main script execution
import_gpg_keys
main
disable_selinux
configure_firewall
set_hostname
disable_swap
install_packages
enable_start_docker
configure_docker
install_cri_dockerd
setup_systemd_cri_dockerd
configure_k8s_repo
install_k8s_tools
enable_start_kubelet
join_k8s_cluster
setup_kube_config

echo "Slave setup completed!"
