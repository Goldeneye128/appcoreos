# Minimal immutable appliance image built in Fedora bootc style.
FROM quay.io/fedora/fedora-bootc:43

# Install only the packages required for this bootstrap phase.
# - podman: container runtime (used later via Quadlet)
# - yq: parse machine-config YAML
# - curl: remote config + API fetches
# - python3: local debug HTTP server for agent
# - NetworkManager: single networking stack (nmcli for DHCP/static)
# - systemd: service orchestration
RUN dnf -y install \
      podman \
      yq \
      curl \
      python3 \
      NetworkManager \
      systemd \
    && dnf -y remove openssh-server openssh-clients \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Copy our appliance filesystem overlay into the image.
COPY rootfs/ /

# Make systemd container-aware when running as an OCI container for testing.
ENV container=oci

# Ensure scripts are executable, ensure runtime path exists,
# and enable early-boot machine-config processing.
RUN chmod 0755 /usr/local/bin/apply-machine-config.sh /usr/lib/your-os/bootstrap-machine-config.sh \
    && chmod 0755 /usr/lib/your-os/generate-containers.sh \
    && chmod 0755 /usr/lib/your-os/generate-state.sh \
    && chmod 0755 /usr/lib/your-os/update-os.sh \
    && chmod 0755 /usr/lib/your-os/init-machine-id.sh \
    && chmod 0755 /usr/lib/your-os/agent.sh \
    && chmod 0755 /usr/lib/your-os/agent-debug-server.py \
    && chmod 0755 /usr/lib/your-os/tui.sh \
    && systemctl mask sshd.service sshd.socket \
    && rm -f /usr/lib/systemd/system/sshd* /etc/systemd/system/sshd* \
    && (systemctl mask getty.target || true) \
    && (systemctl mask getty@.service || true) \
    && (systemctl mask serial-getty@.service || true) \
    && (systemctl mask console-getty.service || true) \
    && (systemctl mask rescue.service || true) \
    && (systemctl mask emergency.service || true) \
    && if [ -e /sbin/agetty ]; then chmod 000 /sbin/agetty; fi \
    && mkdir -p /var/lib/your-os \
    && mkdir -p /etc/containers/systemd \
    && sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME=\"App CoreOS 43\"/' /etc/os-release \
    && sed -i 's/^NAME=.*/NAME=\"AppCoreOS\"/' /etc/os-release \
    && systemctl enable machine-config.service containers.service podman-auto-update.timer state.timer update-os.timer machine-id.service agent.service tui.service

# systemd as PID 1 for containerized test runs.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
