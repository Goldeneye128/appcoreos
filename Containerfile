# Minimal immutable appliance image built in Fedora bootc style.
FROM quay.io/fedora/fedora-bootc:41

# Install only the packages required for this bootstrap phase.
# - podman: container runtime (used later via Quadlet)
# - yq: parse machine-config YAML
# - NetworkManager: single networking stack (nmcli for DHCP/static)
# - systemd: service orchestration
RUN dnf -y install \
      podman \
      yq \
      NetworkManager \
      systemd \
    && dnf -y remove openssh-server \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Copy our appliance filesystem overlay into the image.
COPY rootfs/ /

# Ensure scripts are executable, ensure runtime path exists,
# and enable early-boot machine-config processing.
RUN chmod 0755 /usr/local/bin/apply-machine-config.sh /usr/lib/your-os/bootstrap-machine-config.sh \
    && chmod 0755 /usr/lib/your-os/generate-containers.sh \
    && chmod 0755 /usr/lib/your-os/generate-state.sh \
    && chmod 0755 /usr/lib/your-os/update-os.sh \
    && chmod 0755 /usr/lib/your-os/init-machine-id.sh \
    && chmod 0755 /usr/lib/your-os/agent.sh \
    && chmod 0755 /usr/lib/your-os/tui.sh \
    && mkdir -p /var/lib/your-os \
    && mkdir -p /etc/containers/systemd \
    && systemctl mask getty@tty1.service \
    && systemctl enable machine-config.service containers.service podman-auto-update.timer state.timer update-os.timer machine-id.service agent.service tui.service
