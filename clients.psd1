# Définition des clients IA disponibles.
# Pour en ajouter un : une entrée ici + un dossier images/<nom>/Containerfile,
# puis relancer install.ps1 (reconstruit les images et le menu).
#   SettingsTarget : où recopier le fichier de réglages Windows (config.psd1 > Settings)
#   OnboardingFile : fichier d'état créé pour sauter l'écran d'accueil (facultatif)
@{
    claude = @{
        Label          = 'Claude'
        Command        = @('claude')
        YoloArgs       = @('--dangerously-skip-permissions')
        EnvKeys        = @('ANTHROPIC_API_KEY')
        SettingsTarget = '/home/dev/.claude-config/settings.json'
        OnboardingFile = '/home/dev/.claude-config/.claude.json'
    }
    gemini = @{
        Label          = 'Gemini'
        Command        = @('gemini')
        YoloArgs       = @('--yolo')
        EnvKeys        = @('GEMINI_API_KEY', 'GOOGLE_API_KEY')
        SettingsTarget = '/home/dev/.gemini/settings.json'
    }
}
