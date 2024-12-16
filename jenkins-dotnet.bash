#!/bin/bash

# Function to exit with a message
exit_with_error() {
    echo "[ERROR] $1"
    exit 1
}

# Ask user for the public IP address
read -p "Enter the VM's public IP address: " ip_public
if [[ -z "$ip_public" ]]; then
    exit_with_error "No public IP address provided. Exiting."
fi

# Persist public IP in /etc/profile.d for reboot
echo "export IP_PUBLIC=$ip_public" | sudo tee /etc/profile.d/vm_env.sh > /dev/null
source /etc/profile.d/vm_env.sh

# Update system packages
echo "[INFO] Updating system packages..."
sudo apt-get update && sudo apt-get upgrade -y || exit_with_error "System update failed."

# Install JDK
echo "[INFO] Installing JDK..."
sudo apt install -y fontconfig openjdk-17-jre || exit_with_error "JDK installation failed."
java --version || exit_with_error "JDK verification failed."

# Install Jenkins
echo "[INFO] Installing Jenkins..."
sudo wget -q -O /usr/share/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key || exit_with_error "Failed to download Jenkins keyring."
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | \
    sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update || exit_with_error "Jenkins repository update failed."
sudo apt-get install -y jenkins || exit_with_error "Jenkins installation failed."

# Start and enable Jenkins service
sudo systemctl restart jenkins && sudo systemctl enable jenkins || exit_with_error "Failed to start/enable Jenkins service."
sudo systemctl status jenkins | grep -q "active (running)" || exit_with_error "Jenkins service is not running."

# Enable HTTPS with Nginx
echo "[INFO] Setting up HTTPS with Nginx..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/ssl/private/jenkins-selfsigned.key \
    -out /etc/ssl/certs/jenkins-selfsigned.crt -subj "/CN=$IP_PUBLIC" || exit_with_error "Failed to create self-signed certificate."

sudo apt-get install -y nginx || exit_with_error "Nginx installation failed."
cat << EOF | sudo tee /etc/nginx/sites-available/jenkins > /dev/null
server {
    listen 443 ssl;
    server_name $IP_PUBLIC;

    ssl_certificate /etc/ssl/certs/jenkins-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/jenkins-selfsigned.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host '\$host';
        proxy_set_header X-Real-IP '\$remote_addr';
        proxy_set_header X-Forwarded-For '\$proxy_add_x_forwarded_for';
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/
sudo nginx -t || exit_with_error "Nginx configuration test failed."
sudo systemctl restart nginx || exit_with_error "Failed to restart Nginx."

# Install .NET environment
echo "[INFO] Installing .NET environment..."
sudo apt-get install -y dotnet-sdk-8.0 ca-certificates libc6 libgcc-s1 libicu74 liblttng-ust1 libssl3 libstdc++6 libunwind8 zlib1g || exit_with_error ".NET installation failed."
dotnet tool install --global dotnet-ef || exit_with_error "Failed to install dotnet-ef."
echo 'export PATH="$PATH:$HOME/.dotnet/tools/"' | sudo tee -a /etc/profile.d/dotnet_env.sh > /dev/null
source /etc/profile.d/dotnet_env.sh

# Output Jenkins initial admin password
echo "[INFO] Setup complete. Access Jenkins at https://${IP_PUBLIC}"
echo "Initial Admin Password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword || exit_with_error "Failed to retrieve Jenkins initialAdminPassword."
