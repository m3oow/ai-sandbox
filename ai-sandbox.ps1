<#
.SYNOPSIS
    Lance un client IA (Claude, Gemini...) dans un conteneur Podman qui ne voit
    QUE le dossier indique et ses sous-dossiers.

.DESCRIPTION
    - Un conteneur persistant par couple (client, dossier) : les outils que l'IA
      installe (dnf, pip, npm) restent disponibles pour ce projet, jusqu'a la
      prochaine mise a jour de la sandbox (-Update).
    - La configuration du client IA (historique, sessions, etat) est propre a
      chaque sandbox, dans un volume dedie : rien n'est partage entre projets.
    - -Rebuild reconstruit les images sans toucher aux sandboxes (la nouvelle
      image peut etre testee sur une nouvelle sandbox) ; -Update recree ensuite
      toutes les sandboxes sur la derniere image en conservant ce volume, donc
      l'historique de l'agent IA.
    - Le fichier de reglages Windows (config.psd1 > Settings) est recopie dans
      le conteneur a chaque lancement.
    - Aucun autre fichier de l'hote n'est monte.

.EXAMPLE
    ai-sandbox.ps1 -Client claude -Path "C:\Projets\demo"
    ai-sandbox.ps1 -Client gemini -Yolo
    ai-sandbox.ps1 -Shell                 # bash dans la sandbox du dossier courant
    ai-sandbox.ps1 -List
    ai-sandbox.ps1 -Reset -Path "C:\Projets\demo"
    ai-sandbox.ps1 -Rebuild
    ai-sandbox.ps1 -Update
    ai-sandbox.ps1 -ResetAll              # supprime toutes les sandboxes, leurs volumes et les anciennes images
    ai-sandbox.ps1 -StopAll
#>
[CmdletBinding()]
param(
    [string]$Client = 'claude',
    [string]$Path,
    [switch]$Yolo,      # mode autonome (aucune demande de permission)
    [switch]$Shell,     # ouvre bash au lieu du client IA
    [switch]$Reset,     # supprime la sandbox de ce dossier et son historique (pas vos fichiers)
    [switch]$List,      # liste toutes les sandboxes
    [switch]$Rebuild,   # reconstruit les images (met a jour les clients IA)
    [switch]$Update,    # recree les sandboxes sur la derniere image (historique conserve)
    [switch]$ResetAll,  # supprime TOUTES les sandboxes, leurs volumes et les anciennes images (garde les :latest)
    [switch]$Force,     # avec -ResetAll : pas de demande de confirmation
    [switch]$StopAll    # arrete toutes les sandboxes en cours
)

$Root    = $PSScriptRoot
$Clients = Import-PowerShellDataFile (Join-Path $Root 'clients.psd1')

$DefaultBaseImage = 'registry.access.redhat.com/ubi10/ubi:latest'
$Config = @{}
$configFile = Join-Path $Root 'config.psd1'
if (Test-Path -LiteralPath $configFile) { $Config = Import-PowerShellDataFile $configFile }
$BaseImage = if ($Config.BaseImage) { "$($Config.BaseImage)".Trim() } else { $DefaultBaseImage }
$NpmRegistry = if ($Config.NpmRegistry) { "$($Config.NpmRegistry)".Trim() } else { '' }
$PipIndexUrl = if ($Config.PipIndexUrl) { "$($Config.PipIndexUrl)".Trim() } else { '' }

# ---------------------------------------------------------------- utilitaires

function Exit-WithMessage([string]$Message) {
    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null
    exit 1
}

function Assert-Podman {
    if (-not (Get-Command podman -ErrorAction SilentlyContinue)) {
        Exit-WithMessage 'podman.exe introuvable. Installez Podman Desktop ou ajoutez podman au PATH.'
    }
    podman info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Démarrage de la machine Podman...' -ForegroundColor DarkGray
        podman machine start
        podman info *> $null
        if ($LASTEXITCODE -ne 0) {
            Exit-WithMessage 'Impossible de joindre la machine Podman (podman machine start a échoué).'
        }
    }
}

