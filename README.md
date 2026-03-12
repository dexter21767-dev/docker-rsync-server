RSYNC server for docker
======================

## Description

This is a lightweight RSYNC server in a docker container.

This image provides:
 - an alpine base image
 - RSYNC server
 - Optional OpenSSH server for rsync-over-SSH
 - User creation based on env variable
 - Home directory based on env variable
 - Automatic UID detection based on home permissions
 - Ability to run in chroot
 - Password authentication
 - Hosts allowed / denied rules
 - Extensibility through additional sh scripts (more users creation, tweak...)


## How to use

### Provided example

A full example is provided in the [docker-compose file](https://github.com/mickaelperrin/docker-rsync-server/blob/master/docker-compose.yml)

    git clone https://github.com/mickaelperrin/docker-rsync-server.git
    cd docker-rsync-server
    docker-compose up

### Generic example

    version: '2'

    services:
      # Example application container, this is where your data is.
      app:
        image: alpine:3.5
        # Simulate an application server with an endless loop.
        command: sh -c 'while true; do sleep 10; done';
        volumes:
          - ./data:/data
      # RSYNCD Server
      rsyncd:
        build: .
        image: mickaelperrin/rsyncd-server:latest
        environment:
          # REQUIRED: For user/password authentication
          - USERNAME=sftp
          - PASSWORD=password
          # REQUIRED: Should be the same as the volume mapping of app container
          - VOLUME_PATH=/data
          # OPTIONAL: If you want to restrict access to the volume in read only mode. (default false)
          - READ_ONLY=false
          # OPTIONAL: If you want to chroot the use of rsync. Be sure that your directory structure is compatible.
          # See documentation
          # (default no)
          - CHROOT=yes
          # OPTIONAL: customize the volume name in rsync (default: volume)
          - VOLUME_NAME=data
          # OPTIONAL: restrict connection from (default: 0.0.0.0/0)
          - HOSTS_ALLOW=0.0.0.0/0
          # OPTIONAL: define the user name or user ID that file transfers to and from that module should take place
          # (default set to UID owner of VOLUME_PATH)
          # - OWNER_ID = 1000
          # OPTIONAL: specifies one or more group names/IDs that will be used when accessing the module. The first one will be the default group, and any extra ones be set as supplemental groups.
          # (default set to GID owner of VOLUME_PATH)
          # - GROUP_ID = 1000
          # OPTIONAL: enable SSH server for rsync-over-SSH (default false)
          - ENABLE_SSH=false
          # OPTIONAL: disable rsync daemon if you only want SSH transport (default true)
          - ENABLE_RSYNCD=true
          # OPTIONAL: SSH password for USERNAME (default: PASSWORD)
          # - SSH_PASSWORD=password
          # OPTIONAL: enable password auth in SSH server (default true)
          - SSH_PASSWORD_AUTH=true
          # OPTIONAL: SSH user home directory (default: VOLUME_PATH)
          # - SSH_USER_HOME=/home/sftp
          # OPTIONAL: final SSH directory used by sshd (default: SSH_USER_HOME/.ssh)
          # - SSH_DIR=/home/sftp/.ssh
          # OPTIONAL: one or more public keys for USERNAME (supports '\n' between keys)
          # - SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
        ports:
          - 18873:873
          - 12222:22
        volumes_from:
          - app

### Configuration

Configuration is done through environment variables. 

Required:
- USERNAME: the name to be use for login.
- PASSWORD: the password to login.
- VOLUME_PATH: rsync module path and default SSH user home.

Optionnal:
- CHROOT (default no): if set to yes, enable chroot of user (prevent access to other folders than its home folder). Be aware, that 
currently this feature can leads to unexpected results depending on your directory structure and permissions. 
- VOLUME_NAME (default volume): the name of the volume in rsync.
- OWNER_ID: the uid of the user. If not set automatically grabbed from the uid of the owner of the VOLUME_PATH.
- HOSTS_ALLOW (default 0.0.0.0/0): restrict hosts connections.
- ENABLE_RSYNCD (default true): enable/disable rsync daemon on port 873.
- ENABLE_SSH (default false): start SSH server for rsync-over-SSH.
- SSH_PASSWORD (default PASSWORD): SSH password for USERNAME.
- SSH_PASSWORD_AUTH (default true): enable SSH password authentication.
- SSH_USER_HOME (default VOLUME_PATH): home directory of the SSH user.
- SSH_DIR (default SSH_USER_HOME/.ssh): final `.ssh` directory used by sshd.
- SSH_PUBLIC_KEY: public key(s) for USERNAME, supports `\n` separated keys.
- SSH_MOUNTED_KEYS_DIR (default /home/.ssh): mounted directory containing `authorized_keys`.

### Using rsync over SSH

Enable SSH transport in your service:

    environment:
      - ENABLE_SSH=true
      - ENABLE_RSYNCD=false # optional: set true to run both
      - SSH_USER_HOME=/home/sftp # optional
      - SSH_DIR=/home/sftp/.ssh # optional
      - SSH_MOUNTED_KEYS_DIR=/home/.ssh
    ports:
      - 12222:22
    volumes:
      - ./ssh:/home/.ssh:ro

Then sync through SSH:

    rsync -av -e "ssh -p 12222" ./local-dir/ sftp@localhost:/data/

For key-based auth, provide `SSH_PUBLIC_KEY` and optionally disable password auth:

    environment:
      - ENABLE_SSH=true
      - SSH_PASSWORD_AUTH=false
      - SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...

If you want both key and password auth, keep `SSH_PASSWORD_AUTH=true` and provide either
`SSH_PUBLIC_KEY`, a mounted `SSH_MOUNTED_KEYS_DIR`, or both.

## Disclaimer

Besides the usual disclaimer in the license, we want to specifically emphasize that the authors, and any organizations the authors are associated with, can not be held responsible for data-loss caused by possible malfunctions of Docker Magic Sync.

## License

[GPLv2](http://www.fsf.org/licensing/licenses/info/GPLv2.html) or any later GPL version.
