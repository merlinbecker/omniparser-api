#!/usr/bin/env bash
# ============================================================
# build_and_push_acr.sh
#
# Baut das OmniParser-API Docker-Image (inkl. Modellgewichte)
# und pusht es in eine Azure Container Registry (ACR).
#
# Verwendung:
#   chmod +x build_and_push_acr.sh
#   ./build_and_push_acr.sh \
#       --registry  <meinregistry>.azurecr.io \
#       --image     omniparser-api \
#       --tag       latest \
#       --username  <ACR-Benutzername> \
#       --password  <ACR-Passwort>
#
# Alternativ können alle Werte als Umgebungsvariablen gesetzt werden:
#   ACR_REGISTRY, ACR_IMAGE, ACR_TAG, ACR_USERNAME, ACR_PASSWORD
# ============================================================

set -euo pipefail

# ---------- Standardwerte (können durch Flags überschrieben werden) ----------
ACR_REGISTRY="${ACR_REGISTRY:-}"
ACR_IMAGE="${ACR_IMAGE:-omniparser-api}"
ACR_TAG="${ACR_TAG:-latest}"
ACR_USERNAME="${ACR_USERNAME:-}"
ACR_PASSWORD="${ACR_PASSWORD:-}"

# ---------- Argumente parsen ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)  ACR_REGISTRY="$2";  shift 2 ;;
    --image)     ACR_IMAGE="$2";     shift 2 ;;
    --tag)       ACR_TAG="$2";       shift 2 ;;
    --username)  ACR_USERNAME="$2";  shift 2 ;;
    --password)  ACR_PASSWORD="$2";  shift 2 ;;
    *)
      echo "Unbekannter Parameter: $1"
      echo "Verwende: $0 --registry <host> --image <name> --tag <tag> --username <user> --password <pass>"
      exit 1
      ;;
  esac
done

# ---------- Pflichtfelder prüfen ----------
if [[ -z "$ACR_REGISTRY" ]]; then
  echo "FEHLER: --registry ist erforderlich (z. B. meinregistry.azurecr.io)"
  exit 1
fi
if [[ -z "$ACR_USERNAME" ]]; then
  echo "FEHLER: --username ist erforderlich (ACR-Benutzername oder Service-Principal-ID)"
  exit 1
fi
if [[ -z "$ACR_PASSWORD" ]]; then
  echo "FEHLER: --password ist erforderlich (ACR-Passwort oder Service-Principal-Secret)"
  exit 1
fi

FULL_IMAGE="${ACR_REGISTRY}/${ACR_IMAGE}:${ACR_TAG}"

echo "============================================================"
echo "  Registry : $ACR_REGISTRY"
echo "  Image    : $FULL_IMAGE"
echo "============================================================"

# ---------- Docker-Image bauen ----------
echo ""
echo ">>> Docker-Image wird gebaut ..."
echo "    (Es wird als linux/amd64 ohne OCI-Attestation gebaut, damit"
echo "     Azure Container Apps das Tag korrekt als Linux-Image erkennt.)"
echo ""

docker build \
  --progress=plain \
  --platform linux/amd64 \
  --provenance=false \
  --build-arg "BUILD_TIMESTAMP=$(date -u +%s)" \
  -t "$FULL_IMAGE" \
  -f "$(dirname "$0")/Dockerfile" \
  "$(dirname "$0")"

echo ""
echo ">>> Build erfolgreich: $FULL_IMAGE"

# ---------- In ACR einloggen ----------
echo ""
echo ">>> Melde mich bei der Azure Container Registry an ..."
echo "$ACR_PASSWORD" | docker login "$ACR_REGISTRY" \
  --username "$ACR_USERNAME" \
  --password-stdin

echo ">>> Login erfolgreich."

# ---------- Image pushen ----------
echo ""
echo ">>> Pushe Image in die Registry ..."
docker push "$FULL_IMAGE"

IMAGE_DIGEST="$(docker buildx imagetools inspect "$FULL_IMAGE" --format '{{json .Manifest.Digest}}' | tr -d '"')"
FULL_IMAGE_WITH_DIGEST="${ACR_REGISTRY}/${ACR_IMAGE}@${IMAGE_DIGEST}"

echo ""
echo "============================================================"
echo "  Fertig! Image erfolgreich gepusht:"
echo "  $FULL_IMAGE"
echo ""
echo "  Verwende fuer Azure Container Apps am besten diese exakte Referenz:"
echo "  $FULL_IMAGE_WITH_DIGEST"
echo "============================================================"
