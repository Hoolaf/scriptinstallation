#!/bin/bash

# Script d'installation automatisée d'un NAS Debian
# Ce script configure un serveur NAS complet sous Debian 12
# avec SFTP, WebDAV, Cockpit, et gestion des utilisateurs

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

# Fonctions pour afficher les messages
display_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

display_error() {
    echo -e "${RED}[ERREUR]${NC} $1"
}

display_warning() {
    echo -e "${YELLOW}[ATTENTION]${NC} $1"
}

# Fonction pour vérifier les erreurs
check_error() {
    if [ $? -ne 0 ]; then
        display_error "$1"
        exit 1
    fi
}

display_message "Début de l'installation du serveur NAS Debian..."

# Variables de configuration
NAS_ROOT="/srv/nas"
ADMIN_USER="nasadmin"
DEFAULT_USER="LaPlateforme"
DEFAULT_PASSWORD="LaPlateforme13"

# Demander le mot de passe admin (éviter les mots de passe en dur)
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

# 2. Installation des dépendances et Cockpit
display_message "Installation des packages nécessaires et Cockpit..."
apt install -y openssh-server apache2 apache2-utils \
              rsync mdadm htop nano vim curl wget \
              cockpit cockpit-packagekit cockpit-storaged \
              fail2ban ufw certbot python3-certbot-apache
check_error "Échec de l'installation des paquets."

# Activer et démarrer Cockpit
systemctl enable --now cockpit.socket
check_error "Échec de l'activation de Cockpit."

# 3. Configuration de la structure des dossiers
display_message "Configuration de la structure des dossiers..."
mkdir -p "$NAS_ROOT/Public"
mkdir -p "$NAS_ROOT/Users"
check_error "Échec de la création des dossiers."

# 4. Configuration des groupes et utilisateurs
display_message "Configuration des groupes et utilisateurs..."
groupadd nasusers 2>/dev/null || true

# Création de l'utilisateur administrateur
if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -G sudo,nasusers -s /bin/bash "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
    check_error "Échec de la création de l'utilisateur $ADMIN_USER."
else
    display_warning "L'utilisateur $ADMIN_USER existe déjà."
fi

# Vérification de l'existence de l'utilisateur par défaut
if id "$DEFAULT_USER" &>/dev/null; then
    display_message "Utilisateur $DEFAULT_USER existe déjà, ajout au groupe nasusers..."
    usermod -aG nasusers "$DEFAULT_USER"
else
    display_message "Création de l'utilisateur $DEFAULT_USER..."
    useradd -m -G nasusers -s /bin/bash "$DEFAULT_USER"
    echo "$DEFAULT_USER:$DEFAULT_PASSWORD" | chpasswd
    check_error "Échec de la création de l'utilisateur $DEFAULT_USER."
fi

# 5. Configuration des permissions
display_message "Configuration des permissions..."
chown -R root:nasusers "$NAS_ROOT"
chmod -R 775 "$NAS_ROOT"
chmod 2775 "$NAS_ROOT/Public"  # setgid pour conserver les droits de groupe
chmod -R 770 "$NAS_ROOT/Users"
check_error "Échec de la configuration des permissions."

# 6. Configuration SSH (SFTP)
# 6. Configuration SSH (SFTP)
display_message "Configuration SSH pour SFTP..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

# Créer les dossiers utilisateurs pour SFTP (avec la bonne casse)
mkdir -p "/srv/nas/Users"
chown root:root "/srv/nas/Users"
chmod 755 "/srv/nas/Users"

for USER in "$ADMIN_USER" "$DEFAULT_USER"; do
    mkdir -p "/srv/nas/Users/$USER"
    chown root:root "/srv/nas/Users/$USER"
    chmod 755 "/srv/nas/Users/$USER"
    mkdir -p "/srv/nas/Users/$USER/files"
    chown "$USER:nasusers" "/srv/nas/Users/$USER/files"
    chmod 750 "/srv/nas/Users/$USER/files"
done

# Configuration SFTP avec chroot (noter la majuscule dans le chemin)
cat > /etc/ssh/sshd_config.d/sftp.conf << EOF

Match Group nasusers
    ChrootDirectory /srv/nas/Users/%u
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
EOF

systemctl restart ssh
check_error "Échec de la configuration SSH."

# 7. Configuration WebDAV avec HTTPS
display_message "Configuration WebDAV avec HTTPS..."
a2enmod dav dav_fs auth_digest ssl
check_error "Échec de l'activation des modules Apache."

# Créer la configuration WebDAV
cat > /etc/apache2/sites-available/webdav.conf << EOF
<VirtualHost *:443>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$(hostname)/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$(hostname)/privkey.pem

    Alias /webdav /srv/nas

    <Directory /srv/nas>
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

# Obtenir un certificat Let's Encrypt
# Demander une adresse email valide pour le certificat
read -p "Entrez une adresse email valide pour le certificat SSL : " SSL_EMAIL

# Obtenir un certificat Let's Encrypt
certbot --apache -d $(hostname) --non-interactive --agree-tos -m "$SSL_EMAIL"

# Créer le fichier d'authentification WebDAV
htdigest -c /etc/apache2/webdav.passwd "WebDAV Server" "$ADMIN_USER" << EOF
$ADMIN_PASSWORD
$ADMIN_PASSWORD
EOF

htdigest /etc/apache2/webdav.passwd "WebDAV Server" "$DEFAULT_USER" << EOF
$DEFAULT_PASSWORD
$DEFAULT_PASSWORD
EOF

a2ensite webdav
systemctl restart apache2
check_error "Échec de la configuration WebDAV."

# 8. Configuration du pare-feu
display_message "Configuration du pare-feu..."
ufw allow OpenSSH
ufw allow 443/tcp
ufw allow 9090/tcp  # Port pour Cockpit
ufw --force enable
check_error "Échec de la configuration du pare-feu."

# 9. Création du script de gestion des utilisateurs
display_message "Création du script de gestion des utilisateurs..."
cat > /usr/local/bin/nas_user_manager.sh << 'EOF'
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
        
        # Ajouter l'utilisateur à WebDAV
        if [ -f "/etc/apache2/webdav.passwd" ]; then
            read -s -p "Entrez le mot de passe WebDAV pour $USERNAME: " WEBDAV_PASSWORD
            echo

            echo -n "$USERNAME:WebDAV Server:" >> /etc/apache2/webdav.passwd
            echo -n "$USERNAME:WebDAV Server:$WEBDAV_PASSWORD" | md5sum | cut -d' ' -f1 >> /etc/apache2/webdav.passwd
            echo "Utilisateur $USERNAME ajouté à WebDAV."
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
        
        # Supprimer l'utilisateur de WebDAV
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
cat > /usr/local/bin/nas_backup.sh << 'EOF'
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

# 11. Finalisation
display_message "Installation terminée avec succès !"
display_message "Accédez à l'interface Cockpit : https://$(hostname):9090"
display_message "Accédez à WebDAV : https://$(hostname)/webdav"
