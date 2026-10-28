#!/bin/bash
# Instala el ingestor como servicio en la EC2 del bróker.
# Uso (desde el PC):  scp -r ingestor broker:~/   y luego   ssh -t broker "bash ~/ingestor/instalar.sh"
# Se puede volver a ejecutar para actualizar el código: conserva el .env existente.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/4 Instalando Python venv"
sudo apt-get update -qq
sudo apt-get install -y -qq python3-venv

echo "==> 2/4 Creando entorno virtual e instalando librerías"
python3 -m venv venv
venv/bin/pip install -q -r requirements.txt

echo "==> 3/4 Configuración (.env)"
if [ -f .env ]; then
  echo "    .env ya existe, se conserva"
else
  read -r -p "    IP privada de InfluxDB (10.0.2.x): " INFLUX_IP
  read -r -s -p "    Contraseña MQTT del usuario 'ingestor': " MQTT_PASS; echo
  read -r -s -p "    Token de InfluxDB del ingestor (escritura): " INFLUX_TOKEN; echo
  cat > .env <<EOF
MQTT_HOST=localhost
MQTT_PORT=1883
MQTT_USER=ingestor
MQTT_PASS=${MQTT_PASS}
INFLUX_URL=http://${INFLUX_IP}:8086
INFLUX_TOKEN=${INFLUX_TOKEN}
INFLUX_ORG=uao
INFLUX_BUCKET=racks
CSV_PATH=/var/lib/ingestor/datos.csv
EOF
  chmod 600 .env  # solo el usuario ubuntu puede leer los secretos
  echo "    .env creado"
fi

echo "==> 4/4 Instalando y arrancando el servicio"
sudo cp ingestor.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ingestor
sudo systemctl restart ingestor
sleep 3
sudo systemctl status ingestor --no-pager --lines 10
