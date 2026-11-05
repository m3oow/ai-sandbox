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

Le script copie dans `%LOCALAPPDATA%\ai-sandbox` les seuls fichiers nécessaires à l'exécution
(`ai-sandbox.ps1`, `uninstall.ps1`, `config.psd1`, `clients.psd1`, `lib\`, `images\`), construit
les images depuis UBI 10 (`ai-sandbox-base`, `ai-sandbox-claude`, `ai-sandbox-gemini`) et ajoute
le menu contextuel. `install.ps1` lui-même, le README et les fichiers cachés (`.git`,
`.gitignore`…) ne sont pas installés : relancez l'installation depuis le dossier source.
Aucun droit administrateur n'est nécessaire.

Sous Windows 11, le menu est dans **Afficher plus d'options** (ou Maj + clic droit).

### Installation manuelle (sans `install.ps1`)

Si vous préférez ne pas lancer `install.ps1` (par exemple en contexte professionnel, où
`-ExecutionPolicy Bypass` ou l'écriture dans le registre par un script peuvent déclencher une
alerte de sécurité), chaque étape peut être faite à la main, une commande à la fois, depuis
PowerShell. Rien n'exige de droits administrateur, tout reste dans votre profil.

Les commandes ci-dessous supposent que vous êtes dans le dossier décompressé.

**1. Vérifier Podman**

```powershell
podman --version
podman machine start          # si la machine n'est pas déjà démarrée
podman info --format '{{.Host.Security.Rootless}}'   # doit afficher true (rootless)
```

**2. Copier les fichiers dans `%LOCALAPPDATA%\ai-sandbox`**

```powershell
$Dest = "$env:LOCALAPPDATA\ai-sandbox"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($item in 'ai-sandbox.ps1', 'clients.psd1', 'config.psd1', 'uninstall.ps1', 'lib', 'images') {
    Copy-Item -LiteralPath $item -Destination $Dest -Recurse -Force
}
Get-ChildItem -Path $Dest -Recurse -File | Unblock-File   # retire la marque « téléchargé depuis Internet »
```

`Unblock-File` permet d'exécuter `ai-sandbox.ps1` avec la politique d'exécution `RemoteSigned`
habituelle, sans avoir à la contourner. En cas de réinstallation, ne recopiez pas par-dessus
un `config.psd1` que vous avez modifié.

**3. (Facultatif) Adapter la configuration**

Éditez `%LOCALAPPDATA%\ai-sandbox\config.psd1` pour `BaseImage` (registre interne),
`NpmRegistry` et `Settings` (voir plus bas).

**4. Construire les images**

Si votre registre exige une authentification : `podman login <registre>` au préalable.
Remplacez `BASE` et `NPM` par les valeurs de `config.psd1` (`NPM` peut rester vide).

```powershell
cd "$env:LOCALAPPDATA\ai-sandbox\images"
$BASE = 'registry.access.redhat.com/ubi10/ubi:latest'
$NPM  = ''

podman build --build-arg "BASE_IMAGE=$BASE" --build-arg "NPM_REGISTRY=$NPM" `
    --label "ai-sandbox.base-image=$BASE" -t ai-sandbox-base:latest .\base

podman build --no-cache --build-arg "NPM_REGISTRY=$NPM" -t ai-sandbox-claude:latest .\claude
podman build --no-cache --build-arg "NPM_REGISTRY=$NPM" -t ai-sandbox-gemini:latest .\gemini   # facultatif
```

Vérification : `podman images` doit lister `localhost/ai-sandbox-base`, `-claude` et `-gemini`.

**5. Utiliser sans menu contextuel**

À ce stade, la sandbox est déjà utilisable en ligne de commande (voir « En ligne de commande ») :

```powershell
& "$env:LOCALAPPDATA\ai-sandbox\ai-sandbox.ps1" -Client claude -Path C:\Projets\demo
```

**6. (Facultatif) Ajouter le menu contextuel à la main**

Le menu n'est qu'un ensemble de clés sous `HKCU` (votre utilisateur uniquement). Pour chaque
entrée, créez une clé dont la sous-clé `command` contient la commande à lancer. Exemple pour
Claude (l'entrée shell de Claude, puis les deux entrées de Gemini, suivent le même modèle,
avec `-Shell` et/ou `-Client gemini`) :

```powershell
$ps1  = "$env:LOCALAPPDATA\ai-sandbox\ai-sandbox.ps1"
$icon = "$((Get-Command podman).Source),0"

foreach ($b in 'HKCU:\Software\Classes\Directory\shell\AISandbox',
               'HKCU:\Software\Classes\Directory\Background\shell\AISandbox') {
    New-Item -Path $b -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name MUIVerb     -Value 'Lancer IA sandboxée' -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name SubCommands -Value ''                    -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name Icon        -Value $icon                 -Force | Out-Null

    $k = "$b\shell\01-claude"
    New-Item -Path "$k\command" -Force | Out-Null
    New-ItemProperty -LiteralPath $k -Name MUIVerb -Value 'Claude' -Force | Out-Null
    Set-ItemProperty -LiteralPath "$k\command" -Name '(default)' `
        -Value "wt.exe -w new powershell.exe -NoProfile -File `"$ps1`" -Client claude -Path `"%V`""
}
```

- Sans Windows Terminal, retirez le préfixe `wt.exe -w new `.
- `%V` est remplacé par Windows avec le dossier cliqué.
- Pour l'entrée shell, ajoutez `-Shell` avant `-Path` (voir « Utilisation »).

#### Détail des clés de registre (pour `regedit`)

Tout est sous `HKEY_CURRENT_USER` (HKCU) : pas de droits administrateur. Les deux arborescences
suivantes sont **identiques** et doivent toutes deux être créées : la première pour le clic
droit *sur* un dossier, la seconde pour le clic droit *dans* un dossier ouvert (fond de fenêtre).

```
HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox
HKEY_CURRENT_USER\Software\Classes\Directory\Background\shell\AISandbox
```

Arborescence à reproduire sous chacune des deux clés `AISandbox` :

```
AISandbox
│   MUIVerb      REG_SZ     Lancer IA sandboxée
│   SubCommands  REG_SZ     (chaîne vide)
│   Icon         REG_SZ     <chemin de podman.exe>,0
└── shell
    ├── 01-claude
    │   │   MUIVerb        REG_SZ     Claude
    │   └── command
    │         (Par défaut)  REG_SZ     <commande Claude>
    ├── 02-claude-shell
    │   │   MUIVerb        REG_SZ     Claude (shell)
    │   └── command
    │         (Par défaut)  REG_SZ     <commande Claude shell>
    ├── 03-gemini
    │   │   MUIVerb        REG_SZ     Gemini
    │   │   CommandFlags   REG_DWORD  0x00000020   (séparateur au-dessus de cette entrée)
    │   └── command
    │         (Par défaut)  REG_SZ     <commande Gemini>
    └── 04-gemini-shell
        │   MUIVerb        REG_SZ     Gemini (shell)
        └── command
              (Par défaut)  REG_SZ     <commande Gemini shell>
