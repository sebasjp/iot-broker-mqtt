#!/bin/bash
# Instala Grafana en la EC2 del bróker, con datasource, dashboard y alertas (Telegram) ya configurados.
# Uso (desde el PC):  scp -r grafana broker:~/   y luego   ssh -t broker "bash ~/grafana/instalar.sh"
# Se puede volver a ejecutar para actualizar el dashboard o las reglas: conserva los secretos.
set -euo pipefail
cd "$(dirname "$0")"
PROV=/etc/grafana/provisioning

echo "==> 1/4 Instalando Grafana (repositorio oficial)"
sudo mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq grafana

echo "==> 2/4 Datasource InfluxDB y Telegram (secretos)"
if sudo test -f "$PROV/datasources/influxdb.yaml"; then
  echo "    ya configurados, se conservan"
else
  read -r -p "    IP privada de InfluxDB (10.0.2.x): " INFLUX_IP
  read -r -s -p "    Token de InfluxDB de Grafana (lectura): " INFLUX_TOKEN; echo
  read -r -s -p "    Token del bot de Telegram: " TG_TOKEN; echo
  read -r -p "    Chat ID de Telegram: " TG_CHAT

  sudo tee "$PROV/datasources/influxdb.yaml" > /dev/null <<EOF
apiVersion: 1
datasources:
  - name: InfluxDB
    uid: influxdb-racks
    type: influxdb
    access: proxy
    url: http://${INFLUX_IP}:8086
    isDefault: true
    jsonData:
      version: Flux
      organization: uao
      defaultBucket: racks
    secureJsonData:
      token: ${INFLUX_TOKEN}
EOF

  sudo tee "$PROV/alerting/telegram.yaml" > /dev/null <<EOF
apiVersion: 1
contactPoints:
  - orgId: 1
    name: Telegram
    receivers:
      - uid: telegram-racks
        type: telegram
        settings:
          bottoken: ${TG_TOKEN}
          chatid: "${TG_CHAT}"
# Todas las alertas se envían a Telegram
policies:
  - orgId: 1
    receiver: Telegram
    group_by: ["grafana_folder", "alertname"]
    group_wait: 10s
    group_interval: 1m
    repeat_interval: 1h
EOF
  # Solo root y Grafana pueden leer los secretos
  sudo chown root:grafana "$PROV/datasources/influxdb.yaml" "$PROV/alerting/telegram.yaml"
  sudo chmod 640 "$PROV/datasources/influxdb.yaml" "$PROV/alerting/telegram.yaml"
fi

echo "==> 3/4 Dashboard y reglas de alerta"
sudo cp provisioning/dashboards/racks.yaml "$PROV/dashboards/"
sudo cp provisioning/alerting/reglas.yaml "$PROV/alerting/"
sudo mkdir -p /var/lib/grafana/dashboards
sudo cp dashboards/racks.json /var/lib/grafana/dashboards/
sudo chown -R grafana:grafana /var/lib/grafana/dashboards

echo "==> 4/4 Arrancando Grafana"
sudo systemctl daemon-reload
sudo systemctl enable grafana-server
sudo systemctl restart grafana-server
sleep 5
sudo systemctl status grafana-server --no-pager --lines 5
echo
echo "Grafana: http://<IP_ELASTICA>:3000  (usuario admin / clave admin, pide cambiarla al entrar)"
