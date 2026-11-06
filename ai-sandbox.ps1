<#
.SYNOPSIS
    Lance un client IA (Claude, Gemini...) dans un conteneur Podman qui ne voit
    QUE le dossier indique et ses sous-dossiers.

.DESCRIPTION
    - Un conteneur persistant par couple (client, dossier) : les outils que l'IA
      installe (apt, pip, npm) restent disponibles pour ce projet.
    - La configuration du client IA (historique, etat) est propre a chaque
      conteneur : rien n'est partage entre projets.
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
    ai-sandbox.ps1 -StopAll
#>
[CmdletBinding()]
param(
    [string]$Client = 'claude',
    [string]$Path,
    [switch]$Yolo,      # mode autonome (aucune demande de permission)
    [switch]$Shell,     # ouvre bash au lieu du client IA
    [switch]$Reset,     # supprime la sandbox de ce dossier (pas vos fichiers)
    [switch]$List,      # liste toutes les sandboxes
    [switch]$Rebuild,   # reconstruit les images (met a jour les clients IA)
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

# ---------------------------------------------------------- commandes globales

Assert-Podman

if ($List)    { Show-List; return }

if ($StopAll) {
    $ids = podman ps -q --filter label=ai-sandbox.path
    foreach ($id in $ids) { podman stop -t 2 $id | Out-Null }
    Write-Host "$(@($ids).Count) sandbox(es) arrêtée(s)."
    return
}

if ($Rebuild) {
    Build-Images @($Clients.Keys | Sort-Object)
    Write-Host "`nImages à jour. Les sandboxes existantes gardent l'ancienne image : -Reset pour les recréer." -ForegroundColor Green
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
$Image = "localhost/ai-sandbox-${Client}:latest"

if ($Reset) {
    podman container exists $Name
    if ($LASTEXITCODE -eq 0) {
        podman rm -f $Name | Out-Null
        Write-Host "Sandbox $Client supprimée pour $Path (vos fichiers sont intacts)." -ForegroundColor Green
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

podman container exists $Name
if ($LASTEXITCODE -ne 0) {
    $runArgs = @(
        'run', '-d', '--init',
        '--name', $Name,
        '--hostname', "sandbox-$Client",
        '-v', "${Path}:/workspace",
        '-w', '/workspace',
        '--label', "ai-sandbox.path=$Path",
        '--label', "ai-sandbox.client=$Client"
    )
    $rootless = "$(podman info --format '{{.Host.Security.Rootless}}')".Trim()
    if ($rootless -eq 'true') {
        # UID 1000 de la machine Podman <-> utilisateur "dev" du conteneur
        $runArgs += '--userns=keep-id:uid=1000,gid=1000'
    }
    $runArgs += $Image

    & podman @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Exit-WithMessage "Impossible de créer la sandbox $Name." }
    $isNew = $true
} else {
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
