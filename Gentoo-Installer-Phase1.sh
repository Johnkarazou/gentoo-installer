#!/bin/bash
#
# Gentoo Zen Installer - Phase 1
# Author: JohnKarazou
# Version: 1.3
#
# This script automates the initial phase of a Gentoo Linux installation.
# It handles user configuration, hardware detection, partitioning,
# and prepares the system for a reboot, after which Phase 2 will take over.
#

# --- Safety & Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error
set -u
# If any command in a pipeline fails, the pipeline's return status is the value of the last command to exit with a non-zero status
set -o pipefail

# --- Trap for Graceful Exit ---
# This function is called when the user presses Ctrl+C.
function on_interrupt() {
    echo -e "\n\n\e[1;31m>>> INSTALLATION INTERRUPTED! <<<\e[0m"
    echo "All progress up to the last completed step has been saved."
    echo "To resume from where you left off, simply run the script again:"
    echo -e "    \e[1;32msudo ./${0}\e[0m"
    # Disabling the exit-on-error temporarily to allow potential cleanup
    set +e
    # Attempt to unmount everything cleanly
    umount -R /mnt/gentoo 2>/dev/null || true
    exit 1
}
trap 'on_interrupt' INT

# --- UI & Helper Functions ---
function print_header() {
    echo -e "\n\e[1;35m#\n# $1\n#\e[0m"
}
function print_error() { echo -e "\e[1;31m[ERROR] $1\e[0m" >&2; }
function print_success() { echo -e "\e[1;32m[OK] $1\e[0m"; }
function print_info() { echo -e "\e[1;34m[INFO] $1\e[0m"; }

# --- State & Config Management ---
CHROOT_DIR="/mnt/gentoo"
STATE_FILE="${CHROOT_DIR}/.install_state"
CONFIG_FILE="${CHROOT_DIR}/.install_config"

function update_state() { echo "$1=true" >> "${STATE_FILE}"; print_success "State updated: $1."; }
function check_state() {
    [ ! -f "${STATE_FILE}" ] && return 1
    grep -q "^$1=true$" "${STATE_FILE}"
}

# FIX: Load saved configuration variables from a file
function load_configuration() {
    if [ -f "${CONFIG_FILE}" ]; then
        print_info "Previous configuration found. Loading settings..."
        source "${CONFIG_FILE}"
        print_success "Settings loaded."
    fi
}

# FIX: Save configuration variables to a file
function save_configuration() {
    print_info "Saving installation configuration..."
    # Create the config file, ensuring passwords are quoted to handle special characters
    cat > "${CONFIG_FILE}" <<EOF
# Gentoo Installer Configuration
GENTOO_USER='${GENTOO_USER}'
GENTOO_USER_PASSWORD='${GENTOO_USER_PASSWORD}'
GENTOO_ROOT_PASSWORD='${GENTOO_ROOT_PASSWORD}'
GENTOO_HOSTNAME='${GENTOO_HOSTNAME}'
GENTOO_TIMEZONE='${GENTOO_TIMEZONE}'
GENTOO_LOCALE='${GENTOO_LOCALE}'
GENTOO_PROFILE='${GENTOO_PROFILE}'
ROOT_FS='${ROOT_FS}'
TARGET_DISK='${TARGET_DISK}'
EOF
    print_success "Configuration saved to ${CONFIG_FILE}"
}


# --- Pre-flight Checks ---
function run_preflight_checks() {
    print_header "Running Pre-flight Checks"
    if [ "${EUID}" -ne 0 ]; then
        print_error "This script must be run as root. Please use 'sudo'."
        exit 1
    fi
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        print_error "No internet connection. Please connect to the internet and try again."
        exit 1
    fi
    for tool in curl lsblk sgdisk nproc dmidecode lspci; do
        if ! command -v $tool &> /dev/null;
            then print_error "Required command '$tool' not found. Please use a standard Gentoo live environment."
            exit 1
        fi
    done
    print_success "All pre-flight checks passed."
}

