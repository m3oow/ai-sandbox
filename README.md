# ai-sandbox

Clic droit sur un dossier → **Lancer IA sandboxée** → Claude ou Gemini.
Le client IA tourne dans un conteneur Podman qui ne voit **que ce dossier et ses sous-dossiers**.

```
Explorateur ─► Windows Terminal ─► ai-sandbox.ps1 ─► podman.exe ─► podman machine (WSL)
                                                                     └─ conteneur
                                                                        /workspace = votre dossier
                                                                        settings.json recopié à chaque lancement
```

## Prérequis

- Windows 10/11, Podman Desktop avec une machine Podman démarrée (rootless recommandé)
- Windows Terminal (facultatif, sinon console PowerShell classique)

## Installation

Dans le dossier décompressé :

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Le script copie les fichiers dans `%LOCALAPPDATA%\ai-sandbox`, construit les images depuis UBI 10
(`ai-sandbox-base`, `ai-sandbox-claude`, `ai-sandbox-gemini`) et ajoute le menu contextuel.
Aucun droit administrateur n'est nécessaire.

Sous Windows 11, le menu est dans **Afficher plus d'options** (ou Maj + clic droit).

## Utilisation

| Entrée du menu | Effet |
|---|---|
| Claude / Gemini | Session normale : le client demande avant d'agir |
| Claude (autonome) / Gemini (autonome) | `--dangerously-skip-permissions` / `--yolo` : l'IA agit sans demander, dans la limite du dossier monté |

**Authentification** : le plus simple est un `settings.json` contenant votre clé ou votre
gateway (voir « Réglages du client IA »). Vous pouvez aussi définir `ANTHROPIC_API_KEY` ou
`GEMINI_API_KEY` dans vos variables d'environnement Windows : elles sont transmises à chaque
session sans être stockées dans le conteneur. Une connexion par compte (URL + code à coller)
reste possible, mais elle est propre à chaque sandbox : à refaire pour chaque projet.

### En ligne de commande

```powershell
$s = "$env:LOCALAPPDATA\ai-sandbox\ai-sandbox.ps1"

& $s -Client claude -Path C:\Projets\demo   # session Claude
& $s -Client gemini -Yolo                   # Gemini autonome, dossier courant
& $s -Shell                                 # bash dans la sandbox du dossier courant
& $s -List                                  # toutes les sandboxes et leur dossier
& $s -Reset -Path C:\Projets\demo           # recrée la sandbox à neuf (fichiers intacts)
& $s -Rebuild                               # met à jour les images et les clients IA
& $s -StopAll                               # arrête toutes les sandboxes
```

## Comment ça marche

- **Un conteneur par couple (client, dossier)**, nommé `ai-<client>-<hash du chemin>`.
  Il reste en place entre les sessions : les outils installés par l'IA
  (`sudo apt install …`, `pip install --user …`, `npm i -g …`) restent disponibles pour ce projet.
- **Configuration du client propre à chaque conteneur** (historique, sessions, état) : rien
  n'est partagé entre projets, l'IA d'un projet ne peut pas lire les conversations d'un autre.
  `-Reset` efface aussi cet historique.
- **Utilisateur `dev` (UID 1000)** avec sudo sans mot de passe, mappé sur votre utilisateur
  de la machine Podman (`--userns=keep-id`) : les fichiers créés vous appartiennent.
- **Image de base** : Red Hat UBI 10 (`registry.access.redhat.com/ubi10/ubi:latest` par défaut)
  avec Node.js, Python 3, git, gcc/make, sudo. jq, ripgrep, tree, unzip, etc. sont ajoutés
  s'ils existent dans les dépôts dnf de l'image, ignorés sinon.

## Réglages du client IA (gateway, clé d'API, modèles)

À chaque lancement, le `settings.json` Windows défini dans `config.psd1` est copié dans
la sandbox, ce qui rend Claude immédiatement utilisable avec votre gateway :

```powershell
Settings = @{
    claude = '%USERPROFILE%\.claude\settings.json'
}
```

- **Jamais dans l'image** : la clé n'est pas inscrite dans les images Podman. Changer de clé
  ne demande aucune reconstruction : la session suivante prend la nouvelle valeur.
- **Copie simple** : le fichier remplace celui de la sandbox. Les permissions « toujours
  autoriser » accordées en session ne sont pas perdues : Claude les enregistre dans le projet
  (`.claude/settings.local.json` dans votre dossier).
- **JSON invalide** : la copie est refusée et le fichier précédent est conservé.
- **Premier lancement** : l'écran d'accueil de Claude Code est sauté, pour arriver
  directement dans la session (la confirmation de confiance du dossier est demandée une fois
  par projet).
