#!/bin/bash

# Script d'installation automatisée d'un NAS Debian
# Ce script configure un serveur NAS complet sous Debian 12
# avec RAID 5, SFTP, WebDAV, Samba, Webmin et gestion des utilisateurs

# Vérification des privilèges
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root ou avec sudo."
    exit 1
fi

# Définition des couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Fonctions d'affichage
display_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

display_error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

display_warning() {
    echo -e "${YELLOW}[ATTENTION]${NC} $1"
}

check_error() {
    if [ $? -ne 0 ]; then
        display_error "$1"
        exit 1
    fi
}

display_message "Début de l'installation du serveur NAS Debian..."

# Configuration des variables
NAS_ROOT="/srv/nas"
ADMIN_USER="nasadmin"
DEFAULT_USER="LaPlateforme"
DEFAULT_PASSWORD="LaPlateforme13"
RAID_LEVEL=5
RAID_DEVICES=""

# Saisie du mot de passe admin
read -sp "Entrez le mot de passe pour l'utilisateur $ADMIN_USER : " ADMIN_PASSWORD
echo
read -sp "Confirmez le mot de passe : " ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    display_error "Les mots de passe ne correspondent pas."
    exit 1
fi

# 1. Mise à jour du système
display_message "Mise à jour du système..."
apt update && apt upgrade -y
check_error "Échec de la mise à jour du système."

# 2. Configuration du RAID
configure_raid() {
    display_message "Configuration du RAID ${RAID_LEVEL}..."
    
    lsblk
    read -p "Listez les disques à utiliser pour le RAID (ex: /dev/sdb /dev/sdc) : " RAID_DEVICES
    display_warning "ATTENTION: Toutes les données sur ces disques seront effacées!"

    local count=$(echo $RAID_DEVICES | wc -w)
    if [ $count -lt 3 ]; then
        display_error "RAID 5 nécessite au moins 3 disques"
        exit 1
    fi

    apt install -y mdadm
    check_error "Échec de l'installation de mdadm."

    for disk in $RAID_DEVICES; do
        display_message "Partitionnement de $disk..."
        parted -s $disk mklabel gpt
        parted -s $disk mkpart primary 0% 100%
        parted -s $disk set 1 raid on
    done

    mdadm --create --verbose /dev/md0 --level=$RAID_LEVEL --raid-devices=$count $RAID_DEVICES
    check_error "Échec de la création du RAID"

    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u

    mkfs.ext4 /dev/md0
    mkdir -p "$NAS_ROOT"
    mount /dev/md0 "$NAS_ROOT"
    echo "/dev/md0 $NAS_ROOT ext4 defaults 0 0" >> /etc/fstab

    mdadm --detail /dev/md0
    cat /proc/mdstat
}

configure_raid

# 3. Création de la structure de dossiers
display_message "Création de la structure de dossiers..."
mkdir -p "$NAS_ROOT/Public" "$NAS_ROOT/Users"
chmod -R 2775 "$NAS_ROOT/Public"
find "$NAS_ROOT/Public" -type d -exec chmod g+s {} \;
check_error "Échec de la création des dossiers."

# 4. Configuration des groupes et utilisateurs
display_message "Configuration des groupes et utilisateurs..."
groupadd -f nasusers

# Création de l'administrateur
if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -G sudo,nasusers -s /bin/bash "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
    check_error "Échec de la création de $ADMIN_USER"
else
    usermod -aG sudo,nasusers "$ADMIN_USER"
    display_warning "L'utilisateur $ADMIN_USER existe déjà, mise à jour des groupes."
fi

# Création de l'utilisateur par défaut
if ! id "$DEFAULT_USER" &>/dev/null; then
    useradd -m -G nasusers -s /bin/bash "$DEFAULT_USER"
    echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
    check_error "Échec de la création de $DEFAULT_USER"
else
    usermod -aG nasusers "$DEFAULT_USER"
    display_warning "L'utilisateur $DEFAULT_USER existe déjà, mise à jour des groupes."
fi

# 5. Configuration des permissions
display_message "Configuration des permissions..."
chown -R root:nasusers "$NAS_ROOT"
chmod -R 775 "$NAS_ROOT"
find "$NAS_ROOT/Users" -mindepth 1 -maxdepth 1 -type d -exec chmod 700 {} \;
check_error "Échec de la configuration des permissions."

