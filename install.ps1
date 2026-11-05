<#
.SYNOPSIS
    Installe ai-sandbox : copie les fichiers, construit les images Podman et
    ajoute le menu contextuel "Lancer IA sandboxée" dans l'Explorateur.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -NoBuild
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -BaseImage registry.mon-entreprise.fr/ubi10/ubi:latest
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -NpmRegistry https://nexus.mon-entreprise.fr/repository/npm-proxy/
#>
[CmdletBinding()]
param(
    [switch]$NoBuild,     # ne reconstruit pas les images (menu seulement)
    [string]$BaseImage,   # image de base à utiliser (enregistrée dans config.psd1)
    [string]$NpmRegistry  # registre npm à utiliser ('' = public) (enregistré dans config.psd1)
)

$Src  = $PSScriptRoot
$Dest = Join-Path $env:LOCALAPPDATA 'ai-sandbox'

function Fail([string]$Message) {
    Write-Host $Message -ForegroundColor Red
    Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null
    exit 1
}

# ------------------------------------------------------------ vérifications

$podman = Get-Command podman -ErrorAction SilentlyContinue
if (-not $podman) { Fail 'podman.exe introuvable. Installez Podman Desktop puis relancez.' }

podman info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Démarrage de la machine Podman...' -ForegroundColor DarkGray
    podman machine start
    podman info *> $null
    if ($LASTEXITCODE -ne 0) { Fail 'La machine Podman ne répond pas. Vérifiez-la dans Podman Desktop.' }
}

$rootless = "$(podman info --format '{{.Host.Security.Rootless}}')".Trim()
if ($rootless -eq 'true') {
    Write-Host 'Podman rootless détecté : OK.' -ForegroundColor Green
} else {
    Write-Host 'Attention : la machine Podman est en mode rootful. La sandbox fonctionnera,' -ForegroundColor Yellow
    Write-Host "mais le mode rootless est plus sûr : podman machine stop ; podman machine set --rootful=false ; podman machine start" -ForegroundColor Yellow
}

# ------------------------------------------------------------ copie

