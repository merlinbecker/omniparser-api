# OmniParser API Manual

Diese Anleitung beschreibt die wichtigsten Tests fuer die OmniParser API, lokal und in Azure Container Apps.

## Voraussetzungen

- Docker ist installiert.
- Das Repo liegt lokal vor.
- Fuer Cloud-Tests ist die Azure Container App bereits deployed.
- Fuer API-Requests ist ein API-Key gesetzt.

Empfohlener Azure-Umgebungsvariablenname:

- `OMNIPARSER_API_KEY`

## Lokaler Test

### 1. Image bauen

```bash
./build_and_push_acr.sh \
  --registry cromniparser.azurecr.io \
  --image omniparser-api \
  --tag local-test \
  --username cromniparser \
  --password '<ACR_PASSWORD>'
```

Wenn nur lokal getestet werden soll, kann alternativ direkt mit Docker gebaut werden:

```bash
docker build \
  --platform linux/amd64 \
  --build-arg "BUILD_TIMESTAMP=$(date -u +%s)" \
  -t omniparser-api:local \
  -f Dockerfile .
```

### 2. Container lokal starten

```bash
docker run --rm -p 8000:8000 \
  -e PORT=8000 \
  -e OMNIPARSER_API_KEY=test-key \
  omniparser-api:local
```

Falls das ACR-Image getestet werden soll:

```bash
docker run --rm -p 8000:8000 \
  -e PORT=8000 \
  -e OMNIPARSER_API_KEY=test-key \
  cromniparser.azurecr.io/omniparser-api:<TAG>
```

### 3. Health pruefen

```bash
curl http://127.0.0.1:8000/health
```

Erwartete Antwort:

```json
{"status":"ok"}
```

### 4. End-to-End-Test ausfuehren

```bash
./verify_image.sh \
  --url http://127.0.0.1:8000 \
  --api-key test-key \
  --request-timeout 300
```

Erwartung:

- `/docs` antwortet mit `200`
- `/process_image` antwortet mit `200`
- Die JSON-Antwort enthaelt:
  - `image`
  - `parsed_content_list`
  - `label_coordinates`

## Cloud-Test gegen Azure Container Apps

### 1. Deployment pruefen

Beispiel:

```bash
./verify_image.sh \
  --url https://caomniparser.wonderfulhill-a58a94c1.swedencentral.azurecontainerapps.io \
  --api-key <API_KEY> \
  --request-timeout 300
```

### 2. Direkter API-Test mit curl

```bash
curl -sS -L \
  -H "x-api-key: <API_KEY>" \
  -F "image_file=@examples/screenshot.png" \
  -F "box_threshold=0.05" \
  -F "iou_threshold=0.1" \
  https://caomniparser.wonderfulhill-a58a94c1.swedencentral.azurecontainerapps.io/process_image
```

## Azure Probe-Einstellungen

Fuer diese App sollten die Probes intern auf HTTP laufen, nicht auf HTTPS.

Empfohlene Startup-Probe:

- Typ: `HTTP`
- Pfad: `/health`
- Port: `7860`
- `initialDelaySeconds: 25`
- `periodSeconds: 5`
- `timeoutSeconds: 5`
- `failureThreshold: 12`

Hinweis:

- `HTTPS` ist fuer die interne Probe falsch, weil TLS am Azure-Ingress terminiert wird.
- `TCP` funktioniert nur als grober Check. `HTTP /health` ist besser.

## Typische Fehlerbilder

### Container startet und wird direkt beendet

Moegliche Ursachen:

- falscher `targetPort`
- Probe auf falschem Protokoll
- Probe auf falschem Pfad

Pruefen:

- `targetPort` muss `7860` sein
- Startup-Probe sollte `HTTP /health` auf `7860` sein

### `Missing required environment variable`

Verwende in Azure bevorzugt:

```text
OMNIPARSER_API_KEY
```

Die App akzeptiert zwar auch `OMNIPARSER-API-KEY`, aber der Name mit Unterstrich ist in Plattform-Konfigurationen robuster.

### `/process_image` gibt `401`

Pruefen:

- Header `x-api-key` wird gesetzt
- Wert stimmt mit `OMNIPARSER_API_KEY` ueberein

### `/process_image` gibt `503`

Bedeutung:

- Die App laeuft, aber der API-Key ist serverseitig nicht konfiguriert.

## Nützliche Kurzbefehle

### Health lokal

```bash
curl -sS http://127.0.0.1:8000/health
```

### Docs lokal

```bash
curl -I http://127.0.0.1:8000/docs
```

### Logs eines lokalen Containers

```bash
docker logs <CONTAINER_NAME>
```

### Container stoppen

```bash
docker rm -f <CONTAINER_NAME>
```