# --- Interactive Configuration ---
function gather_user_input() {
    print_header "Gathering System Configuration"

    read -p "Enter your desired username: " GENTOO_USER

    while true; do
        read -s -p "Enter a password for '$GENTOO_USER': " GENTOO_USER_PASSWORD
        echo
        read -s -p "Confirm user password: " GENTOO_USER_PASSWORD_CONFIRM
        echo
        [ "$GENTOO_USER_PASSWORD" = "$GENTOO_USER_PASSWORD_CONFIRM" ] && break
        print_error "Passwords do not match. Please try again."
    done

    read -p "Use the same password for the 'root' account? (y/n): " use_same_password
    if [[ "$use_same_password" == "y" || "$use_same_password" == "Y" ]]; then
        GENTOO_ROOT_PASSWORD=$GENTOO_USER_PASSWORD
    else
        while true; do
            read -s -p "Enter a password for the 'root' user: " GENTOO_ROOT_PASSWORD
            echo
            read -s -p "Confirm root password: " GENTOO_ROOT_PASSWORD_CONFIRM
            echo
            [ "$GENTOO_ROOT_PASSWORD" = "$GENTOO_ROOT_PASSWORD_CONFIRM" ] && break
            print_error "Passwords do not match. Please try again."
        done
    fi

    read -p "Enter the hostname for this computer (e.g., gentoo-desktop): " GENTOO_HOSTNAME
    read -p "Enter your Timezone (e.g., Europe/Athens): " GENTOO_TIMEZONE
    read -p "Enter your desired locale (e.g., en_US.UTF-8): " GENTOO_LOCALE

    print_info "Choose an installation profile:"
    select profile_choice in "Minimal (KDE Desktop + Tools)" "Standard (Minimal + Office/Media)" "Full (Standard + All Extras)"; do
        case $profile_choice in
            "Minimal (KDE Desktop + Tools)") GENTOO_PROFILE="minimal"; break;;
            "Standard (Minimal + Office/Media)") GENTOO_PROFILE="standard"; break;;
            "Full (Standard + All Extras)") GENTOO_PROFILE="full"; break;;
            *) print_error "Invalid option. Please choose 1, 2, or 3.";;
        esac
    done

    print_info "Choose a filesystem for your root partition:"
    select fs_choice in "ext4" "btrfs" "xfs"; do
        if [[ -n "$fs_choice" ]]; then
            ROOT_FS=$fs_choice
            break
        else
            print_error "Invalid option. Please choose 1, 2, or 3."
        fi
    done

    print_info "Detecting available disks..."
    mapfile -t disks < <(lsblk -d -n -o NAME,SIZE,MODEL,TYPE | awk '$4 == "disk" {printf "%-10s %-10s %s\n", $1, $2, $3}')
    echo "Please select the target disk for Gentoo installation:"
    select disk_line in "${disks[@]}"; do
        if [[ -n "$disk_line" ]]; then
            TARGET_DISK_NAME=$(echo "$disk_line" | awk '{print $1}')
            TARGET_DISK="/dev/${TARGET_DISK_NAME}"
            break
        else
            print_error "Invalid selection. Please try again."
        fi
    done

    print_header "Installation Summary"
    echo "Username:          $GENTOO_USER"
    echo "Hostname:          $GENTOO_HOSTNAME"
    echo "Timezone:          $GENTOO_TIMEZONE"
    echo "Locale:            $GENTOO_LOCALE"
    echo "Profile:           $GENTOO_PROFILE"
    echo "Target Disk:       $TARGET_DISK"
    echo "Root Filesystem:   $ROOT_FS"
    echo -e "\n\e[1;31mWARNING: All data on ${TARGET_DISK} will be destroyed!\e[0m"
    read -p "To proceed, type 'YES, I AM SURE': " confirmation
    if [ "$confirmation" != "YES, I AM SURE" ]; then
        print_error "Confirmation failed. Aborting installation."
        exit 1
    fi
    
    # FIX: Save configuration after user confirms
    save_configuration
}