- Si votre `settings.json` Windows contient des hooks ou des chemins propres à Windows, pointez
  plutôt vers un fichier dédié, par exemple `%LOCALAPPDATA%\ai-sandbox\claude-settings.json`.
- La ligne `Réglages :` affichée au lancement indique le fichier utilisé ou le problème rencontré.
- Une installation antérieure conserve son ancien `config.psd1` : ajoutez-y le bloc `Settings`.

À noter : l'IA dans la sandbox peut lire cette clé (elle en a besoin pour fonctionner).
Préférez une clé dédiée, à portée et durée limitées, si votre gateway le permet.

## Image de base et registre d'entreprise

L'image de base est définie dans `config.psd1` :

```powershell
@{
    BaseImage = 'registry.access.redhat.com/ubi10/ubi:latest'
}
```

Pour pointer vers le registre interne de votre entreprise, au choix :

```powershell
# à l'installation (enregistré dans la configuration installée)
powershell -ExecutionPolicy Bypass -File .\install.ps1 -BaseImage registry.mon-entreprise.fr/ubi10/ubi:latest

# ou après coup : éditer %LOCALAPPDATA%\ai-sandbox\config.psd1, puis
& "$env:LOCALAPPDATA\ai-sandbox\ai-sandbox.ps1" -Rebuild
```

- Registre authentifié : `podman login registry.mon-entreprise.fr` une fois au préalable.
- **Registre npm** : si `registry.npmjs.org` n'est pas joignable, renseignez `NpmRegistry`
  (miroir Artifactory, Nexus, Verdaccio…), ou passez `install.ps1 -NpmRegistry <url>`.
  Il est enregistré dans le `~/.npmrc` de la sandbox : il sert à installer Claude Code et
  Gemini CLI, puis à l'IA pour ses propres `npm install`. npm utilise le magasin de
  certificats de l'image : une autorité de certification interne présente dans votre
  image UBI est donc reconnue automatiquement.
- L'image doit être une UBI 10 ou compatible (dnf, utilisateur root), avec des dépôts dnf
  qui fournissent au minimum `nodejs` (≥ 20), `npm`, `python3`, `git-core`, `sudo`, `gcc`, `make`.
  Une image interne dont les `.repo` pointent vers vos miroirs convient telle quelle.
- La réinstallation conserve votre `config.psd1` existant.
- Les sandboxes déjà créées gardent l'ancienne image : `-Reset` pour les recréer.

## Modèle de sécurité

Ce que le conteneur **ne voit pas** : le reste de vos disques, votre profil Windows,
`~/.ssh`, vos identifiants, les autres projets.

Ce qui reste possible :
- modifier ou supprimer le contenu du dossier monté → travaillez sur un dossier sous git
  ou sauvegardé, surtout en mode autonome ;
- accéder à Internet (nécessaire pour l'API et l'installation d'outils).

Garde-fous du lanceur : refus des disques entiers, de `C:\Users`, de votre profil,
de `Windows`, `Program Files`, `ProgramData`, `AppData`, et des chemins réseau.

## Ajouter un client IA

1. Créez `images/<nom>/Containerfile` (`FROM localhost/ai-sandbox-base:latest` + installation).
2. Ajoutez une entrée dans `clients.psd1` (commande, option autonome, clés d'API, emplacement du fichier de réglages).
3. Relancez `install.ps1`.

## Dépannage

| Symptôme | Piste |
|---|---|
| Pas d'entrée dans le menu sous Windows 11 | Afficher plus d'options / Maj + clic droit |
| Fenêtre qui se ferme aussitôt | Lancer `ai-sandbox.ps1` à la main dans PowerShell pour voir l'erreur |
| `Permission denied` dans `/workspace` | Vérifier `podman info --format '{{.Host.Security.Rootless}}'` puis `-Reset` |
| Claude demande une connexion | Vérifier la ligne `Réglages :` au lancement (fichier introuvable ou JSON invalide) |
| Sandbox créée avec une version précédente (volume partagé) | `-Reset` pour la recréer, puis `podman volume rm ai-sandbox-claude-config ai-sandbox-gemini-config` |
| Lenteur sur de gros projets | Les fichiers de `C:\` passent par le pont WSL : c'est plus lent qu'un disque natif |
| Échec du build de l'image de base | Vérifier `BaseImage`, `podman login`, et que les dépôts dnf de l'image fournissent les paquets requis |
| Échec `npm install` des clients IA | Registre npm injoignable : renseigner `NpmRegistry` dans `config.psd1`, puis `-Rebuild` |
| Mettre à jour Claude Code / Gemini CLI | `-Rebuild`, puis `-Reset` sur les sandboxes concernées |

## Désinstallation

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ai-sandbox\uninstall.ps1"          # menu seulement
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ai-sandbox\uninstall.ps1" -Purge   # tout
```
