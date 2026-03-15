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
  local ssh_dir
  local authorized_keys_file
  local mounted_authorized_keys_file
  local generated_private_key
  local generated_public_key
  local random_password
  local unlock_password
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
      adduser -D -h "${SSH_USER_HOME}" -s /bin/sh -G "${group_name}" "${USERNAME}" >/dev/null 2>&1 || true
    else
      adduser -D -h "${SSH_USER_HOME}" -s /bin/sh -u "${OWNER_ID}" -G "${group_name}" "${USERNAME}" >/dev/null 2>&1 || true
    fi
  fi

  if ! id -u "${USERNAME}" >/dev/null 2>&1; then
    echo "Could not create or resolve SSH user '${USERNAME}'"
    exit 1
  fi

  user_home="$(awk -F: -v user="${USERNAME}" '$1 == user { print $6; exit }' /etc/passwd)"
  user_group="$(id -gn "${USERNAME}")"
  user_uid="$(id -u "${USERNAME}")"
  if [ -n "${SSH_DIR}" ]; then
    case "${SSH_DIR}" in
      /*) ssh_dir="${SSH_DIR}" ;;
      *) ssh_dir="${user_home}/${SSH_DIR}" ;;
    esac
  else
    ssh_dir="${user_home}/.ssh"
  fi
  authorized_keys_file="${ssh_dir}/authorized_keys"
  mounted_authorized_keys_file="${SSH_AUTHORIZED_KEYS_FILE}"
  generated_private_key="${ssh_dir}/id_ed25519"
  generated_public_key="${generated_private_key}.pub"

  mkdir -p /var/run/sshd
  ssh-keygen -A

  if [ "${ssh_password_auth}" = "yes" ] && [ -n "${SSH_PASSWORD}" ]; then
    if command -v chpasswd >/dev/null 2>&1; then
      echo "${USERNAME}:${SSH_PASSWORD}" | chpasswd
    else
      echo "chpasswd not found, cannot set SSH_PASSWORD for user '${USERNAME}'"
      exit 1
    fi
  elif [ "${ssh_password_auth}" = "yes" ]; then
    echo "SSH_PASSWORD_AUTH is enabled but SSH_PASSWORD is empty for user '${USERNAME}'"
    exit 1
  else
    # In key-only mode, ensure the account is not in a locked state.
    # PasswordAuthentication is disabled in sshd_config, so this does not enable password login.
    if [ -n "${SSH_PASSWORD}" ]; then
      unlock_password="${SSH_PASSWORD}"
    else
      random_password="$(dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '\n')"
      unlock_password="${random_password}"
    fi
    if command -v chpasswd >/dev/null 2>&1; then
      echo "${USERNAME}:${unlock_password}" | chpasswd
    else
      echo "chpasswd not found, cannot initialize SSH account for user '${USERNAME}'"
      exit 1
    fi
  fi

  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  chown "${user_uid}:${user_group}" "${ssh_dir}"

  if [ ! -f "${generated_private_key}" ] || [ ! -f "${generated_public_key}" ]; then
    rm -f "${generated_private_key}" "${generated_public_key}"
    ssh-keygen -q -t ed25519 -N '' -C "${USERNAME}@container" -f "${generated_private_key}"
  fi
  chown "${user_uid}:${user_group}" "${generated_private_key}" "${generated_public_key}"
  chmod 600 "${generated_private_key}"
  chmod 644 "${generated_public_key}"

  : > "${authorized_keys_file}"
  if [ -n "${mounted_authorized_keys_file}" ] && [ -f "${mounted_authorized_keys_file}" ]; then
    cat "${mounted_authorized_keys_file}" >> "${authorized_keys_file}"
  fi

  if [ -n "${SSH_PUBLIC_KEY}" ]; then
    printf '%b\n' "${SSH_PUBLIC_KEY}" >> "${authorized_keys_file}"
  fi

  if [ -s "${authorized_keys_file}" ]; then
    tmp_authorized_keys="$(mktemp)"
    awk 'NF && !seen[$0]++' "${authorized_keys_file}" > "${tmp_authorized_keys}"
    mv "${tmp_authorized_keys}" "${authorized_keys_file}"
    chown "${user_uid}:${user_group}" "${authorized_keys_file}"
    chmod 600 "${authorized_keys_file}"
  else
    rm -f "${authorized_keys_file}"
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
AuthorizedKeysFile ${authorized_keys_file}
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
  SSH_USER_HOME="${SSH_USER_HOME:-${VOLUME_PATH}}"
  SSH_DIR="${SSH_DIR:-${SSH_USER_HOME}/.ssh}"
  SSH_AUTHORIZED_KEYS_FILE="${SSH_AUTHORIZED_KEYS_FILE:-/authorized_keys}"

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