# --- Automated Steps ---
function execute_partitioning() {
    print_header "Partitioning Disk: ${TARGET_DISK}"
    sgdisk --zap-all ${TARGET_DISK}
    sgdisk --new=1:0:+600M --typecode=1:ef00 --change-name=1:'EFI System' ${TARGET_DISK}
    sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:'Gentoo Root' ${TARGET_DISK}
    partprobe ${TARGET_DISK}
    sleep 2

    if [[ $TARGET_DISK == *"nvme"* ]]; then
        EFI_PARTITION="${TARGET_DISK}p1"
        ROOT_PARTITION="${TARGET_DISK}p2"
    else
        EFI_PARTITION="${TARGET_DISK}1"
        ROOT_PARTITION="${TARGET_DISK}2"
    fi

    print_info "EFI Partition: ${EFI_PARTITION}"
    print_info "Root Partition: ${ROOT_PARTITION}"

    print_info "Formatting partitions..."
    mkfs.vfat -F 32 "${EFI_PARTITION}"
    case "$ROOT_FS" in
        ext4) mkfs.ext4 -L "GENTOO_ROOT" "${ROOT_PARTITION}";;
        btrfs) mkfs.btrfs -L "GENTOO_ROOT" "${ROOT_PARTITION}";;
        xfs) mkfs.xfs -L "GENTOO_ROOT" "${ROOT_PARTITION}";;
    esac
    print_success "Disk partitioning and formatting complete."
}

function mount_filesystems() {
    print_header "Mounting Filesystems"
    if [[ $TARGET_DISK == *"nvme"* ]]; then
        EFI_PARTITION="${TARGET_DISK}p1"
        ROOT_PARTITION="${TARGET_DISK}p2"
    else
        EFI_PARTITION="${TARGET_DISK}1"
        ROOT_PARTITION="${TARGET_DISK}2"
    fi

    mount "${ROOT_PARTITION}" ${CHROOT_DIR}
    mkdir -p "${CHROOT_DIR}/efi"
    mount "${EFI_PARTITION}" "${CHROOT_DIR}/efi"
    print_success "Filesystems mounted."
}

function download_and_extract_stage3() {
    print_header "Downloading and Extracting Stage3"
    cd ${CHROOT_DIR}
    local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
    local pointer_file="latest-stage3-amd64-desktop-openrc.txt"
    print_info "Finding the latest stage3 tarball..."
    local latest_info=$(curl -s "${base_url}${pointer_file}" | grep '\.tar\.xz$')
    local stage3_path=$(echo "${latest_info}" | awk '{print $1}')
    local stage3_url="${base_url}${stage3_path}"
    
    print_info "Downloading from: ${stage3_url}"
    wget -c "${stage3_url}"
    
    print_info "Extracting stage3 (this may take a while)..."
    tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
    rm stage3-*.tar.xz
    print_success "Stage3 download and extraction complete."
}

function configure_chroot() {
    print_header "Configuring Chroot Environment"
    cp --dereference /etc/resolv.conf "${CHROOT_DIR}/etc/"

    print_info "Generating make.conf..."
    local nproc=$(nproc)
    local video_cards="amdgpu"
    mkdir -p "${CHROOT_DIR}/etc/portage"
    cat > "${CHROOT_DIR}/etc/portage/make.conf" <<EOF
# Generated by Gentoo Zen Installer
CARCH="x86_64"
CHOST="x86_64-pc-linux-gnu"
COMMON_FLAGS="-march=native -O3 -pipe -flto=${nproc} -fgraphite-identity -floop-nest-optimize"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
LDFLAGS="-Wl,-O1 -Wl,--as-needed"
MAKEOPTS="-j${nproc} -l${nproc}"
VIDEO_CARDS="${video_cards}"
ACCEPT_LICENSE="*"
GRUB_PLATFORMS="efi-64"
USE="X acl alsa amdgpu bluetooth cups dbus egl elogind pulseaudio udev unicode vulkan wayland"
EOF
    mount --types proc /proc "${CHROOT_DIR}/proc"
    mount --rbind /sys "${CHROOT_DIR}/sys"
    mount --rbind /dev "${CHROOT_DIR}/dev"
    print_success "Chroot configured."
}

