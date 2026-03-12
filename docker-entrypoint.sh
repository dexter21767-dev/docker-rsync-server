#!/bin/bash
set -e

is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

setup_ssh() {
  local ssh_password_auth
  local group_name
  local user_group
  local user_home
  local user_uid
  local tmp_authorized_keys

  ssh_password_auth="no"
  if is_true "${SSH_PASSWORD_AUTH}"; then
    ssh_password_auth="yes"
  fi

  group_name="$(awk -F: -v gid="${GROUP_ID}" '$3 == gid { print $1; exit }' /etc/group)"
  if [ -z "${group_name}" ]; then
    group_name="${USERNAME}"
    if ! awk -F: -v name="${group_name}" '$1 == name { found=1 } END { exit !found }' /etc/group; then
      addgroup -g "${GROUP_ID}" "${group_name}" >/dev/null 2>&1 || true
    fi
  fi

  if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    if awk -F: -v uid="${OWNER_ID}" '$3 == uid { found=1 } END { exit !found }' /etc/passwd; then
      adduser -D -h "${VOLUME_PATH}" -s /bin/sh -G "${group_name}" "${USERNAME}" >/dev/null 2>&1 || true
    else
      adduser -D -h "${VOLUME_PATH}" -s /bin/sh -u "${OWNER_ID}" -G "${group_name}" "${USERNAME}" >/dev/null 2>&1 || true
    fi
  fi

  if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    echo "Could not create or resolve SSH user '${USERNAME}'"
    exit 1
  fi

  user_home="$(awk -F: -v user="${USERNAME}" '$1 == user { print $6; exit }' /etc/passwd)"
  user_group="$(id -gn "${USERNAME}")"
  user_uid="$(id -u "${USERNAME}")"

  mkdir -p /var/run/sshd
  ssh-keygen -A

  if [ "${ssh_password_auth}" = "yes" ] && [ -n "${SSH_PASSWORD}" ]; then
    if command -v chpasswd >/dev/null 2>&1; then
      echo "${USERNAME}:${SSH_PASSWORD}" | chpasswd
    else
      echo "chpasswd not found, cannot set SSH_PASSWORD for user '${USERNAME}'"
      exit 1
    fi
  fi

  mkdir -p "${user_home}/.ssh"
  chmod 700 "${user_home}/.ssh"
  chown "${user_uid}:${user_group}" "${user_home}/.ssh"

  if [ -n "${SSH_MOUNTED_KEYS_DIR}" ] && [ -d "${SSH_MOUNTED_KEYS_DIR}" ]; then
    if [ -f "${SSH_MOUNTED_KEYS_DIR}/authorized_keys" ]; then
      cat "${SSH_MOUNTED_KEYS_DIR}/authorized_keys" >> "${user_home}/.ssh/authorized_keys"
    fi
    if [ -f "${SSH_MOUNTED_KEYS_DIR}/known_hosts" ]; then
      cp "${SSH_MOUNTED_KEYS_DIR}/known_hosts" "${user_home}/.ssh/known_hosts"
      chown "${user_uid}:${user_group}" "${user_home}/.ssh/known_hosts"
      chmod 644 "${user_home}/.ssh/known_hosts"
    fi
  fi

  if [ -n "${SSH_PUBLIC_KEY}" ]; then
    printf '%b\n' "${SSH_PUBLIC_KEY}" >> "${user_home}/.ssh/authorized_keys"
  fi

  if [ -f "${user_home}/.ssh/authorized_keys" ]; then
    tmp_authorized_keys="$(mktemp)"
    awk 'NF && !seen[$0]++' "${user_home}/.ssh/authorized_keys" > "${tmp_authorized_keys}"
    mv "${tmp_authorized_keys}" "${user_home}/.ssh/authorized_keys"
    chown "${user_uid}:${user_group}" "${user_home}/.ssh/authorized_keys"
    chmod 600 "${user_home}/.ssh/authorized_keys"
  fi

  cat > /etc/ssh/sshd_config <<EOF
Port ${SSH_PORT}
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication ${ssh_password_auth}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PrintMotd no
X11Forwarding no
AllowTcpForwarding no
Subsystem sftp internal-sftp
AllowUsers ${USERNAME}
PidFile /var/run/sshd.pid
EOF
}

# Allow to run complementary processes or to enter the container without
# running this init script.
if [ "$1" = "/usr/bin/rsync" ] || [ "$1" = "rsync" ]; then

  # Ensure time is in sync with host
  # see https://wiki.alpinelinux.org/wiki/Setting_the_timezone
  if [ -n "${TZ}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
  fi

  # Defaults
  VOLUME_PATH="${VOLUME_PATH:-/docker}"
  HOSTS_ALLOW="${HOSTS_ALLOW:-0.0.0.0/0}"
  READ_ONLY="${READ_ONLY:-false}"
  CHROOT="${CHROOT:-no}"
  VOLUME_NAME="${VOLUME_NAME:-volume}"
  USERNAME="${USERNAME:-rsyncuser}"
  ENABLE_RSYNCD="${ENABLE_RSYNCD:-true}"
  ENABLE_SSH="${ENABLE_SSH:-false}"
  SSH_PORT="${SSH_PORT:-22}"
  SSH_PASSWORD_AUTH="${SSH_PASSWORD_AUTH:-true}"
  SSH_PASSWORD="${SSH_PASSWORD:-${PASSWORD}}"
  SSH_MOUNTED_KEYS_DIR="${SSH_MOUNTED_KEYS_DIR:-/home/.ssh}"

  # Ensure VOLUME PATH exists
  if [ ! -e "${VOLUME_PATH}" ]; then
    mkdir -p "${VOLUME_PATH}"
  fi

  # Grab UID of owner of the volume directory
  if [ -z "${OWNER_ID}" ]; then
    OWNER_ID="$(stat -c '%u' "${VOLUME_PATH}")"
  else
    echo "OWNER_ID is set forced to: $OWNER_ID"
  fi
  if [ -z "${GROUP_ID}" ]; then
    GROUP_ID="$(stat -c '%g' "${VOLUME_PATH}")"
  else
    echo "GROUP_ID is set forced to: $GROUP_ID"
  fi

  # Generate password file
  if [ -n "${PASSWORD}" ]; then
    echo "$USERNAME:$PASSWORD" >  /etc/rsyncd.secrets
    chmod 600 /etc/rsyncd.secrets
  fi

  # Generate configuration
  eval "echo \"$(cat /rsyncd.tpl.conf)\"" > /etc/rsyncd.conf

  if is_true "${ENABLE_SSH}"; then
    setup_ssh
  fi

  # Check if a script is available in /docker-entrypoint.d and source it
  # You can use it for example to create additional sftp users
  for f in /docker-entrypoint.d/*; do
    case "$f" in
      *.sh)  echo "$0: running $f"; . "$f" ;;
      *)     echo "$0: ignoring $f" ;;
    esac
  done

  if is_true "${ENABLE_SSH}" && ! is_true "${ENABLE_RSYNCD}"; then
    exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
  fi

  if is_true "${ENABLE_SSH}" && is_true "${ENABLE_RSYNCD}"; then
    /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config &
  fi

  if ! is_true "${ENABLE_RSYNCD}"; then
    echo "ENABLE_RSYNCD is false and ENABLE_SSH is not enabled. Nothing to run."
    exit 1
  fi

fi

exec "$@"