function Build-Images([string[]]$Names) {
    $imgDir = Join-Path $Root 'images'

    Write-Host "`n== Image de base ($BaseImage) ==" -ForegroundColor Cyan
    Write-Host "   Registre npm : $(if ($NpmRegistry) { $NpmRegistry } else { 'public (registry.npmjs.org)' })" -ForegroundColor DarkGray
    Write-Host "   Index pip    : $(if ($PipIndexUrl) { $PipIndexUrl } else { 'public (pypi.org)' })" -ForegroundColor DarkGray
    podman build --pull=newer `
        --build-arg "BASE_IMAGE=$BaseImage" `
        --build-arg "NPM_REGISTRY=$NpmRegistry" `
        --build-arg "PIP_INDEX_URL=$PipIndexUrl" `
        --label "ai-sandbox.base-image=$BaseImage" `
        -t ai-sandbox-base:latest (Join-Path $imgDir 'base')
    if ($LASTEXITCODE -ne 0) {
        Exit-WithMessage ("Échec de la construction de l'image de base depuis $BaseImage.`n" +
            "Vérifiez BaseImage dans $configFile, l'accès au registre (podman login <registre>), " +
            "que les dépôts dnf de l'image fournissent les paquets requis " +
            "et que PipIndexUrl (si renseigné) permet de télécharger les bibliothèques Python.")
    }

    foreach ($n in $Names) {
        Write-Host "`n== Image $n ==" -ForegroundColor Cyan
        # --no-cache : récupère toujours la dernière version du client IA
        podman build --no-cache --build-arg "NPM_REGISTRY=$NpmRegistry" `
            -t "ai-sandbox-${n}:latest" (Join-Path $imgDir $n)
        if ($LASTEXITCODE -ne 0) {
            Exit-WithMessage ("Échec de la construction de l'image $n.`n" +
                "Si npm n'a pas pu télécharger le client, vérifiez NpmRegistry dans $configFile.")
        }
    }
}

function Get-Sandboxes {
    $json = podman ps -a --filter label=ai-sandbox.path --format json
    if (-not $json) { return @() }
    $parsed = ($json -join "`n") | ConvertFrom-Json
    $out = @()
    foreach ($c in $parsed) { $out += $c }   # foreach : contourne le comportement de PS 5.1
    return $out
}

function Show-List {
    $rows = foreach ($c in Get-Sandboxes) {
        [pscustomobject]@{
            Client  = $c.Labels.'ai-sandbox.client'
            Etat    = $c.State
            Dossier = $c.Labels.'ai-sandbox.path'
            Nom     = ($c.Names -join ',')
        }
    }
    if (-not $rows) { Write-Host 'Aucune sandbox.'; return }
    $rows | Sort-Object Dossier, Client | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
}

function Get-ClientImage([string]$ClientName) { "localhost/ai-sandbox-${ClientName}:latest" }

# Volume d'état (historique de l'agent IA) associé à une sandbox
function Get-StateVolume([string]$Name) { "$Name-state" }

# Supprime les anciennes images ai-sandbox devenues inutiles (sans tag : les
# images clients héritent du label de l'image de base). Les images :latest et
# les autres images de Podman ne sont pas touchées.
function Remove-ObsoleteImages {
    podman image prune -f --filter label=ai-sandbox.base-image | Out-Null
}

# Vrai si la sandbox n'utilise pas l'image actuelle de son client
function Test-SandboxOutdated([string]$Name, [string]$ClientName) {
    $current = "$(podman image inspect --format '{{.Id}}' (Get-ClientImage $ClientName) 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $current) { return $false }
    $used = "$(podman inspect --format '{{.Image}}' $Name 2>$null)".Trim()
    if ($LASTEXITCODE -ne 0 -or -not $used) { return $false }
    return ($used -ne $current)
}

