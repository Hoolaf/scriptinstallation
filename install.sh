#!/bin/bash

# Script d'installation automatisée d'un NAS Debian
# Ce script configure un serveur NAS complet sous Debian 12
# avec SFTP, WebDAV, gestion des utilisateurs et fonctionnalités avancées

# Vérification des privilèges root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root ou avec sudo."
    exit 1
fi

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Fonction pour afficher les messages
display_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

display_error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

display_warning() {
    echo -e "${YELLOW}[ATTENTION]${NC} $1"
}

display_message "Début de l'installation du serveur NAS Debian..."

# Variables de configuration
NAS_ROOT="/srv/nas"
ADMIN_USER="nasadmin"
ADMIN_PASSWORD="NasAdmin123"  # À changer dans un environnement de production
DEFAULT_USER="LaPlateforme"  # Utilisateur existant selon l'énoncé
DEFAULT_PASSWORD="LaPlateforme13"  # Mot de passe selon l'énoncé

# 1. Mise à jour du système
display_message "Mise à jour du système..."
apt update && apt upgrade -y

# 2. Installation des dépendances
display_message "Installation des packages nécessaires..."
apt install -y openssh-server apache2 apache2-utils libapache2-mod-dav-fs \
              rsync mdadm htop nano vim curl wget \
              qemu-kvm libvirt-daemon-system virtinst libvirt-clients bridge-utils \
              fail2ban ufw

# 3. Configuration de la structure des dossiers
display_message "Configuration de la structure des dossiers..."
mkdir -p "$NAS_ROOT/Public"
mkdir -p "$NAS_ROOT/Users"

# 4. Configuration des groupes et utilisateurs
display_message "Configuration des groupes et utilisateurs..."
groupadd nasusers

# Création de l'utilisateur administrateur
useradd -m -G sudo,nasusers -s /bin/bash "$ADMIN_USER"
echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd

# Vérification de l'existence de l'utilisateur par défaut
if id "$DEFAULT_USER" &>/dev/null; then
    display_message "Utilisateur $DEFAULT_USER existe déjà, ajout au groupe nasusers..."
    usermod -aG nasusers "$DEFAULT_USER"
else
    display_message "Création de l'utilisateur $DEFAULT_USER..."
    useradd -m -G nasusers -s /bin/bash "$DEFAULT_USER"
    echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
fi

# 5. Configuration des permissions
display_message "Configuration des permissions..."
chown -R root:nasusers "$NAS_ROOT"
chmod -R 775 "$NAS_ROOT"
chmod -R 777 "$NAS_ROOT/Public"
chmod -R 770 "$NAS_ROOT/Users"

# 6. Configuration SSH (SFTP)
display_message "Configuration SSH pour SFTP..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Ajouter la configuration SFTP
cat << EOF >> /etc/ssh/sshd_config

# Configuration SFTP
Subsystem sftp internal-sftp

# Configuration pour chroot les utilisateurs dans leur répertoire home
Match Group nasusers
    ChrootDirectory $NAS_ROOT
    X11Forwarding no
    AllowTcpForwarding no
    ForceCommand internal-sftp
EOF

# Redémarrer SSH
systemctl restart ssh

# 7. Configuration WebDAV
display_message "Configuration WebDAV..."
a2enmod dav
a2enmod dav_fs
a2enmod auth_digest
a2enmod ssl

# Créer la configuration WebDAV
cat << EOF > /etc/apache2/sites-available/webdav.conf
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html
    
    Alias /webdav $NAS_ROOT
    
    <Directory $NAS_ROOT>
        Options Indexes FollowSymLinks
        DAV On
        AuthType Digest
        AuthName "WebDAV Server"
        AuthUserFile /etc/apache2/webdav.passwd
        Require valid-user
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

# Activer le site WebDAV
a2ensite webdav

# Créer le fichier d'authentification WebDAV
htdigest -c /etc/apache2/webdav.passwd "WebDAV Server" "$ADMIN_USER" << EOF
$ADMIN_PASSWORD
$ADMIN_PASSWORD
EOF

htdigest /etc/apache2/webdav.passwd "WebDAV Server" "$DEFAULT_USER" << EOF
$DEFAULT_PASSWORD
$DEFAULT_PASSWORD
EOF

# Redémarrer Apache
systemctl restart apache2

# 8. Configuration du pare-feu
display_message "Configuration du pare-feu..."
ufw allow OpenSSH
ufw allow 'Apache Full'
ufw --force enable

