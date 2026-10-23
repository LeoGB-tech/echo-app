# Écho — l'app

Ce dépôt fabrique **tout seul**, à chaque envoi :
- l'app **iPhone** (`Echo.ipa`) ;
- l'app **Android** (`Echo.apk`) ;
- ton **store perso** : https://leogb-tech.github.io/echo-app/ (page d'installation + source SideStore/AltStore + version web d'Écho dans `/app/`).

## Mise en route (une seule fois)
1. Sur GitHub : **New repository** → nom `echo-app` → **Public** (les Mac de GitHub sont gratuits pour les dépôts publics).
2. **Add file → Upload files** → glisse **tout le contenu** de ce dossier (y compris le dossier `.github`) → **Commit changes**.
3. **Settings → Pages → Source : GitHub Actions**.
4. Onglet **Actions** : la fabrication démarre (environ 10 min). Quand tout est vert, ton store est en ligne.

## Mettre à jour Écho
Remplace les fichiers du dossier `web/` par la nouvelle version, puis envoie-les. Une nouvelle version de l'app et du store se fabrique toute seule.
SideStore / AltStore proposent la mise à jour automatiquement.

## Installer sur iPhone
Les étapes sont sur la page du store (Sideloadly depuis le PC, ou SideStore pour les mises à jour automatiques).
