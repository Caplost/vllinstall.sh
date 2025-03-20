#!/bin/bash

# K100-AI Driver and DTK Installation Script for Ubuntu
# This script checks for existing installations and manages the entire setup process

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${2}${1}${NC}"
}

# Function to check if command succeeded
check_status() {
    if [ $? -eq 0 ]; then
        print_message "$1 successful." "$GREEN"
    else
        print_message "Error: $1 failed. Exiting." "$RED"
        exit 1
    fi
}

# Function to confirm before proceeding with default 'y'
confirm_step() {
    while true; do
        read -p "$(echo -e ${YELLOW}$1 Continue? [Y/n]:${NC} )" yn
        yn=${yn:-y}  # Default to 'y' if the input is empty
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) print_message "Installation aborted by user." "$RED"; exit 0;;
            * ) echo "Please answer yes (Y) or no (n).";;
        esac
    done
}

# Function to check if dpkg is in a bad state and fix it
check_dpkg_state() {
    print_message "Checking package management system state..." "$YELLOW"
    
    # Try a simple dpkg operation to check if it's working
    if ! dpkg --configure -a --dry-run &>/dev/null; then
        print_message "Warning: Package management system (dpkg) is in an interrupted state." "$RED"
        print_message "This needs to be fixed before continuing." "$YELLOW"
        confirm_step "Run 'dpkg --configure -a' to fix the issue?"
        
        print_message "Running dpkg --configure -a..." "$YELLOW"
        sudo dpkg --configure -a
        
        if [ $? -eq 0 ]; then
            print_message "Package management system fixed." "$GREEN"
        else
            print_message "Failed to fix package management system. Please run 'sudo dpkg --configure -a' manually." "$RED"
            exit 1
        fi
    else
        print_message "Package management system state: OK" "$GREEN"
    fi
}

# Function to check if driver is already installed
check_driver_installed() {
    print_message "Checking if K100-AI driver is already installed..." "$YELLOW"
    
    if lsmod | grep -q hydcu; then
        print_message "K100-AI driver is already installed and loaded." "$GREEN"
        lsmod | grep hydcu
        return 0  # driver is installed
    else
        print_message "K100-AI driver is not currently loaded." "$YELLOW"
        
        # Check if the package is installed but not loaded
        if dpkg -l | grep -q rock-5.7.1; then
            print_message "Rock driver package is installed but not loaded. May need reboot." "$YELLOW"
            confirm_step "Would you like to continue with driver installation anyway?"
            return 1  # proceed with installation
        else
            print_message "Rock driver package is not installed." "$YELLOW"
            return 1  # driver is not installed
        fi
    fi
}

# Check if script is running with root privileges
if [ "$(id -u)" != "0" ]; then
    print_message "This script must be run as root. Please use sudo." "$RED"
    exit 1
fi

print_message "Starting K100-AI driver and DTK installation for Ubuntu..." "$GREEN"

# Check package management system state
check_dpkg_state

# Step 1: Update package lists
print_message "Step 1: Updating package lists..." "$YELLOW"
confirm_step "This will update your package lists."
apt update
# Check status but don't exit on failure for apt update
if [ $? -eq 0 ]; then
    print_message "Package list update successful." "$GREEN"
else
    print_message "Warning: Package list update failed." "$RED"
    print_message "This might be due to DNS or network issues. You may need to configure DNS manually." "$YELLOW"
    confirm_step "Continue despite apt update failure?"
fi

# Step 2: Install dependencies
print_message "Step 2: Installing required dependencies..." "$YELLOW"
confirm_step "This will install gcc, g++, cmake, automake, libelf-dev, pciutils, libdrm-dev, and more."
apt install -y gcc g++ cmake automake libelf-dev libdrm-amdgpu1 libtinfo5 pciutils libdrm-dev
apt install -y mlocate
apt install -y linux-headers-$(uname -r)
check_status "Dependencies installation"

# Check if driver is already installed
DRIVER_NEEDED=1
check_driver_installed
DRIVER_NEEDED=$?