# 9. Création du script de gestion des utilisateurs
display_message "Création du script de gestion des utilisateurs..."
cat << 'EOF' > /usr/local/bin/nas_user_manager.sh
#!/bin/bash

# Script de gestion des utilisateurs pour le NAS Debian
# Usage: nas_user_manager.sh [add|remove|list|mod_perms] [username] [permissions]

# Vérifier si l'utilisateur est root
if [ "$(id -u)" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root ou avec sudo."
    exit 1
fi

ACTION=$1
USERNAME=$2
PERMISSIONS=$3
NAS_ROOT="/srv/nas"

case "$ACTION" in
    add)
        if [ -z "$USERNAME" ]; then
            echo "Erreur: Nom d'utilisateur requis."
            echo "Usage: nas_user_manager.sh add username"
            exit 1
        fi
        
        # Vérifier si l'utilisateur existe déjà
        if id "$USERNAME" &>/dev/null; then
            echo "L'utilisateur $USERNAME existe déjà."
            # Ajouter au groupe nasusers s'il n'y est pas déjà
            if ! groups "$USERNAME" | grep -q nasusers; then
                usermod -aG nasusers "$USERNAME"
                echo "Utilisateur $USERNAME ajouté au groupe nasusers."
            else
                echo "L'utilisateur $USERNAME est déjà dans le groupe nasusers."
            fi
        else
            # Créer l'utilisateur
            useradd -m -G nasusers -s /bin/bash "$USERNAME"
            
            # Définir le mot de passe
            echo "Définir le mot de passe pour $USERNAME:"
            passwd "$USERNAME"
            
            echo "Utilisateur $USERNAME créé avec succès."
        fi
        
        # Créer le dossier utilisateur dans le NAS s'il n'existe pas
        if [ ! -d "$NAS_ROOT/Users/$USERNAME" ]; then
            mkdir -p "$NAS_ROOT/Users/$USERNAME"
            chown "$USERNAME:nasusers" "$NAS_ROOT/Users/$USERNAME"
            chmod 700 "$NAS_ROOT/Users/$USERNAME"
            echo "Dossier utilisateur créé: $NAS_ROOT/Users/$USERNAME"
        fi
        
        # Ajouter l'utilisateur à WebDAV s'il n'existe pas
        if ! grep -q "$USERNAME:" /etc/apache2/webdav.passwd; then
            echo "Ajout de $USERNAME à WebDAV:"
            htdigest /etc/apache2/webdav.passwd "WebDAV Server" "$USERNAME"
        fi
        
        echo "Configuration complète pour l'utilisateur $USERNAME."
        ;;
        
    remove)
        if [ -z "$USERNAME" ]; then
            echo "Erreur: Nom d'utilisateur requis."
            echo "Usage: nas_user_manager.sh remove username"
            exit 1
        fi
        
        # Vérifier si l'utilisateur existe
        if ! id "$USERNAME" &>/dev/null; then
            echo "L'utilisateur $USERNAME n'existe pas."
            exit 1
        fi
        
        # Supprimer l'utilisateur
        userdel -r "$USERNAME"
        
        # Sauvegarder les données de l'utilisateur
        if [ -d "$NAS_ROOT/Users/$USERNAME" ]; then
            mv "$NAS_ROOT/Users/$USERNAME" "$NAS_ROOT/Users/$USERNAME.bak_$(date +%Y%m%d)"
            echo "Données de l'utilisateur sauvegardées dans $NAS_ROOT/Users/$USERNAME.bak_$(date +%Y%m%d)"
        fi
        
        # Supprimer l'utilisateur de WebDAV (n'est pas supporté directement, nous devons recréer le fichier)
        if [ -f "/etc/apache2/webdav.passwd" ]; then
            grep -v "$USERNAME:" /etc/apache2/webdav.passwd > /tmp/webdav.passwd.tmp
            mv /tmp/webdav.passwd.tmp /etc/apache2/webdav.passwd
            echo "Utilisateur supprimé de WebDAV."
        fi
        
        echo "Utilisateur $USERNAME supprimé avec succès."
        ;;
        
    list)
        echo "Liste des utilisateurs du NAS:"
        echo "------------------------------"
        echo "Membres du groupe nasusers:"
        getent group nasusers | cut -d: -f4 | tr ',' '\n' | sort
        echo "------------------------------"
        echo "Dossiers utilisateurs existants:"
        ls -la "$NAS_ROOT/Users/" | grep "^d" | awk '{print $9}' | grep -v "^\." | sort
        echo "------------------------------"
        echo "Utilisateurs WebDAV:"
        if [ -f "/etc/apache2/webdav.passwd" ]; then
            cut -d: -f1 /etc/apache2/webdav.passwd | sort | uniq
        else
            echo "Fichier WebDAV non trouvé."
        fi
        ;;
        
    mod_perms)
        if [ -z "$USERNAME" ] || [ -z "$PERMISSIONS" ]; then
            echo "Erreur: Nom d'utilisateur et permissions requis."
            echo "Usage: nas_user_manager.sh mod_perms username permissions"
            echo "Exemple: nas_user_manager.sh mod_perms john 750"
            exit 1
        fi
        
        if [ ! -d "$NAS_ROOT/Users/$USERNAME" ]; then
            echo "Erreur: Le dossier utilisateur $NAS_ROOT/Users/$USERNAME n'existe pas."
            exit 1
        fi
        
        chmod "$PERMISSIONS" "$NAS_ROOT/Users/$USERNAME"
        echo "Permissions du dossier $NAS_ROOT/Users/$USERNAME modifiées à $PERMISSIONS."
        ;;
        
    *)
        echo "Usage: nas_user_manager.sh [add|remove|list|mod_perms] [username] [permissions]"
        echo "  add username        - Ajouter/activer un utilisateur"
        echo "  remove username     - Supprimer un utilisateur (sauvegarde ses données)"
        echo "  list                - Lister tous les utilisateurs"
        echo "  mod_perms username perm - Modifier les permissions du dossier utilisateur"
        exit 1
        ;;