```

Points d'attention :

- `SubCommands` doit exister avec une valeur **vide** : c'est ce qui transforme l'entrée en
  sous-menu déroulant. Sans elle, Windows n'affiche pas les entrées de `shell`.
- Le préfixe numérique des sous-clés (`01-`, `02-`…) fixe l'ordre d'affichage.
- `(Par défaut)` est la valeur sans nom de la sous-clé `command`. Dans regedit : double-clic
  sur `(Par défaut)` puis saisie de la commande.
- Pour n'avoir que Claude, ne créez que `01-claude` et `02-claude-shell`.
- `Icon` : obtenez le chemin avec `(Get-Command podman).Source` ; ajoutez `,0` à la fin
  (première icône du fichier). Facultatif.

Commandes à saisir (remplacez `<UTILISATEUR>` par votre nom de profil Windows, le chemin doit
être absolu : regedit n'étend pas `%LOCALAPPDATA%` dans une valeur `REG_SZ`) :

| Entrée | Valeur de `command` |
|---|---|
| `01-claude` | `wt.exe -w new powershell.exe -NoProfile -File "C:\Users\<UTILISATEUR>\AppData\Local\ai-sandbox\ai-sandbox.ps1" -Client claude -Path "%V"` |
| `02-claude-shell` | idem `01-claude`, avec ` -Shell` avant ` -Path` |
| `03-gemini` | idem `01-claude`, avec `-Client gemini` |
| `04-gemini-shell` | idem `03-gemini`, avec ` -Shell` avant ` -Path` |

- `%V` doit rester tel quel : Windows le remplace par le dossier cliqué.
- Sans Windows Terminal, supprimez le préfixe `wt.exe -w new `.
- `install.ps1` ajoute en plus `-ExecutionPolicy Bypass` après `-NoProfile`. C'est inutile si
  vous avez fait `Unblock-File` (étape 2) avec une politique `RemoteSigned`.

**Import par fichier `.reg`** (alternative à la saisie dans regedit) : enregistrez le contenu
suivant dans un fichier `ai-sandbox-menu.reg` (encodage Unicode/UTF-16 LE, celui de regedit ;
si vous l'éditez à la main, enregistrez-le ainsi, sinon `sandboxée` sera mal lu), remplacez
`<UTILISATEUR>` et `<CHEMIN PODMAN>` (antislashs doublés), puis double-cliquez dessus. L'exemple
couvre Claude ; pour Gemini, dupliquez les blocs sur le même modèle (`03-gemini`, `04-gemini-shell`). Le bloc est à répéter pour la seconde racine (`...\Directory\Background\shell\...`).

```
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox]
"MUIVerb"="Lancer IA sandboxée"
"SubCommands"=""
"Icon"="<CHEMIN PODMAN>,0"

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox\shell\01-claude]
"MUIVerb"="Claude"

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox\shell\01-claude\command]
@="wt.exe -w new powershell.exe -NoProfile -File \"C:\\Users\\<UTILISATEUR>\\AppData\\Local\\ai-sandbox\\ai-sandbox.ps1\" -Client claude -Path \"%V\""

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox\shell\02-claude-shell]
"MUIVerb"="Claude (shell)"