if [ $DRIVER_NEEDED -eq 1 ]; then
    # Step 3: Download the driver
    print_message "Step 3: Checking for driver file..." "$YELLOW"
    
    # Define specific download URL
    DRIVER_URL="https://download.sourcefind.cn:65024/directlink/6/latest%E9%A9%B1%E5%8A%A8/dtk-24.04/rock-5.7.1-6.2.26-V1.5.aio.run"
    DRIVER_FILENAME=$(basename "$DRIVER_URL")
    
    # Check if rock*.run file exists in the current directory
    DRIVER_EXISTS=$(ls rock*.run 2>/dev/null | wc -l)
    
    if [ $DRIVER_EXISTS -gt 0 ]; then
        EXISTING_DRIVER=$(ls rock*.run | head -1)
        print_message "Found existing driver file: $EXISTING_DRIVER" "$GREEN"
        confirm_step "Do you want to use this existing driver file?"
        # Use the existing driver file
        cp "$EXISTING_DRIVER" ./rock-driver.run
        check_status "Using existing driver file"
    else
        print_message "No existing driver file found in current directory." "$YELLOW"
        print_message "Will download from: $DRIVER_URL" "$YELLOW"
        confirm_step "This will download the driver to the current directory."
        
        # Download the driver
        wget "$DRIVER_URL" -O "$DRIVER_FILENAME"
        check_status "Driver download"
        
        # Create a symbolic link to standardize filename for the rest of the script
        ln -sf "$DRIVER_FILENAME" rock-driver.run
        check_status "Creating driver link"
    fi
    
    # Step 4: Set execution permissions
    print_message "Step 4: Setting execution permissions..." "$YELLOW"
    confirm_step "This will set execution permissions on the downloaded driver file."
    chmod +x rock-driver.run
    check_status "Permission setting"
    
    # Step 5: Install the driver
    print_message "Step 5: Installing the driver..." "$GREEN"
    print_message "Note: When prompted about legacy hymgr config, select 'Y' to generate a new config or 'N' to keep existing config." "$YELLOW"
    print_message "Note: For K100-AI, you'll be prompted to update VBIOS. For first-time installation, it's recommended to select 'Y' and restart after installation." "$YELLOW"
    confirm_step "This will run the driver installer. You will need to respond to prompts during installation."
    
    ./rock-driver.run
    check_status "Driver installation"
    
    # Step 6: Restart the hymgr service
    print_message "Step 6: Restarting hymgr service..." "$YELLOW"
    confirm_step "This will restart the hymgr service to apply the driver changes."
    systemctl restart hymgr
    check_status "Service restart"
    
    print_message "Driver installation complete. A system reboot is recommended before continuing." "$GREEN"
    confirm_step "Would you like to continue with DTK installation now? (A reboot before DTK installation is recommended)"
else
    print_message "Skipping driver installation as it's already installed." "$GREEN"
fi

# Step 7: Install DTK Development Environment
print_message "Step 7: Install DTK Development Environment for Ubuntu 22.04?" "$YELLOW"
confirm_step "This will install the DTK development environment. Continue?"

print_message "Installing DTK dependencies..." "$YELLOW"
apt-get install -y make gcc g++ cmake git wget gfortran elfutils libdrm-dev
apt-get install -y kmod libtinfo5 sqlite3 libsqlite3-dev libelf-dev
apt-get install -y libnuma-dev libgl1-mesa-dev rpm rsync mesa-common-dev apt-utils
apt-get install -y cmake libpci-dev pciutils libpciaccess-dev libbabeltrace-dev pkg-config
apt-get install -y libfile-which-perl libfile-basedir-perl libfile-copy-recursive-perl libfile-listing-perl
apt-get install -y python3 python3-pip python3-dev python3-wheel
apt-get install -y gettext gettext-base libprotobuf-dev tcl
apt-get install -y libio-digest-perl libdigest-md5-file-perl libdata-dumper-simple-perl vim curl libcurlpp-dev
apt-get install -y doxygen graphviz texlive libncurses5 msgpack*

# Download DTK package
print_message "Downloading DTK package..." "$YELLOW"
DTK_URL="https://download.sourcefind.cn:65024/directlink/1/DTK-24.04.3/Ubuntu22.04/DTK-24.04.3-Ubuntu22.04-x86_64.tar.gz"
DTK_FILENAME=$(basename "$DTK_URL")