if ((Resolve-Path $Src).ProviderPath.TrimEnd('\') -ine $Dest.TrimEnd('\')) {
    Write-Host "Copie vers $Dest ..."
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    # Une configuration déjà installée (ex. image interne) est conservée
    $destConfig = Join-Path $Dest 'config.psd1'
    $savedConfig = if (Test-Path -LiteralPath $destConfig) { Get-Content -LiteralPath $destConfig -Raw -Encoding UTF8 }
    # Le dossier .git (historique du dépôt) n'a rien à faire dans le dossier d'installation
    Get-ChildItem -LiteralPath $Src -Force |
        Where-Object { $_.Name -ne '.git' } |
        Copy-Item -Destination $Dest -Recurse -Force
    # Installation antérieure qui avait recopié .git : nettoyage
    $staleGit = Join-Path $Dest '.git'
    if (Test-Path -LiteralPath $staleGit) {
        Remove-Item -LiteralPath $staleGit -Recurse -Force
        Write-Host "Ancien dossier .git retiré de $Dest" -ForegroundColor DarkGray
    }
    if ($savedConfig) {
        [IO.File]::WriteAllText($destConfig, $savedConfig, (New-Object Text.UTF8Encoding $true))
        Write-Host "Configuration existante conservée : $destConfig" -ForegroundColor DarkGray
    }
}
Get-ChildItem -Path $Dest -Recurse -File | Unblock-File

# -BaseImage / -NpmRegistry : enregistrés dans la configuration installée
$configPath = Join-Path $Dest 'config.psd1'

function Set-ConfigValue([string]$Key, [string]$Value) {
    $content = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $escaped = $Value.Trim().Replace("'", "''")
    $pattern = "(?m)^([ \t]*)$Key[ \t]*=[^\r\n]*"
    if ([regex]::IsMatch($content, $pattern)) {
        $content = [regex]::Replace($content, $pattern, "`${1}$Key = '$escaped'")
    } else {
        # clé absente (ancienne configuration) : ajoutée avant l'accolade finale
        $idx = $content.LastIndexOf('}')
        $content = $content.Substring(0, $idx) + "    $Key = '$escaped'`r`n" + $content.Substring($idx)
    }
    [IO.File]::WriteAllText($configPath, $content, (New-Object Text.UTF8Encoding $true))
}

if ($PSBoundParameters.ContainsKey('BaseImage'))   { Set-ConfigValue 'BaseImage'   $BaseImage }
if ($PSBoundParameters.ContainsKey('NpmRegistry')) { Set-ConfigValue 'NpmRegistry' $NpmRegistry }

$cfg = Import-PowerShellDataFile $configPath
Write-Host "Image de base : $($cfg.BaseImage)" -ForegroundColor Cyan
Write-Host "Registre npm  : $(if ($cfg.NpmRegistry) { $cfg.NpmRegistry } else { 'public (registry.npmjs.org)' })" -ForegroundColor Cyan

$Clients = Import-PowerShellDataFile (Join-Path $Dest 'clients.psd1')
$ps1     = Join-Path $Dest 'ai-sandbox.ps1'

# ------------------------------------------------------------ images

if (-not $NoBuild) {
    Write-Host "`nConstruction des images (plusieurs minutes la première fois)..." -ForegroundColor Cyan
    & $ps1 -Rebuild
}

# ------------------------------------------------------------ menu contextuel

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue

function New-MenuCommand([string]$ClientName, [string]$Mode) {
    $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ps1`" -Client $ClientName"
    if ($Mode -eq 'shell') { $cmd += ' -Shell' }
    $cmd += ' -Path "%V"'
    if ($wt) { return "wt.exe -w new $cmd" }
    return $cmd
}

$icon  = "$($podman.Source),0"
$bases = @(
    'HKCU:\Software\Classes\Directory\shell\AISandbox',            # clic droit sur un dossier
    'HKCU:\Software\Classes\Directory\Background\shell\AISandbox'  # clic droit dans un dossier
)

foreach ($b in $bases) {
    if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Recurse -Force }
    New-Item -Path $b -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name 'MUIVerb'     -Value 'Lancer IA sandboxée' -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name 'SubCommands' -Value ''                   -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $b -Name 'Icon'        -Value $icon                -PropertyType String -Force | Out-Null

    $i = 0
    foreach ($name in ($Clients.Keys | Sort-Object)) {
        $label = $Clients[$name].Label
        # Deux entrées par client : session normale, shell dans la sandbox
        foreach ($mode in @('', 'shell')) {
            $i++
            $suffix = if ($mode) { "-$mode" } else { '' }
            $key    = "$b\shell\{0:D2}-{1}{2}" -f $i, $name, $suffix
            $text   = switch ($mode) {
                'shell' { "$label (shell)" }
                default { $label }
            }

            New-Item -Path "$key\command" -Force | Out-Null
            New-ItemProperty -LiteralPath $key -Name 'MUIVerb' -Value $text -PropertyType String -Force | Out-Null
            if ($i -gt 1 -and -not $mode) {
                # séparateur avant chaque nouveau client
                New-ItemProperty -LiteralPath $key -Name 'CommandFlags' -Value 0x20 -PropertyType DWord -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath "$key\command" -Name '(default)' -Value (New-MenuCommand $name $mode)
        }
    }
}

Write-Host ''
Write-Host 'Installation terminée.' -ForegroundColor Green
Write-Host "  Fichiers : $Dest"
Write-Host "  Menu     : clic droit sur un dossier > Lancer IA sandboxée"
Write-Host "             (sous Windows 11 : 'Afficher plus d'options' ou Maj + clic droit)"
Write-Host "  Terminal : $(if ($wt) { 'Windows Terminal' } else { 'console PowerShell (Windows Terminal non trouvé)' })"
Write-Host ''
Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null
