#!/bin/bash

# Script d'installation automatisée d'un NAS Debian
# Ce script configure un serveur NAS complet sous Debian 12
# avec RAID 5, SFTP, WebDAV, Cockpit, et gestion des utilisateurs

#Privileges Checking
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root ou avec sudo."
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Fonction Affichage de messages
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

# Variable de configuration
NAS_ROOT="/srv/nas"
ADMIN_USER="nasadmin"
DEFAULT_USER="LaPlateforme"
DEFAULT_PASSWORD="LaPlateforme13"
RAID_LEVEL=5
RAID_DEVICES=""

read -sp "Entrez le mot de passe pour l'utilisateur $ADMIN_USER : " ADMIN_PASSWORD
echo
read -sp "Confirmez le mot de passe : " ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    display_error "Les mots de passe ne correspondent pas."
    exit 1
fi

display_message "Mise à jour du système..."
apt update && apt upgrade -y
check_error "Échec de la mise à jour du système."

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

    # Installation de mdadm
    apt install -y mdadm
    check_error "Échec de l'installation de mdadm."

    for disk in $RAID_DEVICES; do
        display_message "Partitionnement de $disk..."
        parted -s $disk mklabel gpt
        parted -s $disk mkpart primary 0% 100%
        parted -s $disk set 1 raid on
    done

    display_message "Création du tableau RAID ${RAID_LEVEL}..."
    mdadm --create --verbose /dev/md0 --level=$RAID_LEVEL --raid-devices=$count $RAID_DEVICES
    check_error "Échec de la création du RAID"

    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u

    display_message "Formatage du RAID en ext4..."
    mkfs.ext4 /dev/md0
    mkdir -p "$NAS_ROOT"
    mount /dev/md0 "$NAS_ROOT"
    echo "/dev/md0 $NAS_ROOT ext4 defaults 0 0" >> /etc/fstab

    display_message "Vérification du statut RAID..."
    mdadm --detail /dev/md0
    cat /proc/mdstat
}

configure_raid

# 3. Installatio des dépendances
#!/bin/bash

display_message "Installation des packages nécessaires et Webmin..."
apt install -y openssh-server apache2 apache2-utils \
              rsync mdadm htop nano vim curl wget \
              samba samba-common-bin \
              fail2ban ufw
check_error "Échec de l'installation des paquets."

# Ajout du dépôt Webmin
echo "deb https://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list
wget -qO- https://download.webmin.com/jcameron-key.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/webmin.gpg
apt update
apt install -y webmin
check_error "Échec de l'installation de Webmin."

systemctl enable --now webmin
check_error "Échec de l'activation de Webmin."


display_message "Configuration WebDAV..."
a2enmod dav dav_fs auth_digest
check_error "Échec de l'activation des modules Apache."

a2dissite 000-default.conf

cat > /etc/apache2/sites-available/webdav.conf << EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /srv/nas

    <Directory /srv/nas>
        DAV On
        AuthType Digest
        AuthName "WebDAV_Area"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user
        
        
        # Autorisations
        <LimitExcept GET HEAD OPTIONS>
            Require valid-user
        </LimitExcept>
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/webdav-error.log
    CustomLog \${APACHE_LOG_DIR}/webdav-access.log combined
</VirtualHost>
EOF

# Créer le fichier de mot de passe si inexistant
[ ! -f /etc/apache2/webdav.passwd ] && touch /etc/apache2/webdav.passwd
chown www-data:www-data /etc/apache2/webdav.passwd
chmod 640 /etc/apache2/webdav.passwd

# Ajouter les utilisateurs
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

# Création du fichier de mots de passe s'il n'existe pas
if [ ! -f /etc/apache2/webdav.passwd ]; then
    touch /etc/apache2/webdav.passwd
    chown www-data:www-data /etc/apache2/webdav.passwd
    chmod 640 /etc/apache2/webdav.passwd
fi

# Ajout des utilisateurs
htdigest -c /etc/apache2/webdav.passwd "WebDAV_Server" "$ADMIN_USER" << EOF
$ADMIN_PASSWORD
$ADMIN_PASSWORD
EOF

htdigest /etc/apache2/webdav.passwd "WebDAV_Server" "$DEFAULT_USER" << EOF
$DEFAULT_PASSWORD
$DEFAULT_PASSWORD
EOF

a2ensite webdav
systemctl restart apache2
check_error "Échec de la configuration WebDAV."

# 9. Configuration Samba
display_message "Configuration de Samba..."
cat > /etc/samba/smb.conf << EOF
[global]
   workgroup = WORKGROUP
   server string = NAS Server
   security = user
   map to guest = bad user
   dns proxy = no

[Public]
   path = /srv/nas/Public
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0775
   directory mask = 0775

[Users]
   path = /srv/nas/Users
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

systemctl restart smbd
check_error "Échec de la configuration Samba."

# 10. Modification du pare-feu
display_message "Configuration du pare-feu..."
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 139/tcp  # Samba
ufw allow 445/tcp  # Samba
ufw allow 10000/tcp  # Webmin
ufw --force enable
check_error "Échec de la configuration du pare-feu."

# ... [Les sections de gestion des utilisateurs et sauvegarde restent inchangées] ...

# 12. Finalisation
display_message "Installation terminée avec succès !"
display_message "Accédez à l'interface Webmin : https://$(hostname):10000"
display_message "Accédez à WebDAV : http://$(hostname)/webdav"
display_message "Accédez aux partages Samba : \\\\$(hostname)"
display_message "Statut du RAID :"
mdadm --detail /dev/md0 | grep -E 'State|Active|Working|Failed'
