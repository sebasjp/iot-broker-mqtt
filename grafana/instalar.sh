#!/bin/bash
# Instala/actualiza Grafana en la EC2 del bróker con datasource, dashboard y alertas
# de Telegram ya provisionados. Es idempotente: se puede volver a ejecutar.
#
# Uso (desde el PC):
#   scp -r grafana ubuntu@<IP>:/home/ubuntu/
#   ssh -t ubuntu@<IP> "bash /home/ubuntu/grafana/instalar.sh"
#
# Requisitos: /home/ubuntu/.env.grafana con las 7 variables (ver .env.grafana.example).
# Los secretos NO viven en este repo: este script solo los lee del entorno.
set -euo pipefail
cd "$(dirname "$0")"

PROV=/etc/grafana/provisioning
ENV_FILE=/home/ubuntu/.env.grafana
# IP elástica del bróker: es la que se abre en el navegador y la que usan los enlaces
# de las alertas (root_url). Si cambia, se actualiza aquí.
HOST_IP=32.199.8.57

echo "==> 1/6 Comprobando $ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: falta $ENV_FILE. Copia grafana/.env.grafana.example y rellénalo." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for v in INFLUX_URL INFLUX_ORG INFLUX_BUCKET INFLUX_TOKEN TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID GF_SECURITY_ADMIN_PASSWORD; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: la variable $v está vacía en $ENV_FILE" >&2
    exit 1
  fi
done
echo "    variables OK"

echo "==> 2/6 Swap de 1 GB (evita OOM con Grafana en 1 GB de RAM)"
if ! sudo swapon --show=NAME --noheadings | grep -q '^/swapfile$'; then
  if ! sudo fallocate -l 1G /swapfile 2>/dev/null; then
    sudo dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  fi
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  echo "    swap creada"
else
  echo "    swap ya activa"
fi
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-grafana-swap.conf >/dev/null
sudo sysctl --system >/dev/null
free -h | awk 'NR==1 || /Swap/'

echo "==> 3/6 Instalando Grafana"
sudo apt-get install -y -qq curl ca-certificates gpg wget >/dev/null
sudo install -d -m 0755 /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
sudo apt-get update -qq || echo "    aviso: apt-get update con errores (repo Grafana); se intentará el .deb oficial"
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana; then
  echo "    repositorio no disponible para esta versión; usando .deb oficial"
  wget -q -O /tmp/grafana_latest.deb https://dl.grafana.com/oss/release/grafana_latest_amd64.deb
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/grafana_latest.deb
fi

echo "==> 4/6 Provisioning (datasource, dashboard, alertas)"
sudo mkdir -p "$PROV/datasources" "$PROV/dashboards" "$PROV/alerting" /var/lib/grafana/dashboards
sudo cp provisioning/datasources/influxdb.yaml "$PROV/datasources/influxdb.yaml"
sudo cp provisioning/dashboards/racks.yaml "$PROV/dashboards/racks.yaml"
sudo cp provisioning/alerting/telegram.yaml "$PROV/alerting/telegram.yaml"
sudo cp provisioning/alerting/reglas.yaml "$PROV/alerting/reglas.yaml"
sudo cp provisioning/alerting/plantillas.yaml "$PROV/alerting/plantillas.yaml"
sudo cp dashboards/racks.json /var/lib/grafana/dashboards/racks.json
sudo chown -R grafana:grafana /var/lib/grafana/dashboards
# Los YAML no contienen secretos (se leen del entorno), pero se restringen igualmente.
sudo chown root:grafana "$PROV/datasources/influxdb.yaml" "$PROV/alerting/telegram.yaml" \
  "$PROV/alerting/reglas.yaml" "$PROV/alerting/plantillas.yaml"
sudo chmod 640 "$PROV/datasources/influxdb.yaml" "$PROV/alerting/telegram.yaml" \
  "$PROV/alerting/reglas.yaml" "$PROV/alerting/plantillas.yaml"

# Grafana (usuario grafana) lee los secretos de este EnvironmentFile.
sudo chown ubuntu:grafana "$ENV_FILE"
sudo chmod 640 "$ENV_FILE"
sudo mkdir -p /etc/systemd/system/grafana-server.service.d
sudo tee /etc/systemd/system/grafana-server.service.d/10-env-file.conf >/dev/null <<'EOF'
[Service]
EnvironmentFile=/home/ubuntu/.env.grafana
EOF

# root_url: sin esto, los enlaces de las alertas (GeneratorURL) apuntan a localhost:3000.
sudo tee /etc/systemd/system/grafana-server.service.d/20-root-url.conf >/dev/null <<EOF
[Service]
Environment=GF_SERVER_ROOT_URL=http://${HOST_IP}:3000
EOF

echo "==> 5/6 Primera arrancada y contraseña de admin"
sudo systemctl daemon-reload
sudo systemctl enable grafana-server >/dev/null
sudo systemctl restart grafana-server
for _ in $(seq 1 30); do
  curl -fsS http://localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 2
done

GRAFANA_CLI=""
if command -v grafana >/dev/null 2>&1; then
  GRAFANA_CLI="grafana cli"
elif command -v grafana-cli >/dev/null 2>&1; then
  GRAFANA_CLI="grafana-cli"
fi
if [[ -n "$GRAFANA_CLI" ]]; then
  sudo $GRAFANA_CLI --homepath /usr/share/grafana admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD" >/dev/null
  echo "    contraseña de admin aplicada"
else
  echo "    aviso: no se encontró grafana-cli; cambia la contraseña desde la web"
fi
sudo systemctl restart grafana-server
for _ in $(seq 1 30); do
  curl -fsS http://localhost:3000/api/health >/dev/null 2>&1 && break
  sleep 2
done

echo "==> 6/6 Verificación"
AUTH="admin:${GF_SECURITY_ADMIN_PASSWORD}"
curl -fsS http://localhost:3000/api/health; echo
echo -n "    datasource: "
curl -fsS -u "$AUTH" http://localhost:3000/api/datasources/uid/influxdb-racks/health || true
echo
echo -n "    alertas provisionadas: "
curl -fsS -u "$AUTH" http://localhost:3000/api/v1/provisioning/alert-rules 2>/dev/null | grep -o '"title"' | wc -l
echo -n "    puntos de contacto: "
curl -fsS -u "$AUTH" http://localhost:3000/api/v1/provisioning/contact-points 2>/dev/null | grep -o '"name"' | wc -l

echo
echo "Grafana: http://${HOST_IP}:3000  (usuario admin / clave definida en $ENV_FILE)"
echo "Si no abre, revisa que el Security Group permita TCP 3000 desde tu IP."
