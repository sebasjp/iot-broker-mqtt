"""
Ingestor MQTT -> InfluxDB + CSV.

Se suscribe a los topics <rack>/temperatura y <rack>/humedad en Mosquitto
y guarda cada lectura en InfluxDB y en un archivo CSV, con la misma hora (UTC).

Ejemplo: el mensaje "24.5" en el topic "rack1/temperatura" se guarda como
  InfluxDB: ambiente,rack=rack1 temperatura=24.5
  CSV:      2026-10-26T21:30:00.123+00:00,rack1,temperatura,24.5
"""

import csv
import logging
import math
import os
from datetime import datetime, timezone
from pathlib import Path

import paho.mqtt.client as mqtt
from dotenv import load_dotenv
from influxdb_client import InfluxDBClient, Point, WritePrecision
from influxdb_client.client.write_api import SYNCHRONOUS

# --- Configuración: se lee del archivo .env (ver .env.example) -------------
load_dotenv(Path(__file__).with_name(".env"))

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_USER = os.environ["MQTT_USER"]
MQTT_PASS = os.environ["MQTT_PASS"]
# "+" = cualquier valor en ese nivel: rack1, rack2, ...
TOPICS = ["+/temperatura", "+/humedad"]

INFLUX_URL = os.environ["INFLUX_URL"]
INFLUX_TOKEN = os.environ["INFLUX_TOKEN"]
INFLUX_ORG = os.getenv("INFLUX_ORG", "uao")
INFLUX_BUCKET = os.getenv("INFLUX_BUCKET", "racks")
MEASUREMENT = "ambiente"

CSV_PATH = Path(os.getenv("CSV_PATH", "/var/lib/ingestor/datos.csv"))
CSV_HEADER = ["timestamp_utc", "rack", "variable", "valor"]

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("ingestor")

influx = InfluxDBClient(url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG)
write_api = influx.write_api(write_options=SYNCHRONOUS)


# --- Guardado ---------------------------------------------------------------
def guardar_csv(ahora, rack, variable, valor):
    nuevo = not CSV_PATH.exists() or CSV_PATH.stat().st_size == 0
    with CSV_PATH.open("a", newline="") as f:
        writer = csv.writer(f)
        if nuevo:
            writer.writerow(CSV_HEADER)
        writer.writerow([ahora.isoformat(timespec="milliseconds"), rack, variable, valor])


def guardar_influx(ahora, rack, variable, valor):
    punto = (
        Point(MEASUREMENT)
        .tag("rack", rack)
        .field(variable, valor)
        .time(ahora, WritePrecision.MS)
    )
    write_api.write(bucket=INFLUX_BUCKET, record=punto)


# --- Callbacks MQTT ---------------------------------------------------------
def al_conectar(client, userdata, flags, reason_code, properties):
    if reason_code.is_failure:
        log.error("No se pudo conectar a Mosquitto: %s", reason_code)
        return
    log.info("Conectado a Mosquitto en %s:%s", MQTT_HOST, MQTT_PORT)
    # Suscribirse aquí hace que, si se reconecta, se vuelva a suscribir solo
    for topic in TOPICS:
        client.subscribe(topic)
        log.info("Suscrito a %s", topic)


def al_desconectar(client, userdata, flags, reason_code, properties):
    log.warning("Desconectado de Mosquitto (%s). Reintentando...", reason_code)


def al_recibir(client, userdata, msg):
    ahora = datetime.now(timezone.utc)  # una sola hora para InfluxDB y CSV
    rack, variable = msg.topic.split("/")

    try:
        valor = float(msg.payload.decode())
    except (UnicodeDecodeError, ValueError):
        log.warning("Valor no numérico en %s: %r", msg.topic, msg.payload)
        return
    if not math.isfinite(valor):  # descarta nan / inf (lectura fallida del sensor)
        log.warning("Valor inválido en %s: %s", msg.topic, valor)
        return

    # Primero el CSV: si InfluxDB falla, el dato queda guardado igual
    guardar_csv(ahora, rack, variable, valor)
    try:
        guardar_influx(ahora, rack, variable, valor)
    except Exception as e:
        log.error("Error escribiendo en InfluxDB (guardado solo en CSV): %s", e)
        return
    log.info("%s %s=%s", rack, variable, valor)


# --- Programa principal -----------------------------------------------------
def main():
    CSV_PATH.parent.mkdir(parents=True, exist_ok=True)

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="ingestor")
    client.username_pw_set(MQTT_USER, MQTT_PASS)
    client.on_connect = al_conectar
    client.on_disconnect = al_desconectar
    client.on_message = al_recibir
    client.reconnect_delay_set(min_delay=1, max_delay=30)

    client.connect(MQTT_HOST, MQTT_PORT)
    client.loop_forever()  # escucha para siempre y se reconecta solo


if __name__ == "__main__":
    main()
