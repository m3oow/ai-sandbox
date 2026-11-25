# Configuration d'ai-sandbox.
# Après modification : ai-sandbox.ps1 -Rebuild, puis -Reset sur les sandboxes
# existantes pour qu'elles utilisent la nouvelle image.
@{
    # Image de base des sandboxes (doit être une UBI 10 ou compatible, avec dnf).
    # Par défaut : l'image UBI 10 officielle de Red Hat.
    # Exemple pour un registre d'entreprise :
    #   BaseImage = 'registry.mon-entreprise.fr/mirror/ubi10/ubi:latest'
    # Si le registre exige une authentification : podman login registry.mon-entreprise.fr
    BaseImage = 'registry.access.redhat.com/ubi10/ubi:latest'

    # Registre npm utilisé pour installer les clients IA, puis par l'IA dans la sandbox.
    # Vide = registre public https://registry.npmjs.org/
    # Exemples (Artifactory, Nexus, Verdaccio...) :
    #   NpmRegistry = 'https://artifactory.mon-entreprise.fr/artifactory/api/npm/npm-remote/'
    #   NpmRegistry = 'https://nexus.mon-entreprise.fr/repository/npm-proxy/'
    NpmRegistry = ''

    # Index pip (miroir PyPI) utilisé pour installer les bibliothèques Python de l'image
    # (Office, PDF), puis par l'IA dans la sandbox (pip install).
    # Vide = PyPI public https://pypi.org/simple
    # Exemples :
    #   PipIndexUrl = 'https://artifactory.mon-entreprise.fr/artifactory/api/pypi/pypi-remote/simple'
    #   PipIndexUrl = 'https://nexus.mon-entreprise.fr/repository/pypi-proxy/simple'
    PipIndexUrl = ''

    # Fichiers de réglages Windows copiés dans la sandbox au lancement de chaque session
    # (URL de gateway, clé d'API, modèles...). Ils ne sont JAMAIS inscrits dans les images.
    # Le fichier remplace celui de la sandbox à chaque lancement (une clé changée
    # est prise en compte à la session suivante). Les variables %XXX% sont développées.
    # Mettre '' ou supprimer la ligne pour désactiver.
    # Astuce : pointez vers un fichier dédié (ex. %LOCALAPPDATA%\ai-sandbox\claude-settings.json)
    # si votre settings.json Windows contient des hooks ou chemins propres à Windows.
    Settings = @{
        claude = '%USERPROFILE%\.claude\settings.json'
        # gemini = '%USERPROFILE%\.gemini\settings.json'
    }
}
