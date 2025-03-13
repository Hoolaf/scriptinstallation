#!/bin/bash
set -e  # Arrête le script en cas d'erreur

# ---------------------------
# Variables personnalisables
# ---------------------------
ADMIN_USER="LaPlateforme"
ADMIN_PASS="LaPlateforme13"
SFTP_GROUP="sftpusers"
WEBDAV_DIR="/var/www/webdav"
PUBLIC_DIR="/srv/nas/public"
USERS_LIST=("user1" "user2")  # Liste des utilisateurs à créer

# ---------------------------
# 1. Mise à jour du système
# ---------------------------
apt update && apt upgrade -y
apt install -y openssh-server apache2 sudo ufw curl wget samba cadaver

# ---------------------------
# 2. Création utilisateur Admin
# ---------------------------
if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    usermod -aG sudo "$ADMIN_USER"
fi

# ---------------------------
# 3. Configuration SFTP/SSH
# ---------------------------
groupadd -f "$SFTP_GROUP"
sed -i '/Match Group '"$SFTP_GROUP"'/d' /etc/ssh/sshd_config
cat <<EOF >> /etc/ssh/sshd_config
Match Group $SFTP_GROUP
    ChrootDirectory %h
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
EOF
systemctl restart ssh

# ---------------------------
# 4. Configuration WebDAV
# ---------------------------
a2enmod dav dav_fs auth_digest
mkdir -p "$WEBDAV_DIR"
chown -R www-data:www-data "$WEBDAV_DIR"

# Création fichier de configuration Apache
cat <<EOF > /etc/apache2/sites-available/webdav.conf
<VirtualHost *:80>
    ServerAdmin admin@nas.local
    DocumentRoot $WEBDAV_DIR

    <Directory $WEBDAV_DIR>
        DAV On
        AuthType Digest
        AuthName "webdav"
        AuthUserFile /etc/apache2/webdav-passwords
        Require valid-user
    </Directory>
</VirtualHost>
EOF

# Création utilisateur WebDAV (même que l'admin)
htdigest -c /etc/apache2/webdav-passwords "webdav" "$ADMIN_USER" <<EOF
$ADMIN_PASS
$ADMIN_PASS
EOF

a2ensite webdav.conf
systemctl restart apache2

# ---------------------------
# 5. Dossier Public (Samba)
# ---------------------------
mkdir -p "$PUBLIC_DIR"
chmod 777 "$PUBLIC_DIR"

cat <<EOF >> /etc/samba/smb.conf
[Public]
    path = $PUBLIC_DIR
    browseable = yes
    read only = no
    guest ok = yes
EOF
systemctl restart smbd

# ---------------------------
# 6. Création des utilisateurs
# ---------------------------
for USER in "${USERS_LIST[@]}"; do
    if ! id "$USER" &>/dev/null; then
        useradd -m -s /bin/bash "$USER"
        echo "$USER:$ADMIN_PASS" | chpasswd  # Mot de passe identique pour tous (à modifier)
        usermod -aG "$SFTP_GROUP" "$USER"
    fi
done

# ---------------------------
# 7. Configuration du pare-feu
# ---------------------------
ufw allow ssh
ufw allow 80
ufw allow 139/tcp  # Samba
ufw enable

# ---------------------------
# 8. Tests automatiques
# ---------------------------
echo "✅ Installation terminée ! Tests :"
ss -tulpn | grep -E '22|80|139'
curl -I http://localhost/webdav

# ---------------------------
# 9. Documentation générée
# ---------------------------
cat <<EOF > /root/NAS_DOCUMENTATION.md
# Documentation NAS
- Admin : $ADMIN_USER / $ADMIN_PASS
- SFTP : sftp://$ADMIN_USER@$(hostname -I | awk '{print $1}')
- WebDAV : http://$(hostname -I | awk '{print $1}')/webdav
- Dossier Public : smb://$(hostname -I | awk '{print $1}')/Public
EOF

echo "📄 Documentation générée : /root/NAS_DOCUMENTATION.md"