esac

exit 0
EOF

chmod +x /usr/local/bin/nas_user_manager.sh

# 10. Création du script de sauvegarde
display_message "Création du script de sauvegarde..."
cat << 'EOF' > /usr/local/bin/nas_backup.sh
#!/bin/bash

# Script de sauvegarde du NAS
# Usage: nas_backup.sh [destination_server] [destination_path]

DEST_SERVER=$1
DEST_PATH=${2:-"/backup/nas"}
SRC_PATH="/srv/nas"
BACKUP_LOG="/var/log/nas_backup.log"

# Fonction de journalisation
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$BACKUP_LOG"
}

# Vérifier si les arguments nécessaires sont fournis
if [ -z "$DEST_SERVER" ]; then
    log_message "Erreur: Serveur de destination requis."
    echo "Usage: nas_backup.sh user@destination_server [destination_path]"
    exit 1
fi

log_message "Début de la sauvegarde vers $DEST_SERVER:$DEST_PATH"

# Vérifier la connexion SSH au serveur de destination
ssh -o BatchMode=yes -o ConnectTimeout=5 "$DEST_SERVER" echo "Test de connexion" &> /dev/null
if [ $? -ne 0 ]; then
    log_message "Erreur: Impossible de se connecter au serveur $DEST_SERVER"
    exit 1
fi

# Créer le dossier de sauvegarde s'il n'existe pas
log_message "Création du dossier de destination s'il n'existe pas"
ssh "$DEST_SERVER" "mkdir -p $DEST_PATH"

# Effectuer la sauvegarde avec rsync
log_message "Démarrage de la sauvegarde avec rsync"
rsync -avz --delete --stats "$SRC_PATH/" "$DEST_SERVER:$DEST_PATH/" 2>&1 | tee -a "$BACKUP_LOG"

# Vérifier le résultat
if [ ${PIPESTATUS[0]} -eq 0 ]; then
    log_message "Sauvegarde terminée avec succès"
else
    log_message "Erreur lors de la sauvegarde"
fi

exit ${PIPESTATUS[0]}
EOF

chmod +x /usr/local/bin/nas_backup.sh

# 11. Création de l'interface d'administration
display_message "Création de l'interface d'administration..."
cat << 'EOF' > /usr/local/bin/nas_admin.sh
#!/bin/bash

# Interface d'administration du NAS Debian
# Usage: nas_admin.sh

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Vérifier si l'utilisateur est root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ce script doit être exécuté en tant que root ou avec sudo.${NC}"
    exit 1
fi

NAS_ROOT="/srv/nas"

# Fonction pour le menu principal
show_main_menu() {
    clear
    echo -e "${BLUE}========================================================${NC}"
    echo -e "${GREEN}      NAS DEBIAN - INTERFACE D'ADMINISTRATION${NC}"
    echo -
