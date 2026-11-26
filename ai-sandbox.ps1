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
    [switch]$StopAll,   # arrete toutes les sandboxes en cours
    [switch]$NewWindow  # usage interne (menu contextuel) : relance le script dans un terminal
)

# Lancement depuis le menu contextuel avec Windows Terminal : le registre ne passe
# jamais le dossier cliqué (%V) à wt.exe, qui découpe sa ligne de commande sur « ; »
# MÊME entre guillemets (un dossier nommé « x; nt calc » exécuterait « calc » sur
# l'hôte). Ce lanceur (fenêtre masquée) rouvre le script dans un terminal visible,
# et n'utilise pas wt.exe si le chemin contient un « ; ».
if ($NewWindow) {
    $p = if ($Path) { $Path } else { (Get-Location).ProviderPath }
    if ($p.EndsWith('\')) { $p += '.' }   # sinon « C:\" » est lu comme un guillemet échappé
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Client `"$Client`""
    if ($Shell) { $argLine += ' -Shell' }
    if ($Yolo)  { $argLine += ' -Yolo' }
    $argLine += " -Path `"$p`""
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt -and -not $argLine.Contains(';')) {
        Start-Process -FilePath $wt.Source -ArgumentList "-w new powershell.exe $argLine"
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine
    }
    exit 0
}

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

function Test-Rootless {
    if ($null -eq $script:Rootless) {
        $script:Rootless = "$(podman info --format '{{.Host.Security.Rootless}}')".Trim()
    }
    return ($script:Rootless -eq 'true')
}

# En mode rootful, root dans la sandbox (sudo sans mot de passe) est root de la
# machine Podman, qui a accès à vos fichiers Windows : la moindre faille du noyau
# ou de l'isolation devient une sortie de la sandbox. Refusé sauf choix explicite.
function Assert-Rootless {
    if ((Test-Rootless) -or $Config.AllowRootful) { return }
    Exit-WithMessage ("Refusé : la machine Podman est en mode rootful.`n" +
        "Root dans la sandbox serait root de la machine Podman, qui a accès à vos fichiers Windows.`n" +
        "Passez en rootless : podman machine stop ; podman machine set --rootful=false ; podman machine start`n" +
        "(ou, en connaissance de cause : AllowRootful = `$true dans $configFile)")
}

# Vrai si $Child est $Parent ou se trouve dessous
function Test-IsUnder([string]$Child, [string]$Parent) {
    $c = $Child.TrimEnd('\'); $p = $Parent.TrimEnd('\')
    return ($c -ieq $p) -or $c.StartsWith("$p\", [StringComparison]::OrdinalIgnoreCase)
}

# Chemin réel : suit les jonctions et liens symboliques de chaque composant.
# Podman monte la CIBLE d'un lien : sans cela, C:\Projets\x -> C:\Users\moi\AppData
# contournerait les garde-fous. Lève une exception si un composant est illisible.
function Resolve-RealPath([string]$P) {
    $P = [IO.Path]::GetFullPath($P).TrimEnd('\')
    for ($hop = 0; $hop -lt 40; $hop++) {
        if ($P.StartsWith('\\')) { return $P }
        $parts = $P.Split('\')
        $cur = $parts[0] + '\'
        $next = $null
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -eq '') { continue }
            $item = Get-Item -LiteralPath (Join-Path $cur $parts[$i]) -Force -ErrorAction Stop
            if ($item.LinkType -in 'Junction', 'SymbolicLink') {
                $target = "$(@($item.Target)[0])"
                if (-not $target) { throw "Lien illisible : $($item.FullName)" }
                if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path $cur $target }
                $rest = [string]::Join('\', $parts, $i + 1, $parts.Count - $i - 1)
                $next = if ($rest) { Join-Path $target $rest } else { $target }
                break
            }
            $cur = $item.FullName
        }
        if ($null -eq $next) { return $P }
        if ($next.StartsWith('\\')) { return $next }
        $P = [IO.Path]::GetFullPath($next).TrimEnd('\')
    }
    throw "Trop de liens imbriqués : $P"
}

# Renvoie la raison du refus si $P (chemin réel) ne doit pas être monté, sinon $null.
# Un dossier monté est accessible en écriture à l'IA : il ne doit contenir ni
# fichiers exécutés automatiquement par Windows (Démarrage, profils PowerShell,
# scripts d'ai-sandbox...), ni identifiants (~\.ssh, ~\.aws...).
function Get-SandboxPathError([string]$P) {
    if ($P.StartsWith('\\')) {
        return "Chemin réseau ou \\wsl$ non pris en charge : $P`nUtilisez un dossier sur un disque local (C:\, D:\...)."
    }
    if ($P -match '^[A-Za-z]:$') { return "Refusé : '$P\' est un disque entier, trop large pour une sandbox." }
    if ($P -notmatch '^[A-Za-z]:\\') { return "Chemin non pris en charge : $P" }
    try {
        if ([IO.DriveInfo]::new($P.Substring(0, 2)).DriveType -eq 'Network') {
            return "Lecteur réseau non pris en charge : $P`nUtilisez un dossier sur un disque local."
        }
    } catch { }

    # Trop larges : refusés ainsi que leurs dossiers parents (C:\Users...)
    $broad = @($env:USERPROFILE, $env:PUBLIC, $env:OneDrive)
    if ($env:USERPROFILE) { $broad += Split-Path $env:USERPROFILE -Parent }
    foreach ($s in ($broad | Where-Object { $_ })) {
        if (Test-IsUnder $s $P) { return "Refusé : '$P' est trop large pour une sandbox (contient $s)." }
    }

    # Sensibles : refusés, ainsi que leurs parents et leurs sous-dossiers
    $sensitive = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432,
                   $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA, $Root)
    if ($env:LOCALAPPDATA) { $sensitive += Split-Path $env:LOCALAPPDATA -Parent }   # AppData (dont Démarrage)
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if ($docs) { $sensitive += @((Join-Path $docs 'WindowsPowerShell'), (Join-Path $docs 'PowerShell')) }
    if ($env:USERPROFILE) {
        foreach ($d in '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker', '.config',
                       '.claude', '.gemini', '.vscode') {
            $sensitive += Join-Path $env:USERPROFILE $d
        }
    }
    foreach ($s in ($sensitive | Where-Object { $_ })) {
        if ((Test-IsUnder $s $P) -or (Test-IsUnder $P $s)) {
            return "Refusé : '$P' contient ou se trouve dans un dossier sensible ($s)."
        }
    }
    return $null
}

# ------------------------------------------- fichiers interprétés par l'hôte
# Ce que l'IA écrit dans le dossier monté peut être EXÉCUTÉ plus tard par Windows
# ou vos outils, hors sandbox : .git/config (core.fsmonitor, hooksPath...) et hooks
# exécutés par git / l'extension git de VS Code, tâches VS Code, réglages Claude
# Code (hooks, serveurs MCP), raccourcis et desktop.ini (icône sur un partage
# réseau = fuite du hash NTLM)... Ces fichiers sont relevés avant et après la
# session, et toute création ou modification est signalée.

$HostSensitiveSkipDirs = @('node_modules', '.venv', 'venv', '__pycache__', '.tox', '.gradle', '.m2', '.cache')

function Test-HostSensitiveFile([IO.FileInfo]$F) {
    if ($F.Name -in '.git', '.mcp.json', '.envrc', '.npmrc', 'desktop.ini') { return $true }
    if ($F.Extension -in '.lnk', '.url', '.scf', '.library-ms', '.searchconnector-ms', '.code-workspace') { return $true }
    $parent = $F.Directory.Name
    if ($parent -eq '.vscode' -and $F.Name -in 'tasks.json', 'settings.json', 'launch.json') { return $true }
    if ($parent -in '.claude', '.gemini' -and $F.Name -like 'settings*.json') { return $true }
    return $false
}

function Get-FileStamp([IO.FileInfo]$F) { "$($F.LastWriteTimeUtc.Ticks)/$($F.Length)" }

function Add-HostSensitiveFiles([string]$Dir, [int]$Depth, [hashtable]$Found, [hashtable]$Budget) {
    try { $entries = ([IO.DirectoryInfo]$Dir).GetFileSystemInfos() } catch { return }
    foreach ($e in $entries) {
        $Budget.Left--
        if ($Budget.Left -lt 0) { $Found['(analyse partielle : dossier trop volumineux)'] = ''; return }
        $isDir = [bool]($e.Attributes -band [IO.FileAttributes]::Directory)
        if ([bool]($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $e.LinkType -in 'Junction', 'SymbolicLink') {
            $Found[$e.FullName] = "lien -> $(@($e.Target)[0])"   # non suivi
            continue
        }
        if (-not $isDir) {
            if (Test-HostSensitiveFile $e) { $Found[$e.FullName] = Get-FileStamp $e }
            continue
        }
        if ($e.Name -ieq '.git') {
            foreach ($n in 'config', 'config.worktree', 'commondir') {
                $f = [IO.FileInfo](Join-Path $e.FullName $n)
                if ($f.Exists) { $Found[$f.FullName] = Get-FileStamp $f }
            }
            $hooks = [IO.DirectoryInfo](Join-Path $e.FullName 'hooks')
            if ($hooks.Exists) {
                foreach ($h in $hooks.GetFiles()) {
                    if ($h.Extension -ne '.sample') { $Found[$h.FullName] = Get-FileStamp $h }
                }
            }
            continue
        }
        if ($Depth -lt 12 -and $HostSensitiveSkipDirs -notcontains $e.Name) {
            Add-HostSensitiveFiles $e.FullName ($Depth + 1) $Found $Budget
        }
    }
}

function Get-HostSensitiveFiles([string]$Dir) {
    $found = @{}
    Add-HostSensitiveFiles $Dir 0 $found @{ Left = 200000 }
    return $found
}

function Build-Images([string[]]$Names) {
    $imgDir = Join-Path $Root 'images'

    foreach ($u in @($NpmRegistry, $PipIndexUrl)) {
        if ($u -and $u -notmatch '^https://') {
            Write-Host "   Attention : $u n'est pas en HTTPS (paquets modifiables en transit)." -ForegroundColor Yellow
        }
    }

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

    if (Test-Rootless) {
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
    Assert-Rootless
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

        # Garde-fous actuels appliqués aussi aux sandboxes existantes (créées par une
        # version antérieure, ou dont le chemin est devenu un lien entre-temps)
        try { $real = Resolve-RealPath $sbPath } catch { $real = $null }
        if (-not $real) {
            $pathError = 'chemin réel indéterminable'
        } elseif ($real -ine $sbPath.TrimEnd('\')) {
            $pathError = "le chemin est désormais un lien vers $real"
        } else {
            $pathError = Get-SandboxPathError $real
        }
        if ($pathError) {
            $row.Detail = "non recréée, dossier refusé : $pathError (supprimez-la : podman rm -f $name)"
            $failed += $row; continue
        }

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

    # Anciennes images ai-sandbox devenues inutiles (les images clients héritent
    # du label de l'image de base). Les autres images de Podman ne sont pas touchées.
    podman image prune -f --filter label=ai-sandbox.base-image | Out-Null

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

# Garde-fous : on ne monte jamais un périmètre trop large ou sensible. Le contrôle
# porte sur le chemin réel (liens résolus), qui est aussi celui monté.
if (-not $Path.StartsWith('\\') -and $Path -notmatch '^[A-Za-z]:$') {
    try {
        $Path = Resolve-RealPath $Path
    } catch {
        Exit-WithMessage "Impossible de déterminer le chemin réel de $Path : $($_.Exception.Message)"
    }
}
$pathError = Get-SandboxPathError $Path
if ($pathError) { Exit-WithMessage $pathError }

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

Assert-Rootless

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
        # Le contenu des réglages (clés d'API...) passe par l'environnement du processus
        # podman.exe (« -e NOM » sans valeur : valeur reprise de l'environnement) et
        # JAMAIS par sa ligne de commande, lisible par les autres processus et journalisée
        # par l'audit Windows (événement 4688) ou les EDR.
        $env:AI_SANDBOX_SETTINGS_B64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsSrc))
        $syncArgs = @('exec',
            '-e', "AI_SANDBOX_SYNC_B64=$scriptB64",
            '-e', 'AI_SANDBOX_SETTINGS_B64',
            '-e', "AI_SANDBOX_SETTINGS_TARGET=$($cfg.SettingsTarget)")
        if ($cfg.OnboardingFile) { $syncArgs += @('-e', "AI_SANDBOX_ONBOARDING=$($cfg.OnboardingFile)") }
        $syncArgs += @($Name, 'bash', '-c', 'echo $AI_SANDBOX_SYNC_B64 | base64 -d | bash')

        try {
            & podman @syncArgs
            $syncCode = $LASTEXITCODE
        } finally {
            Remove-Item Env:\AI_SANDBOX_SETTINGS_B64 -ErrorAction SilentlyContinue
        }
        if ($syncCode -eq 0) {
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
# uniquement (jamais stockées dans la configuration du conteneur). « -e NOM » sans
# valeur : podman reprend la valeur de son environnement, la clé n'apparaît pas
# sur la ligne de commande.
foreach ($k in $cfg.EnvKeys) {
    if ([Environment]::GetEnvironmentVariable($k)) { $execArgs += @('-e', $k) }
}

$execArgs += $Name
if ($Shell) {
    $execArgs += 'bash'
} else {
    $execArgs += $cfg.Command
    if ($Yolo) { $execArgs += $cfg.YoloArgs }
}

$audit  = ($Config.AuditHostFiles -ne $false)
$before = if ($audit) { Get-HostSensitiveFiles $Path }

& podman @execArgs
$code = $LASTEXITCODE

# Dernière session fermée : la sandbox est arrêtée, pour qu'aucun processus lancé
# par l'IA en arrière-plan ne continue sans surveillance (accès réseau, écriture
# dans le dossier). Elle redémarre en une seconde à la session suivante.
$execCount = "$(podman inspect --format '{{len .ExecIDs}}' $Name 2>$null)".Trim()
if ($execCount -eq '0') { podman stop -t 2 $Name 2>$null | Out-Null }

$pause = ($code -ne 0 -and $code -ne 130)
if ($pause) {
    Write-Host ''
    Write-Host "La session s'est terminée avec le code $code." -ForegroundColor Yellow
}

if ($audit) {
    $after = Get-HostSensitiveFiles $Path
    $changes = @(foreach ($k in ($after.Keys | Sort-Object)) {
        if (-not $before.ContainsKey($k))    { "    + $k" }
        elseif ($before[$k] -ne $after[$k]) { "    ~ $k" }
    })
    if ($changes.Count -gt 0) {
        Write-Host ''
        Write-Host 'Attention : la session a créé (+) ou modifié (~) des fichiers que Windows ou vos outils' -ForegroundColor Yellow
        Write-Host "peuvent exécuter HORS de la sandbox (git, VS Code, Claude Code, Explorateur) :" -ForegroundColor Yellow
        $changes | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        Write-Host ("Relisez-les avant d'ouvrir ce dossier avec git, un IDE ou un agent IA sous Windows " +
                    "(ex. core.fsmonitor, core.hooksPath, hooks, tâches, serveurs MCP).") -ForegroundColor Yellow
        $pause = $true
    }
}

# Garde la fenêtre ouverte pour pouvoir lire les messages
if ($pause) { Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null }
exit $code