[HKEY_CURRENT_USER\Software\Classes\Directory\shell\AISandbox\shell\02-claude-shell\command]
@="wt.exe -w new powershell.exe -NoProfile -File \"C:\\Users\\<UTILISATEUR>\\AppData\\Local\\ai-sandbox\\ai-sandbox.ps1\" -Client claude -Shell -Path \"%V\""
```

Dans un fichier `.reg`, `\` s'écrit `\\` et `"` s'écrit `\"` ; une valeur `REG_DWORD`
s'écrit `"CommandFlags"=dword:00000020`.

Pour retirer le menu : supprimez les deux clés `AISandbox` (voir « Désinstallation » ci-dessous).
Le menu apparaît sans redémarrage ; sous Windows 11, il est dans **Afficher plus d'options**.

## Utilisation

| Entrée du menu | Effet |
|---|---|
| Claude / Gemini | Session normale : le client demande avant d'agir |
| Claude (shell) / Gemini (shell) | Ouvre un `bash` dans la sandbox du dossier, sans lancer l'agent |

Les entrées « shell » ouvrent un terminal dans **le même conteneur** que l'agent du dossier
(un conteneur par couple client + dossier) : vous pouvez manipuler les fichiers en shell pendant
qu'un agent tourne dans une autre fenêtre. Ils partagent les outils installés et la configuration
du client, mais pas le terminal.

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

### Désinstallation manuelle

```powershell
# menu contextuel
Remove-Item -Recurse -Force 'HKCU:\Software\Classes\Directory\shell\AISandbox',
                            'HKCU:\Software\Classes\Directory\Background\shell\AISandbox'

# sandboxes, images, fichiers (équivalent de -Purge)
podman ps -aq --filter label=ai-sandbox.path | ForEach-Object { podman rm -f $_ }
podman rmi -f ai-sandbox-claude ai-sandbox-gemini ai-sandbox-base
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\ai-sandbox"
```
