# Minimal immutable appliance image inspired by Universal Blue workflows,
# based directly on Fedora CoreOS.
FROM quay.io/fedora/fedora-coreos:stable

# Install only the packages required for this bootstrap phase.
# - podman: container runtime (Quadlet)
# - yq: parse machine-config YAML
# - curl/python3: agent + debug server
# - NetworkManager: single networking stack
# - tmux/podman-compose/firewalld: useful VM host tools
# - guest agents: qemu/open-vm/hyper-v support
RUN dnf -y install \
      bootc \
      podman \
      curl \
      python3 \
      NetworkManager \
      systemd \
      tmux \
      podman-compose \
      firewalld \
      qemu-guest-agent \
      open-vm-tools \
      hyperv-daemons \
    && (dnf -y remove \
      openssh-server \
      openssh-clients \
      'cockpit*' \
      'docker*' \
      moby-engine \
      tailscale \
      wireguard-tools || true) \
    && curl -fL --retry 3 --retry-delay 2 \
      "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64" \
      -o /usr/bin/yq \
    && chmod 0755 /usr/bin/yq \
    && dnf clean all \
    && rm -rf /var/cache/dnf

# Copy our appliance filesystem overlay into the image.
COPY system_files/ /

# Make systemd container-aware when running as an OCI container for testing.
ENV container=oci

# Ensure scripts are executable, ensure runtime path exists,
# and enable early-boot machine-config processing.
RUN chmod 0755 /usr/lib/appcoreos/apply-machine-config.sh /usr/lib/appcoreos/bootstrap-machine-config.sh \
    && chmod 0755 /usr/lib/appcoreos/generate-containers.sh \
    && chmod 0755 /usr/lib/appcoreos/generate-state.sh \
    && chmod 0755 /usr/lib/appcoreos/init-machine-id.sh \
    && chmod 0755 /usr/lib/appcoreos/agent.sh \
    && chmod 0755 /usr/lib/appcoreos/agent-debug-server.py \
    && chmod 0755 /usr/lib/appcoreos/tui.sh \
    && rm -f /usr/lib/systemd/system-generators/systemd-getty-generator || true \
    && rm -f /usr/lib/systemd/system-generators/systemd-ssh-generator || true \
    && rm -f /usr/lib/systemd/system/coreos-touch-run-agetty.service || true \
    && rm -f /usr/lib/systemd/system/coreos-check-ssh-keys.service || true \
    && rm -f /usr/lib/systemd/system/sshd* || true \
    && rm -f /etc/systemd/system/sshd* || true \
    && (systemctl mask sshd.service || true) \
    && (systemctl mask sshd.socket || true) \
    && (systemctl mask sshd-vsock.socket || true) \
    && (systemctl mask ssh-access.target || true) \
    && (systemctl disable zincati.service zincati.timer || true) \
    && (systemctl mask zincati.service zincati.timer || true) \
    && (systemctl mask getty.target || true) \
    && (systemctl mask getty@.service || true) \
    && (systemctl mask serial-getty@.service || true) \
    && (systemctl mask console-getty.service || true) \
    && (systemctl mask coreos-touch-run-agetty.service || true) \
    && (systemctl mask coreos-check-ssh-keys.service || true) \
    && (systemctl mask getty@tty1.service || true) \
    && (systemctl mask serial-getty@ttyS0.service || true) \
    && mkdir -p /var/lib/appcoreos \
    && mkdir -p /etc/containers/systemd \
    && sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME=\"App CoreOS 43\"/' /etc/os-release \
    && sed -i 's/^NAME=.*/NAME=\"AppCoreOS\"/' /etc/os-release \
    && (systemctl preset-all || true) \
    && (systemctl enable bootc-fetch-apply-updates.timer || true) \
    && systemctl enable appcore.target machine-config.service containers.service podman-auto-update.timer state.timer machine-id.service agent.service tui.service

# systemd as PID 1 for containerized test runs.
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