# Crée la sandbox $Name pour ($ClientName, $SandboxPath), avec son volume d'état.
# -NoStart : crée le conteneur sans le démarrer. Renvoie $true en cas de succès.
function New-Sandbox {
    param(
        [string]$ClientName,
        [string]$SandboxPath,
        [string]$Name,
        [switch]$NoStart
    )
    $clientCfg = $Clients[$ClientName]

    # @(...) obligatoire : un tableau d'un seul élément renvoyé par if devient une chaîne
    $runArgs = @(if ($NoStart) { 'create' } else { 'run', '-d' })
    $runArgs += @(
        '--init',
        '--name', $Name,
        '--hostname', "sandbox-$ClientName",
        '-v', "${SandboxPath}:/workspace",
        '-w', '/workspace',
        '--label', "ai-sandbox.path=$SandboxPath",
        '--label', "ai-sandbox.client=$ClientName"
    )

    if ($clientCfg.StateDir) {
        # Volume créé explicitement pour porter les labels (nettoyage par -Purge).
        # Vide à sa création : Podman y copie le contenu du dossier de l'image au
        # premier montage. Il est réutilisé tel quel lors d'une recréation.
        $vol = Get-StateVolume $Name
        podman volume exists $vol
        if ($LASTEXITCODE -ne 0) {
            podman volume create --label "ai-sandbox.path=$SandboxPath" `
                --label "ai-sandbox.client=$ClientName" $vol | Out-Null
            if ($LASTEXITCODE -ne 0) { return $false }
        }
        $runArgs += @('-v', "${vol}:$($clientCfg.StateDir)")
    }

    if ($null -eq $script:Rootless) {
        $script:Rootless = "$(podman info --format '{{.Host.Security.Rootless}}')".Trim()
    }
    if ($script:Rootless -eq 'true') {
        # UID 1000 de la machine Podman <-> utilisateur "dev" du conteneur
        $runArgs += '--userns=keep-id:uid=1000,gid=1000'
    }
    $runArgs += Get-ClientImage $ClientName

    & podman @runArgs | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Sandboxes qui n'utilisent pas la dernière image de leur client
function Get-OutdatedSandboxes {
    $out = @()
    foreach ($c in Get-Sandboxes) {
        $clientName = $c.Labels.'ai-sandbox.client'
        if ($Clients.ContainsKey($clientName) -and (Test-SandboxOutdated @($c.Names)[0] $clientName)) { $out += $c }
    }
    return $out
}

# -Update : recrée sur la dernière image chaque sandbox qui ne l'utilise pas
# encore. Le volume d'état est conservé ; les sessions ouvertes sont coupées.
function Update-AllSandboxes {
    $recreated = @(); $unchanged = @(); $orphans = @(); $failed = @()

    foreach ($c in Get-Sandboxes) {
        $name       = @($c.Names)[0]
        $clientName = $c.Labels.'ai-sandbox.client'
        $sbPath     = $c.Labels.'ai-sandbox.path'
        $row = [pscustomobject]@{ Nom = $name; Client = $clientName; Dossier = $sbPath; Detail = '' }

        if (-not $Clients.ContainsKey($clientName)) {
            $row.Detail = "client '$clientName' absent de clients.psd1"
            $failed += $row; continue
        }
        if (-not (Test-SandboxOutdated $name $clientName)) { $unchanged += $row; continue }

        # Dossier supprimé, déplacé, renommé ou disque non branché : la recréation
        # échouerait (montage impossible), on laisse la sandbox telle quelle.
        if (-not (Test-Path -LiteralPath $sbPath -PathType Container)) { $orphans += $row; continue }

        $wasRunning = ("$($c.State)" -eq 'running')
        Write-Host "Recréation de $name ($sbPath)..." -ForegroundColor DarkGray
        podman rm -f $name | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $row.Detail = 'suppression du conteneur impossible'
            $failed += $row; continue
        }
        if (New-Sandbox -ClientName $clientName -SandboxPath $sbPath -Name $name -NoStart:(-not $wasRunning)) {
            $recreated += $row
        } else {
            $row.Detail = 'création impossible (historique conservé : relancez la mise à jour ou la sandbox)'
            $failed += $row
        }
    }

    Remove-ObsoleteImages

    Write-Host "`n== Sandboxes ==" -ForegroundColor Cyan
    Write-Host "  Recréées sur la nouvelle image : $($recreated.Count)" -ForegroundColor Green
    foreach ($r in $recreated) { Write-Host "    $($r.Client)  $($r.Dossier)" }
    Write-Host "  Déjà à jour : $($unchanged.Count)"

    if ($failed) {
        Write-Host "  En échec : $($failed.Count)" -ForegroundColor Red
        foreach ($r in $failed) { Write-Host "    $($r.Client)  $($r.Dossier) : $($r.Detail)" -ForegroundColor Red }
    }

    if ($orphans) {
        Write-Host "  Ignorées, dossier introuvable : $($orphans.Count)" -ForegroundColor Yellow
        foreach ($r in $orphans) {
            Write-Host "    $($r.Client)  $($r.Dossier)" -ForegroundColor Yellow
            Write-Host "      nettoyage : podman rm -f $($r.Nom) ; podman volume rm $(Get-StateVolume $r.Nom)" -ForegroundColor DarkGray
        }
        Write-Host ("  Disque non branché : rebranchez-le puis relancez la mise à jour.`n" +
                    "  Dossier supprimé ou déplacé : la sandbox est orpheline,`n" +
                    "  supprimez-la avec les commandes de nettoyage ci-dessus (historique compris).") -ForegroundColor Yellow
    }
}

# -ResetAll : supprime toutes les sandboxes, TOUS leurs volumes (historique des agents IA
# compris) et les anciennes images ai-sandbox. Les images :latest, les dossiers de
# travail et les autres ressources Podman ne sont pas touchés.
function Reset-All {
    $containers = @(podman ps -aq --filter label=ai-sandbox.path)
    # Volumes d'état (label) + volumes partagés d'anciennes versions (ai-sandbox-*)
    $volumes = @(podman volume ls -q --filter label=ai-sandbox.path) +
               @(podman volume ls --format '{{.Name}}' | Where-Object { $_ -like 'ai-sandbox-*' })
    $volumes = @($volumes | Where-Object { $_ } | Sort-Object -Unique)
    $images  = @(podman image ls -q --filter dangling=true --filter label=ai-sandbox.base-image)

    if (-not $containers -and -not $volumes -and -not $images) {
        Write-Host 'Rien à supprimer.'
        return
    }

    Write-Host "`n== Réinitialisation complète ==" -ForegroundColor Cyan
    Write-Host "  Sandboxes à supprimer        : $($containers.Count)"
    Write-Host "  Volumes à supprimer          : $($volumes.Count) (historique des agents IA compris)"
    Write-Host "  Anciennes images à supprimer : $($images.Count) (les images :latest sont conservées)"
    Write-Host '  Vos dossiers de travail ne sont pas touchés.'

    if (-not $Force) {
        Write-Host ''
        Write-Host "Attention : l'historique des agents IA et les outils installés dans les sandboxes seront perdus définitivement." -ForegroundColor Yellow
        $answer = Read-Host 'Confirmer la suppression ? [o/N]'
        if ($answer -notmatch '^[oOyY]') {
            Write-Host 'Annulé : rien n''a été supprimé.'
            return
        }
    }

    # Conteneurs d'abord (sinon volumes et images restent « utilisés »)
    $failed = 0
    foreach ($id in $containers) {
        podman rm -f $id | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    foreach ($v in $volumes) {
        podman volume rm -f $v | Out-Null
        if ($LASTEXITCODE -ne 0) { $failed++ }
    }
    Remove-ObsoleteImages

    Write-Host "`n== Bilan ==" -ForegroundColor Cyan
    Write-Host "  Sandboxes supprimées         : $($containers.Count)"
    Write-Host "  Volumes supprimés            : $($volumes.Count)"
    Write-Host "  Anciennes images supprimées  : $($images.Count)"
    if ($failed) {
        Write-Host "  Suppressions en échec : $failed (relancez, ou vérifiez avec podman ps -a / podman volume ls)" -ForegroundColor Red
    } else {
        Write-Host "`nRéinitialisation terminée." -ForegroundColor Green
    }
}

# ---------------------------------------------------------- commandes globales

Assert-Podman

if ($List)    { Show-List; return }

if ($ResetAll) { Reset-All; return }

if ($StopAll) {
    $ids = podman ps -q --filter label=ai-sandbox.path
    foreach ($id in $ids) { podman stop -t 2 $id | Out-Null }
    Write-Host "$(@($ids).Count) sandbox(es) arrêtée(s)."
    return
}

if ($Rebuild) {
    Build-Images @($Clients.Keys | Sort-Object)
    Write-Host "`nImages à jour." -ForegroundColor Green
    $outdated = @(Get-OutdatedSandboxes)
    if ($outdated.Count -gt 0) {
        Write-Host ("$($outdated.Count) sandbox(es) existante(s) sur une ancienne image. Testez la nouvelle image " +
                    "sur une nouvelle sandbox, puis « Mettre à jour les sandboxes » (-Update) pour l'appliquer " +
                    "à toutes (historique conservé).") -ForegroundColor Yellow
    }
    return
}

if ($Update) {
    Update-AllSandboxes
    return
}

# ------------------------------------------------------- client et dossier

if (-not $Clients.ContainsKey($Client)) {
    Exit-WithMessage "Client inconnu : '$Client'. Disponibles : $(($Clients.Keys | Sort-Object) -join ', ')"
}
$cfg = $Clients[$Client]

if (-not $Path) { $Path = (Get-Location).ProviderPath }
try {
    $Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
} catch {
    Exit-WithMessage "Dossier introuvable : $Path"
}
$Path = $Path.TrimEnd('\')

# Garde-fous : on ne monte jamais un périmètre trop large
if ($Path.StartsWith('\\')) {
    Exit-WithMessage "Chemin réseau ou \\wsl$ non pris en charge : $Path`nUtilisez un dossier sur un disque local (C:\, D:\...)."
}
if ($Path -match '^[A-Za-z]:$') {
    Exit-WithMessage "Refusé : '$Path\' est un disque entier, trop large pour une sandbox."
}
$forbidden = @(
    $env:USERPROFILE,
    (Split-Path $env:USERPROFILE -Parent),
    $env:SystemRoot,
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    $env:LOCALAPPDATA,
    $env:APPDATA
) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
foreach ($f in $forbidden) {
    if ($Path -ieq $f) { Exit-WithMessage "Refusé : '$Path' est trop large pour une sandbox." }
}
if ($env:SystemRoot -and $Path.StartsWith($env:SystemRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Exit-WithMessage "Refusé : '$Path' est dans le dossier Windows."
}

# Nom de conteneur stable pour ce couple (client, dossier)
$sha   = [Security.Cryptography.SHA1]::Create()
$bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
$hash  = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
$Name  = "ai-$Client-$($hash.Substring(0, 10))"
$Image = Get-ClientImage $Client

if ($Reset) {
    # Supprime tout : le conteneur et l'historique de l'agent IA (volume d'état)
    $found = $false
    podman container exists $Name
    if ($LASTEXITCODE -eq 0) {
        podman rm -f $Name | Out-Null
        if ($LASTEXITCODE -ne 0) { Exit-WithMessage "Impossible de supprimer la sandbox $Name." }
        $found = $true
    }
    $vol = Get-StateVolume $Name
    podman volume exists $vol
    if ($LASTEXITCODE -eq 0) {
        podman volume rm -f $vol | Out-Null
        if ($LASTEXITCODE -ne 0) { Exit-WithMessage "Impossible de supprimer l'historique $vol." }
        $found = $true
    }
    if ($found) {
        Write-Host "Sandbox $Client et son historique supprimés pour $Path (vos fichiers sont intacts)." -ForegroundColor Green
    } else {
        Write-Host "Aucune sandbox $Client pour $Path."
    }
    return
}

# ------------------------------------------------ création / démarrage

podman image exists $Image
if ($LASTEXITCODE -ne 0) {
    Write-Host "Image $Image absente : construction (quelques minutes la première fois)..." -ForegroundColor Yellow
    Build-Images @($Client)
}

$outdated = $false
podman container exists $Name
if ($LASTEXITCODE -ne 0) {
    # Nouvelle sandbox, ou recréation après une mise à jour qui a échoué :
    # dans ce cas, l'historique est retrouvé dans le volume d'état.
    podman volume exists (Get-StateVolume $Name)
    $isNew = ($LASTEXITCODE -ne 0)
    if (-not (New-Sandbox -ClientName $Client -SandboxPath $Path -Name $Name)) {
        Exit-WithMessage "Impossible de créer la sandbox $Name."
    }
} else {
    # Pas de recréation automatique : la nouvelle image s'applique avec -Update
    $outdated = Test-SandboxOutdated $Name $Client
    $running = "$(podman inspect --format '{{.State.Running}}' $Name)".Trim()
    if ($running -ne 'true') {
        podman start $Name | Out-Null
        if ($LASTEXITCODE -ne 0) { Exit-WithMessage "Impossible de démarrer la sandbox $Name." }
    }
    $isNew = $false
}

# --------------------------------------------- synchronisation des réglages

$settingsInfo = 'aucun'
$settingsSrc  = if ($Config.Settings -and $Config.Settings[$Client]) { "$($Config.Settings[$Client])".Trim() } else { '' }
if ($settingsSrc -and $cfg.SettingsTarget) {
    $settingsSrc = [Environment]::ExpandEnvironmentVariables($settingsSrc)
    if (Test-Path -LiteralPath $settingsSrc -PathType Leaf) {
        $settingsSrc = (Resolve-Path -LiteralPath $settingsSrc).ProviderPath
        # Le script de synchronisation est transmis dans une variable d'environnement (base64)
        # et non sur l'entrée standard : un tube vers podman.exe peut ne pas arriver au conteneur
        # sous Windows, et bash lit alors le clavier (le script semble figé).
        # Fins de ligne Unix forcées, rien à installer dans l'image.
        $script  = (Get-Content -LiteralPath (Join-Path $Root 'lib\sync-settings.sh') -Raw) -replace "`r", ''
        $scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
        $syncArgs = @('exec',
            '-e', "AI_SANDBOX_SYNC_B64=$scriptB64",
            '-e', "AI_SANDBOX_SETTINGS_B64=$([Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsSrc)))",
            '-e', "AI_SANDBOX_SETTINGS_TARGET=$($cfg.SettingsTarget)")
        if ($cfg.OnboardingFile) { $syncArgs += @('-e', "AI_SANDBOX_ONBOARDING=$($cfg.OnboardingFile)") }
        $syncArgs += @($Name, 'bash', '-c', 'echo $AI_SANDBOX_SYNC_B64 | base64 -d | bash')

        & podman @syncArgs
        if ($LASTEXITCODE -eq 0) {
            $settingsInfo = $settingsSrc
        } else {
            $settingsInfo = "ÉCHEC de la copie ($settingsSrc)"
        }
    } else {
        $settingsInfo = "fichier introuvable : $settingsSrc"
    }
}

# ------------------------------------------------------------- session

$mode = if ($Shell) { 'shell bash' } elseif ($Yolo) { 'AUTONOME (sans demande de permission)' } else { 'standard' }
$Host.UI.RawUI.WindowTitle = "$($cfg.Label) sandbox - $(Split-Path $Path -Leaf)"

Write-Host ''
Write-Host "  Sandbox  : $Name$(if ($isNew) { ' (nouvelle)' })" -ForegroundColor Cyan
Write-Host "  Dossier  : $Path  ->  /workspace" -ForegroundColor Cyan
Write-Host "  Client   : $($cfg.Label)   Mode : $mode" -ForegroundColor Cyan
if ($settingsSrc) {
    $color = if ($settingsInfo -eq $settingsSrc) { 'Cyan' } else { 'Yellow' }
    Write-Host "  Réglages : $settingsInfo" -ForegroundColor $color
}
if ($outdated) {
    Write-Host "  Image    : plus récente disponible, « Mettre à jour les sandboxes » (-Update) pour l'appliquer" -ForegroundColor Yellow
}
if ($Yolo) {
    Write-Host "  Attention : l'IA peut modifier ou supprimer tout le contenu de ce dossier." -ForegroundColor Yellow
}
Write-Host ''

$execArgs = @('exec', '-it', '-w', '/workspace',
              '-e', 'TERM=xterm-256color', '-e', 'COLORTERM=truecolor')

# Clés d'API éventuellement définies sous Windows : transmises à la session
# uniquement (jamais stockées dans la configuration du conteneur).
foreach ($k in $cfg.EnvKeys) {
    $v = [Environment]::GetEnvironmentVariable($k)
    if ($v) { $execArgs += @('-e', "$k=$v") }
}

$execArgs += $Name
if ($Shell) {
    $execArgs += 'bash'
} else {
    $execArgs += $cfg.Command
    if ($Yolo) { $execArgs += $cfg.YoloArgs }
}

& podman @execArgs
$code = $LASTEXITCODE

# Garde la fenêtre ouverte en cas d'erreur pour pouvoir lire le message
if ($code -ne 0 -and $code -ne 130) {
    Write-Host ''
    Write-Host "La session s'est terminée avec le code $code." -ForegroundColor Yellow
    Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null
}
exit $code