# Check if DTK package already exists
if [ -f "$DTK_FILENAME" ]; then
    print_message "DTK package $DTK_FILENAME already exists." "$GREEN"
    confirm_step "Use existing DTK package?"
else
    # Download DTK package
    wget "$DTK_URL" -O "$DTK_FILENAME"
    if [ $? -ne 0 ]; then
        print_message "Failed to download DTK package. Please check your network connection." "$RED"
        confirm_step "Continue despite DTK download failure?"
    fi
fi

# Extract DTK package
print_message "Extracting DTK package to /opt..." "$YELLOW"
tar xvf "$DTK_FILENAME" -C /opt
if [ $? -ne 0 ]; then
    print_message "Failed to extract DTK package." "$RED"
    confirm_step "Continue despite extraction failure?"
fi

# Create symbolic link
print_message "Creating symbolic link /opt/dtk..." "$YELLOW"
ln -sf /opt/dtk-24.04.3 /opt/dtk

# Setup DTK environment variables
print_message "Setting up DTK environment variables..." "$YELLOW"
print_message "1. You can source /opt/dtk/env.sh to temporarily load the DTK environment." "$GREEN"
print_message "2. Add 'source /opt/dtk/env.sh' to ~/.bashrc for permanent setup." "$GREEN"
print_message "3. Or use environment modules (recommended):" "$GREEN"

# Check if environment-modules is installed
if ! command -v module &> /dev/null; then
    print_message "Installing environment-modules..." "$YELLOW"
    apt-get install -y environment-modules
    if [ $? -ne 0 ]; then
        print_message "Failed to install environment-modules." "$RED"
    fi
fi

# Create a module file
print_message "Creating a DTK module file..." "$YELLOW"
MODULE_FILE="/usr/share/modules/modulefiles/dtk-24.04.3"
cat > "$MODULE_FILE" << 'EOF'
#%Module1.0
proc ModulesHelp { } {
puts stderr "DTK-24.04.3– DCU driver and runtime Toolkit"
}
module-whatis "DTK-24.04.3– DCU driver and runtime Toolkit, version 24.04.2"
conflict compiler/rocm
set ROCMVER version 24.04.2
set DTK_HOME [file dirname $ROCMVER]
setenv ROCM_PATH [file dirname $DTK_HOME]
setenv HIP_PATH [file dirname $DTK_HOME]
prepend-path PATH [file dirname $DTK_HOME]
prepend-path LD_LIBRARY_PATH [file dirname $DTK_HOME]
prepend-path C_INCLUDE_PATH [file dirname $DTK_HOME]
prepend-path CPLUS_INCLUDE_PATH [file dirname $DTK_HOME]
setenv MIOPEN_SYSTEM_DB_PATH [file dirname $DTK_HOME]
setenv HSA_FORCE_FINE_GRAIN_PCIE 1
EOF

print_message "DTK module file created: $MODULE_FILE" "$GREEN"
print_message "To load the DTK environment, use 'module load dtk-24.04.3'" "$GREEN"

# Add source command to bashrc
print_message "Do you want to add source command to ~/.bashrc for permanent setup?" "$YELLOW"
confirm_step "This will add 'source /opt/dtk/env.sh' to your ~/.bashrc file"
echo 'source /opt/dtk/env.sh' >> ~/.bashrc
print_message "Added source command to ~/.bashrc. It will be active after you log out and log back in or run 'source ~/.bashrc'" "$GREEN"

# Installation completed
print_message "Installation process completed." "$GREEN"
if [ $DRIVER_NEEDED -eq 1 ]; then
    print_message "If you chose to update VBIOS during installation, please restart your system now." "$YELLOW"
    print_message "A system reboot is recommended to ensure the driver is properly loaded." "$YELLOW"
fi
print_message "Your K100-AI driver with DTK should be ready to use." "$GREEN"
print_message "To verify your DTK installation, run 'source /opt/dtk/env.sh' (if not added to ~/.bashrc) and then 'rocminfo | grep -i zifang'" "$GREEN"