# 6. Installation des dépendances
display_message "Installation des paquets nécessaires..."
apt install -y openssh-server apache2 apache2-utils \
              rsync htop nano vim curl wget \
              samba samba-common-bin \
              fail2ban ufw
check_error "Échec de l'installation des paquets."

# 7. Configuration de Webmin
display_message "Installation de Webmin..."
echo "deb https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list
wget -qO- https://download.webmin.com/jcameron-key.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/webmin.gpg
apt update && apt install -y webmin
check_error "Échec de l'installation de Webmin."
systemctl enable --now webmin

# 8. Configuration WebDAV
display_message "Configuration WebDAV..."
a2enmod dav dav_fs auth_digest
a2dissite 000-default.conf

cat > /etc/apache2/sites-available/webdav.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot $NAS_ROOT

    <Directory $NAS_ROOT>
        DAV On
        Options Indexes FollowSymLinks
        AuthType Digest
        AuthName "WebDAV_Area"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user
        
        <LimitExcept GET HEAD OPTIONS>
            Require valid-user
        </LimitExcept>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/webdav-error.log
    CustomLog \${APACHE_LOG_DIR}/webdav-access.log combined
</VirtualHost>
EOF

# Création du fichier d'authentification
[ ! -f /etc/apache2/webdav.passwd ] && touch /etc/apache2/webdav.passwd
chown www-data:www-data /etc/apache2/webdav.passwd
chmod 640 /etc/apache2/webdav.passwd

htdigest -c /etc/apache2/webdav.passwd "WebDAV_Area" "$ADMIN_USER" << EOF
$ADMIN_PASSWORD
$ADMIN_PASSWORD
EOF

htdigest /etc/apache2/webdav.passwd "WebDAV_Area" "$DEFAULT_USER" << EOF
$DEFAULT_PASSWORD
$DEFAULT_PASSWORD
EOF

a2ensite webdav.conf
systemctl restart apache2
check_error "Échec de la configuration WebDAV."

# 9. Configuration Samba
display_message "Configuration Samba..."
cat > /etc/samba/smb.conf << EOF
[global]
    workgroup = WORKGROUP
    server string = NAS Server
    security = user
    map to guest = bad user
    dns proxy = no

[Public]
    path = $NAS_ROOT/Public
    browseable = yes
    read only = no
    guest ok = yes
    create mask = 0775
    directory mask = 0775

[Users]
    path = $NAS_ROOT/Users
    browseable = no
    read only = no
    valid users = @nasusers
    force group = nasusers
    create mask = 0770
    directory mask = 0770
EOF

# Ajout des utilisateurs à Samba
(echo "$DEFAULT_PASSWORD"; echo "$DEFAULT_PASSWORD") | smbpasswd -a -s "$DEFAULT_USER"
(echo "$ADMIN_PASSWORD"; echo "$ADMIN_PASSWORD") | smbpasswd -a -s "$ADMIN_USER"

systemctl restart smbd nmbd
check_error "Échec de la configuration Samba."

# 10. Configuration du pare-feu
display_message "Configuration du pare-feu..."
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 139/tcp
ufw allow 445/tcp
ufw allow 10000/tcp
ufw --force enable
check_error "Échec de la configuration du pare-feu."

# 11. Création des dossiers utilisateurs
display_message "Création des espaces utilisateurs..."
for USER in "$ADMIN_USER" "$DEFAULT_USER"; do
    USER_DIR="$NAS_ROOT/Users/$USER"
    mkdir -p "$USER_DIR"
    chown "$USER:nasusers" "$USER_DIR"
    chmod 700 "$USER_DIR"
    display_message "Espace créé pour $USER : $USER_DIR"
done

# 12. Finalisation
display_message "Installation terminée avec succès !"
display_message "Accès Webmin : https://$(hostname -I | awk '{print $1}'):10000"
display_message "Accès WebDAV : http://$(hostname -I | awk '{print $1}')/webdav"
display_message "Partages Samba : \\\\$(hostname -I | awk '{print $1}')"
display_message "Statut RAID :"
mdadm --detail /dev/md0 | grep -E 'State|Active|Working|Failed'
