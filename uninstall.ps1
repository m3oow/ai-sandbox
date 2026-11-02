<#
.SYNOPSIS
    Désinstalle ai-sandbox.

.DESCRIPTION
    Par défaut : retire seulement le menu contextuel.
    -Purge : supprime aussi les sandboxes, les images et le dossier d'installation.
             Les volumes ai-sandbox-* laissés par d'anciennes versions sont
             supprimés seulement après confirmation.
    Vos dossiers de travail ne sont jamais touchés.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param([switch]$Purge)

$Dest = Join-Path $env:LOCALAPPDATA 'ai-sandbox'

foreach ($b in @(
    'HKCU:\Software\Classes\Directory\shell\AISandbox',
    'HKCU:\Software\Classes\Directory\Background\shell\AISandbox'
)) {
    if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Recurse -Force }
}
Write-Host 'Menu contextuel retiré.' -ForegroundColor Green

if ($Purge -and (Get-Command podman -ErrorAction SilentlyContinue)) {
    $ids = podman ps -aq --filter label=ai-sandbox.path
    foreach ($id in $ids) { podman rm -f $id | Out-Null }
    Write-Host "$(@($ids).Count) sandbox(es) supprimée(s)."

    $images = podman images --format '{{.Repository}}:{{.Tag}}' |
              Where-Object { $_ -like 'localhost/ai-sandbox-*' }
    # images clients d'abord, base ensuite
    foreach ($img in ($images | Sort-Object { $_ -like '*ai-sandbox-base*' })) {
        podman rmi -f $img | Out-Null
    }
    Write-Host 'Images supprimées.'

    $vols = podman volume ls --format '{{.Name}}' | Where-Object { $_ -like 'ai-sandbox-*' }
    if ($vols) {
        $answer = Read-Host "Supprimer aussi les volumes d'anciennes versions ($($vols -join ', ')) ? [o/N]"
        if ($answer -match '^[oOyY]') {
            foreach ($v in $vols) { podman volume rm -f $v | Out-Null }
            Write-Host 'Volumes supprimés.'
        }
    }

    if (Test-Path -LiteralPath $Dest) {
        Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Dossier $Dest supprimé."
    }
}

Read-Host 'Appuyez sur Entrée pour fermer' | Out-Null
