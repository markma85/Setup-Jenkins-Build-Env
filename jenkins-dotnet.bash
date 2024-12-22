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
        *) echo "[WARNING] Unknown parameter passed: $1"; exit_with_error "Usage: $0 [--ip-public <ip>] [--docker-host <ip>]" ;;
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
    sudo apt clean
else
    echo "[INFO] wget is already installed."
fi

# Check if JDK is installed
if ! command_exists java; then
    echo "[INFO] Installing JDK..."
    # Check if tzdata is installed
    if ! dpkg -l | grep -q "^ii  tzdata "; then
        echo "[INFO] Installing tzdata..."
        sudo apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata || exit_with_error "tzdata installation failed."
        sudo apt clean
    else
        echo "[INFO] tzdata is already installed."
    fi
    sudo apt install -y fontconfig openjdk-17-jre || exit_with_error "JDK installation failed."
    sudo apt clean
    java --version || exit_with_error "JDK verification failed."
else
    echo "[INFO] JDK is already installed."
fi

# Check if Git is installed
if ! command_exists git; then
    echo "[INFO] Installing Git..."
    sudo apt-get install -y git || exit_with_error "Git installation failed."
    sudo apt clean
else
    echo "[INFO] Git is already installed."
fi

# Check if Jenkins is installed
if [[ ! -f /etc/init.d/jenkins && ! -f /lib/systemd/system/jenkins.service ]]; then
    echo "[INFO] Installing Jenkins..."
    sudo wget -q -O /usr/share/keyrings/jenkins-keyring.asc \
        https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key || exit_with_error "Failed to download Jenkins keyring."
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | \
        sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    sudo apt-get update || exit_with_error "Jenkins repository update failed."
    sudo apt-get install -y jenkins || exit_with_error "Jenkins installation failed."
    echo 'export JENKINS_HOME="/var/lib/jenkins"' | sudo tee -a /etc/profile.d/jenkins_env.sh > /dev/null
    source /etc/profile.d/jenkins_env.sh
    # Install suggested plugins
    if ! command -v jq &> /dev/null; then
        echo "[INFO] Installing jq..."
        sudo apt-get install -y jq || exit_with_error "jq installation failed."
        sudo apt clean
    else
        echo "[INFO] jq is already installed."
    fi

    # Process and install plugins
    echo "[INFO] Installing Jenkins plugins..."
    sudo wget -q -O /tmp/plugins.txt \
        https://raw.githubusercontent.com/markma85/Setup-Jenkins-Build-Env/refs/heads/main/plugins.txt || exit_with_error "Failed to download Jenkins plugins list."

    # download Jenkins Plugin Manager Cli from https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.2/jenkins-plugin-manager-2.13.2.jar
    sudo wget -q -O /var/lib/jenkins/jenkins-plugin-manager.jar \
        https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.2/jenkins-plugin-manager-2.13.2.jar || exit_with_error "Failed to download Jenkins Plugin Manager Cli."
    sudo chown jenkins:jenkins /var/lib/jenkins/jenkins-plugin-manager.jar
    sudo chmod 644 /var/lib/jenkins/jenkins-plugin-manager.jar

    sudo java -jar /var/lib/jenkins/jenkins-plugin-manager.jar --war /usr/share/java/jenkins.war --plugin-download-directory /var/lib/jenkins/plugins --plugin-file /tmp/plugins.txt --plugins delivery-pipeline-plugin:1.3.2 deployit-plugin || exit_with_error "Failed to install suggested plugins."
    sudo chown -R jenkins:jenkins /var/lib/jenkins
    sudo chmod -R 755 /var/lib/jenkins
    sudo apt clean
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
    sudo apt clean
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/jenkins-selfsigned.key \
        -out /etc/ssl/certs/jenkins-selfsigned.crt -subj "/CN=$ip_public" || exit_with_error "Failed to create self-signed certificate."

    cat << EOF | sudo tee /etc/nginx/sites-available/jenkins > /dev/null
upstream jenkins {
    keepalive 32;
    server 127.0.0.1:8080;
}
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 443 ssl;
    server_name $ip_public;

    ssl_certificate /etc/ssl/certs/jenkins-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/jenkins-selfsigned.key;

    root /usr/share/java/jenkins.war;
    access_log /var/log/nginx/jenkins_access.log;
    error_log /var/log/nginx/jenkins_error.log;

    ignore_invalid_headers off;

    location ~ "^/static/[0-9a-fA-F]{8}\/(.*)$" {
        rewrite "^/static/[0-9a-fA-F]{8}\/(.*)" /\$1 last;
    }
    location /userContent {
        root /var/lib/jenkins;
        if (!-f \$request_filename) {
            rewrite (.*) /$1 last;
            break;
        }
        sendfile on;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host '\$host';
        proxy_set_header X-Real-IP '\$remote_addr';
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
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
if ! dotnet tool list --tool-path /usr/lib/dotnet/tools | grep -q "dotnet-ef"; then
    echo "[INFO] Installing dotnet-ef..."
    sudo dotnet tool install --tool-path /usr/lib/dotnet/tools dotnet-ef || exit_with_error "Failed to install dotnet-ef."
    sudo apt clean
    sudo ln -s /usr/lib/dotnet/tools/dotnet-ef /usr/bin/dotnet-ef
    source /etc/profile.d/dotnet_env.sh
else
    echo "[INFO] dotnet-ef is already installed."
fi

# Check if NPM is installed
if ! command_exists npm; then
    echo "[INFO] Installing NPM..."
    sudo apt-get install -y npm || exit_with_error "NPM installation failed."
    sudo apt clean
else
    echo "[INFO] NPM is already installed."
fi

# Check if Docker CLI is installed
if ! command_exists docker; then
    echo "[INFO] Installing Docker client..."
    sudo apt-get install ca-certificates curl -y
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce-cli || exit_with_error "Docker client installation failed."
    sudo apt clean
    docker --version || exit_with_error "Docker client verification failed."
else
    echo "[INFO] Docker CLI is already installed."
fi

# Check if Docker Compose is installed
if ! command_exists docker-compose; then
    echo "[INFO] Installing Docker Compose..."
    sudo curl -SL https://github.com/docker/compose/releases/download/v2.32.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    # Verify Docker Compose installation, if fails, create a symbolic link
    docker-compose --version || sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
    # Verify Docker Compose installation
    docker-compose --version || exit_with_error "Docker Compose installation failed."
else
    echo "[INFO] Docker Compose is already installed."
fi

# Export docker host
echo "export DOCKER_HOST=$docker_host" | sudo tee -a /etc/profile.d/docker_env.sh > /dev/null

# Output Jenkins initial admin password
echo "[INFO] Setup complete. Access Jenkins at https://${ip_public}"
echo "Initial Admin Password:"
sudo cat /var/lib/jenkins/secrets/initialAdminPassword || exit_with_error "Failed to retrieve Jenkins initialAdminPassword."
