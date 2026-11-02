# Copie un fichier de reglages de l'hote dans la sandbox (remplace l'existant).
# Execute dans le conteneur par ai-sandbox.ps1 : podman exec -i ... bash -s
#   AI_SANDBOX_SETTINGS_B64     contenu du fichier hote, en base64
#   AI_SANDBOX_SETTINGS_TARGET  chemin du fichier de reglages dans le conteneur
#   AI_SANDBOX_ONBOARDING       (facultatif) fichier d'etat cree pour sauter l'ecran d'accueil
set -eu
target="$AI_SANDBOX_SETTINGS_TARGET"
tmp="$target.tmp"
mkdir -p "$(dirname "$target")"

printf '%s' "$AI_SANDBOX_SETTINGS_B64" | base64 -d > "$tmp"
sed -i '1s/^\xEF\xBB\xBF//' "$tmp"     # BOM UTF-8 eventuel (editeurs Windows)
chmod 600 "$tmp"

# JSON invalide : on garde le fichier precedent
if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$tmp" 2>/dev/null; then
  rm -f "$tmp"
  echo "Reglages ignores : JSON invalide" >&2
  exit 2
fi
mv -f "$tmp" "$target"

if [ -n "${AI_SANDBOX_ONBOARDING:-}" ] && [ ! -e "$AI_SANDBOX_ONBOARDING" ]; then
  printf '{\n  "hasCompletedOnboarding": true\n}\n' > "$AI_SANDBOX_ONBOARDING"
  chmod 600 "$AI_SANDBOX_ONBOARDING"
fi
exit 0