function generate_phase2_script() {
    print_header "Generating Phase 2 Installer Script"
    # This is a simplified version for demonstration. A real script would be much larger.
    cat > "${CHROOT_DIR}/root/phase2_chroot_install.sh" <<'EOF'
#!/bin/bash
set -e
set -u
set -o pipefail
trap 'on_interrupt_phase2' INT
function on_interrupt_phase2() {
    echo -e "\n\n"
    echo "================================================================="
    echo "      >>> PHASE 2 INSTALLATION INTERRUPTED! <<<"
    echo "================================================================="
    echo -e "\nDon't worry, your progress up to the last completed step is saved."
    # ... more detailed message ...
    exit 1
}
source /etc/profile
export PS1="(chroot) ${PS1}"
print_info() { echo -e "\e[1;34m[INFO] $1\e[0m"; }
emerge-webrsync
emerge --sync
eselect profile set default/linux/amd64/17.1/desktop/plasma/openrc
emerge -vuDN @world
emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware
# This is a placeholder for the full kernel compile, package installs etc.
print_info "Phase 2 placeholder complete. System would be built here."
# Clean up runonce service
rm /etc/init.d/runonce-installer
rc-update del runonce-installer default
echo "INSTALLATION COMPLETE!"
EOF
    chmod +x "${CHROOT_DIR}/root/phase2_chroot_install.sh"
    print_success "Phase 2 script generated."
}

function prepare_for_reboot() {
    print_header "Preparing System for First Reboot"
    cat > "${CHROOT_DIR}/prepare_reboot.sh" <<EOF
#!/bin/bash
set -e
source /etc/profile
export PS1="(chroot) \${PS1}"
emerge-webrsync
emerge --sync
emerge sys-boot/grub:2
# Minimal kernel for first boot
cd /usr/src/linux
make defconfig
make -j$(nproc) && make modules_install && make install
# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg
# Create and enable the runonce service for Phase 2
cat > /etc/init.d/runonce-installer <<'EOT'
#!/sbin/openrc-run
depend() {
    need localmount net
}
start() {
    ebegin "Starting Phase 2 Installation"
    /root/phase2_chroot_install.sh &> /root/phase2_install.log
    eend \$?
}
EOT
chmod +x /etc/init.d/runonce-installer
rc-update add runonce-installer default
EOF
    chmod +x "${CHROOT_DIR}/prepare_reboot.sh"
    chroot ${CHROOT_DIR} /prepare_reboot.sh
    print_success "System is ready for reboot."
}

# --- Main Execution Flow ---
function main() {
    run_preflight_checks
    
    mkdir -p ${CHROOT_DIR}
    touch "${STATE_FILE}"

    # FIX: Load configuration at the start to handle resumes
    load_configuration

    if ! check_state "USER_INPUT_COMPLETE"; then
        gather_user_input # This function now saves the config
        update_state "USER_INPUT_COMPLETE"
    fi

    if ! check_state "PARTITIONING_COMPLETE"; then
        execute_partitioning
        update_state "PARTITIONING_COMPLETE"
    fi

    if ! check_state "FILESYSTEMS_MOUNTED"; then
        mount_filesystems
        update_state "FILESYSTEMS_MOUNTED"
    fi

    if ! check_state "STAGE3_EXTRACTED"; then
        download_and_extract_stage3
        update_state "STAGE3_EXTRACTED"
    fi

    if ! check_state "CHROOT_CONFIGURED"; then
        configure_chroot
        update_state "CHROOT_CONFIGURED"
    fi

    if ! check_state "PHASE2_SCRIPT_GENERATED"; then
        generate_phase2_script
        update_state "PHASE2_SCRIPT_GENERATED"
    fi

    if ! check_state "REBOOT_PREPARED"; then
        prepare_for_reboot
        update_state "REBOOT_PREPARED"
    fi

    print_header "PHASE 1 COMPLETE"
    echo -e "\nThe system is now ready to reboot into your new Gentoo installation."
    echo "Phase 2 of the installation will begin automatically after reboot."
    echo "Please remove the installation media now."
    read -p "Press ENTER to unmount filesystems and reboot..."
    
    umount -R ${CHROOT_DIR}
    echo "Rebooting in 5 seconds..."
    sleep 5
    reboot
}

main "$@"
