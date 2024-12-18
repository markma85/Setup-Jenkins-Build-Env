#!/bin/bash

# Function to exit with a message
exit_with_error() {
    echo "[ERROR] $1"
    exit 1
}

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Parse command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ip-public) ip_public="$2"; shift ;;
        --docker-host) docker_host="$2"; shift ;;
        --docker-port) docker_port="$2"; shift ;;
        *) echo "[WARNING] Unknown parameter passed: $1"; exit_with_error "Usage: $0 [--ip-public <ip>] [--docker-host <ip>] [--docker-port <port>]" ;;
    esac
    shift
done

# Ask user for the public IP address, check if the IP address is valid, otherwise let the user re-enter the IP address
if [[ -z "$ip_public" ]]; then
    read -p "Enter the public IP address: " ip_public
    while ! [[ "$ip_public" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; do
        read -p "Invalid IP address. Please enter a valid public IP address: " ip_public
    done
fi

# Check if wget is installed
if ! command_exists wget; then
    echo "[INFO] Installing wget..."
    sudo apt-get update && sudo apt-get install -y wget || exit_with_error "wget installation failed."
else
    echo "[INFO] wget is already installed."
fi

# Check if JDK is installed
if ! command_exists java; then
    echo "[INFO] Installing JDK..."
    sudo apt install -y fontconfig openjdk-17-jre || exit_with_error "JDK installation failed."
    java --version || exit_with_error "JDK verification failed."
else
    echo "[INFO] JDK is already installed."
fi

# Check if Jenkins is installed
if ! command_exists jenkins; then
    echo "[INFO] Installing Jenkins..."
    sudo wget -q -O /usr/share/keyrings/jenkins-keyring.asc \
        https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key || exit_with_error "Failed to download Jenkins keyring."
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | \
        sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    sudo apt-get update || exit_with_error "Jenkins repository update failed."
    sudo apt-get install -y jenkins || exit_with_error "Jenkins installation failed."
else
    echo "[INFO] Jenkins is already installed."
fi

# Start and enable Jenkins service
if ! sudo service jenkins status | grep -q "active (running)"; then
    echo "[INFO] Starting Jenkins service..."
    sudo service jenkins restart || exit_with_error "Failed to start Jenkins service."
    sudo systemctl enable jenkins || echo "[WARNING]Failed to enable Jenkins service."
else
    echo "[INFO] Jenkins service is already running."
fi

# Check if Nginx is installed
if ! command_exists nginx; then
    echo "[INFO] Installing Nginx..."
    sudo apt-get install -y nginx || exit_with_error "Nginx installation failed."
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/jenkins-selfsigned.key \
        -out /etc/ssl/certs/jenkins-selfsigned.crt -subj "/CN=$ip_public" || exit_with_error "Failed to create self-signed certificate."

    cat << EOF | sudo tee /etc/nginx/sites-available/jenkins > /dev/null
server {
    listen 443 ssl;
    server_name $ip_public;

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
    sudo service nginx restart || exit_with_error "Failed to restart Nginx."
else
    echo "[INFO] Nginx is already installed and running."
fi

# Check if .NET is installed
if ! command_exists dotnet; then
    echo "[INFO] Installing .NET environment..."
    sudo apt-get install -y dotnet-sdk-8.0 ca-certificates libc6 libgcc-s1 libicu74 liblttng-ust1 libssl3 libstdc++6 libunwind8 zlib1g || exit_with_error ".NET installation failed."
else
    echo "[INFO] .NET is already installed."
fi

# Check if dotnet-ef is installed
if ! dotnet tool list --tool-path /root/.dotnet/tools | grep -q "dotnet-ef"; then
    echo "[INFO] Installing dotnet-ef..."
    sudo dotnet tool install --tool-path /root/.dotnet/tools dotnet-ef || exit_with_error "Failed to install dotnet-ef."
    echo 'export PATH="$PATH:/root/.dotnet/tools/"' | sudo tee -a /etc/profile.d/dotnet_env.sh > /dev/null
    source /etc/profile.d/dotnet_env.sh
else
    echo "[INFO] dotnet-ef is already installed."
fi

# Check if Docker CLI is installed
if ! command_exists docker; then
    echo "[INFO] Installing Docker client..."
    sudo apt-get install ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce-cli || exit_with_error "Docker client installation failed."
    docker --version || exit_with_error "Docker client verification failed."
else
    echo "[INFO] Docker CLI is already installed."
fi

# Output Jenkins initial admin password
echo "[INFO] Setup complete. Access Jenkins at https://${ip_public}"
echo "Initial Admin Password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword || exit_with_error "Failed to retrieve Jenkins initialAdminPassword."
