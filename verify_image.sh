#!/usr/bin/env bash

set -euo pipefail

API_BASE_URL="${API_BASE_URL:-}"
API_KEY="${API_KEY:-}"
IMAGE_FILE="${IMAGE_FILE:-$(dirname "$0")/examples/screenshot.png}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
BOX_THRESHOLD="${BOX_THRESHOLD:-0.05}"
IOU_THRESHOLD="${IOU_THRESHOLD:-0.1}"

usage() {
  cat <<EOF
Verifiziert eine laufende OmniParser-API per End-to-End-Test.

Verwendung:
  ./verify_image.sh --url <https://deine-container-app> [optionen]

Optionen:
  --url <basis-url>        Basis-URL der Container App, z. B. https://app-name.region.azurecontainerapps.io
  --api-key <wert>         API-Key fuer Header x-api-key
  --file <pfad>            Screenshot fuer den Upload-Test
  --request-timeout <sek>  Maximale Wartezeit fuer den Upload-Request (Standard: 180)
  --box-threshold <wert>   box_threshold fuer den API-Aufruf (Standard: 0.05)
  --iou-threshold <wert>   iou_threshold fuer den API-Aufruf (Standard: 0.1)
  --help                   Hilfe anzeigen

Alternativ koennen Umgebungsvariablen gesetzt werden:
  API_BASE_URL, API_KEY, IMAGE_FILE, REQUEST_TIMEOUT, BOX_THRESHOLD, IOU_THRESHOLD
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      API_BASE_URL="$2"
      shift 2
      ;;
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --file)
      IMAGE_FILE="$2"
      shift 2
      ;;
    --request-timeout)
      REQUEST_TIMEOUT="$2"
      shift 2
      ;;
    --box-threshold)
      BOX_THRESHOLD="$2"
      shift 2
      ;;
    --iou-threshold)
      IOU_THRESHOLD="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unbekannter Parameter: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$API_BASE_URL" ]]; then
  echo "FEHLER: --url ist erforderlich." >&2
  usage
  exit 1
fi

if [[ ! -f "$IMAGE_FILE" ]]; then
  echo "FEHLER: Screenshot nicht gefunden: $IMAGE_FILE" >&2
  exit 1
fi

for required_cmd in curl python3; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "FEHLER: Benoetigtes Kommando fehlt: $required_cmd" >&2
    exit 1
  fi
done

API_BASE_URL="${API_BASE_URL%/}"
DOCS_URL="${API_BASE_URL}/docs"
PROCESS_URL="${API_BASE_URL}/process_image"

CURL_AUTH_ARGS=()
if [[ -n "$API_KEY" ]]; then
  CURL_AUTH_ARGS=(-H "x-api-key: ${API_KEY}")
fi

TMP_DIR="$(mktemp -d)"
RESPONSE_BODY="$TMP_DIR/response.json"
DOCS_BODY="$TMP_DIR/docs.html"

cleanup() {
  local exit_code=$?
  rm -rf "$TMP_DIR"
  exit "$exit_code"
}

trap cleanup EXIT

echo ">>> Pruefe Container-App-API: $API_BASE_URL"
echo ">>> Testdatei: $IMAGE_FILE"

docs_code="$(curl -sS -L -o "$DOCS_BODY" -w '%{http_code}' --max-time 30 "$DOCS_URL" || true)"
if [[ "$docs_code" != "200" ]]; then
  echo "FEHLER: Die API-Dokumentation ist nicht erreichbar, HTTP-Status: $docs_code" >&2
  echo "Hinweis: Pruefe die Container-App-URL, Ingress-Einstellungen, den Target-Port 7860 und ob die Revision healthy ist." >&2
  exit 1
fi

echo ">>> API ist erreichbar. Sende Test-Screenshot ..."
http_code="$(curl -sS -L \
  -o "$RESPONSE_BODY" \
  -w '%{http_code}' \
  --max-time "$REQUEST_TIMEOUT" \
  "${CURL_AUTH_ARGS[@]}" \
  -F "image_file=@${IMAGE_FILE}" \
  -F "box_threshold=${BOX_THRESHOLD}" \
  -F "iou_threshold=${IOU_THRESHOLD}" \
  "$PROCESS_URL" || true)"

if [[ "$http_code" != "200" ]]; then
  echo "FEHLER: API-Aufruf fehlgeschlagen, HTTP-Status: $http_code" >&2
  if [[ -s "$RESPONSE_BODY" ]]; then
    echo "--- Antwort ---" >&2
    cat "$RESPONSE_BODY" >&2
    echo >&2
    echo "---------------" >&2
  fi
  if [[ "$http_code" == "400" ]]; then
    echo "Hinweis: HTTP 400 deutet meist auf ein ungueltiges Bildformat oder einen fehlerhaften Multipart-Upload hin." >&2
  elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "Hinweis: Auth fehlgeschlagen oder Zugriff gesperrt. Pruefe den API-Key (Header x-api-key) und Netzwerkregeln." >&2
  elif [[ "$http_code" == "404" ]]; then
    echo "Hinweis: Der Pfad /process_image ist nicht erreichbar. Pruefe, ob die richtige Revision mit der FastAPI-App laeuft." >&2
  elif [[ "$http_code" == "500" ]]; then
    echo "Hinweis: HTTP 500 deutet auf einen Laufzeitfehler im Container hin, z. B. Modellladefehler, fehlende GPU, OOM oder OCR-Abhaengigkeiten." >&2
  elif [[ "$http_code" == "000" ]]; then
    echo "Hinweis: Kein HTTP-Handshake. Pruefe DNS, TLS-Zertifikat, Public Ingress und ob die Container App bereits gestartet ist." >&2
  fi
  exit 1
fi

python3 - "$RESPONSE_BODY" <<'PY'
import base64
import json
import sys
from pathlib import Path

response_path = Path(sys.argv[1])
payload = json.loads(response_path.read_text())

required_fields = ["image", "parsed_content_list", "label_coordinates"]
missing = [field for field in required_fields if field not in payload]
if missing:
    raise SystemExit(f"FEHLER: Antwort enthaelt nicht alle Pflichtfelder: {', '.join(missing)}")

if not payload["image"]:
    raise SystemExit("FEHLER: Feld 'image' ist leer.")

try:
    decoded = base64.b64decode(payload["image"], validate=True)
except Exception as exc:
    raise SystemExit(f"FEHLER: Feld 'image' ist kein gueltiges Base64: {exc}") from exc

if len(decoded) < 100:
    raise SystemExit("FEHLER: Dekodiertes Bild ist unplausibel klein.")

parsed_len = len(str(payload["parsed_content_list"]).strip())
coord_len = len(str(payload["label_coordinates"]).strip())

if parsed_len == 0:
    raise SystemExit("FEHLER: parsed_content_list ist leer.")

print("Antwort validiert.")
print(f"  Bildbytes: {len(decoded)}")
print(f"  parsed_content_list Zeichen: {parsed_len}")
print(f"  label_coordinates Zeichen: {coord_len}")
PY

echo ">>> Verifikation erfolgreich. Die Container App verarbeitet den Screenshot und liefert eine gueltige Antwort."
echo ">>> Gepruefter Endpunkt: $PROCESS_URL"