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
read_master_inputs() {

    read -p "Enter current Master hostname (default: Master): " master_hostname
    master_hostname=${master_hostname:-master}


    master_ip=$(hostname -I | awk '{print $1}')
    echo "Current slave IP: $master_ip"


    read -p "How many slave nodes do you want to configure?: " num_slaves


    declare -ga slave_hostnames=()
    declare -ga slave_ips=()

    export master_ip

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

}

# Function to update /etc/hosts file
update_hosts_file() {

    sudo cp /etc/hosts /etc/hosts.backup
    
    echo "Updating /etc/hosts file..."
    

    if ! grep -q "$master_hostname" /etc/hosts; then
        echo "$master_ip $master_hostname" | sudo tee -a /etc/hosts > /dev/null
    fi
    
 
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
    

    if [ "$EUID" -ne 0 ]; then 
        echo "Please run with sudo privileges"
        exit 1
    fi
    

    read_master_inputs
    

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
  sudo firewall-cmd --permanent --add-port=6443/tcp
  sudo firewall-cmd --permanent --add-port=2379-2380/tcp
  sudo firewall-cmd --permanent --add-port=10250/tcp
  sudo firewall-cmd --permanent --add-port=10251/tcp
  sudo firewall-cmd --permanent --add-port=10259/tcp
  sudo firewall-cmd --permanent --add-port=10257/tcp
  sudo firewall-cmd --permanent --add-port=179/tcp
  sudo firewall-cmd --permanent --add-port=4789/udp
  sudo firewall-cmd --reload
}

# Set hostname for the master
set_hostname() {
  echo "Setting hostname..."
  sudo hostnamectl set-hostname $master_hostname
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
  sleep 10
}

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

extract_and_echo_token_and_hash() {   
    local output="$1"
    
    # Extract and export the token and hash
    export K8S_TOKEN=$(echo "$output" | grep -oP 'Using token: \K\S+')
    export K8S_HASH=$(echo "$output" | grep -oP 'sha256:\S+')
    
    # Echo the token and hash
    echo "----------------------------------------"
    echo "This is Your Token: $K8S_TOKEN"
    echo "This is Your Hash: $K8S_HASH"
    echo "----------------------------------------"
    
    # Save to a separate file for later reference
    {
        echo "Token: $K8S_TOKEN"
        echo "Hash: $K8S_HASH"
        echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    } > cluster-join-info.txt
}


init_master() {
    log_message "Starting Kubernetes master initialization..."
    
    # Run kubeadm init directly and capture output to a log file
    sudo kubeadm init \
        --pod-network-cidr=192.168.0.0/16 \
        --cri-socket unix:///var/run/cri-dockerd.sock \
        | tee kubeadm-init.log
    
    # Store the exit status (use ${PIPESTATUS[0]} to get the exit status of kubeadm, not tee)
    INIT_STATUS=${PIPESTATUS[0]}
    
    # Check if initialization was successful
    if [ $INIT_STATUS -eq 0 ]; then
        log_message "Kubernetes master initialization completed successfully"
    else
        log_message "ERROR: Kubernetes master initialization failed with status $INIT_STATUS"
        log_message "Check kubeadm-init.log for details"
        exit 1
    fi
}

# Setup kube config
setup_kube_config() {
  echo "Setting up kube config..."
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  kubectl get nodes
}

calico_network() {
  echo "Installing Calico network plugin..."

  # Download and apply the Calico operator manifest
  kubectl create -f https://docs.projectcalico.org/manifests/tigera-operator.yaml

  # Download the custom-resources.yaml file
  wget https://docs.projectcalico.org/manifests/custom-resources.yaml

  # Use sed to replace the IP address in the YAML file with $master_ip dynamically
  sed "s|192.168.0.0/16|$master_ip/16|g" custom-resources.yaml | kubectl apply -f -

  # Check the Calico pods status
  kubectl get pods -n calico-system
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
init_master
setup_kube_config
calico_network
extract_and_echo_token_and_hash "$(cat kubeadm-init.log)"

echo "Master setup completed!"



