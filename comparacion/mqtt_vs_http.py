"""
Comparación MQTT vs HTTP contra la EC2 del bróker. Solo mide: no modifica nada.

- MQTT: publica N mensajes en el topic de prueba "prueba/latencia" en Mosquitto (puerto 1883)
  y mide cuánto tarda cada uno en volver (el script está suscrito a ese mismo topic).
  El ingestor solo escucha "+/temperatura" y "+/humedad", así que IGNORA estos mensajes:
  no se guarda nada en InfluxDB ni en el CSV.
- HTTP: N pedidos "GET /api/health" a Grafana (puerto 3000, misma EC2), de dos formas:
    a) conexión nueva en cada pedido (lo típico de un dispositivo IoT que usa HTTP)
    b) conexión reutilizada (keep-alive)

La IP y las credenciales se leen de esp32-s3/secrets.h (no se imprimen).

Uso (desde la raíz del repo):
    python comparacion/mqtt_vs_http.py
"""

import re
import socket
import statistics
import sys
import threading
import time
import uuid
from pathlib import Path

import paho.mqtt.client as mqtt

N = 50                     # repeticiones por prueba
PAUSA = 0.1                # segundos entre envíos
TOPIC = "prueba/latencia"  # no coincide con +/temperatura ni +/humedad: el ingestor lo ignora
PAYLOAD = "28.2"           # mismo tamaño que una lectura real del ESP32
PUERTO_HTTP = 3000         # Grafana

# --- Credenciales (de secrets.h, sin imprimirlas) ---------------------------
ruta = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("esp32-s3/secrets.h")
texto = ruta.read_text(encoding="utf-8")


def leer(nombre):
    return re.search(rf'{nombre}\s*=\s*"([^"]*)"', texto).group(1)


HOST, USER, PASS = leer("BROKER"), leer("MQTT_USER"), leer("MQTT_PASS")


def resumen(ms):
    return f"{statistics.mean(ms):6.1f} | {min(ms):6.1f} | {max(ms):6.1f}"


# --- 1. MQTT ----------------------------------------------------------------
print(f"1/3 MQTT: {N} mensajes en '{TOPIC}'...")
llego = threading.Event()
# client_id distinto de "ingestor": si fuera igual, Mosquitto desconectaría al ingestor real
cliente = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,
                      client_id=f"comparacion-{uuid.uuid4().hex[:6]}")
cliente.username_pw_set(USER, PASS)
cliente.on_message = lambda c, u, m: llego.set()

t0 = time.perf_counter()
cliente.connect(HOST, 1883)
cliente.loop_start()
limite = time.time() + 10
while not cliente.is_connected():
    if time.time() > limite:
        sys.exit("MQTT: no se pudo conectar (¿IP o contraseña en secrets.h?)")
    time.sleep(0.001)
conexion_mqtt_ms = (time.perf_counter() - t0) * 1000  # se paga UNA sola vez

cliente.subscribe(TOPIC)
time.sleep(1)

mqtt_ms = []
for _ in range(N):
    llego.clear()
    t = time.perf_counter()
    cliente.publish(TOPIC, PAYLOAD, qos=0)
    if not llego.wait(5):
        sys.exit("MQTT: el mensaje no volvió en 5 s")
    mqtt_ms.append((time.perf_counter() - t) * 1000)
    time.sleep(PAUSA)
cliente.loop_stop()
cliente.disconnect()

# Paquete PUBLISH QoS 0: 1 byte de tipo + 1 de longitud + 2 de largo del topic + topic + valor
bytes_mqtt = 2 + 2 + len(TOPIC) + len(PAYLOAD)


# --- 2 y 3. HTTP ------------------------------------------------------------
def peticion(conexion):
    # Encabezados parecidos a los que envía la librería HTTPClient del ESP32
    return (f"GET /api/health HTTP/1.1\r\n"
            f"Host: {HOST}:{PUERTO_HTTP}\r\n"
            f"User-Agent: ESP32HTTPClient\r\n"
            f"Connection: {conexion}\r\n"
            f"Accept-Encoding: identity\r\n\r\n").encode()


def leer_respuesta(sock):
    """Lee una respuesta HTTP completa y devuelve cuántos bytes ocupó."""
    datos = b""
    while b"\r\n\r\n" not in datos:
        datos += sock.recv(4096)
    encabezados, cuerpo = datos.split(b"\r\n\r\n", 1)
    largo = int(re.search(rb"(?i)content-length:\s*(\d+)", encabezados).group(1))
    while len(cuerpo) < largo:
        cuerpo += sock.recv(4096)
    return len(encabezados) + 4 + len(cuerpo)


print(f"2/3 HTTP con conexión nueva en cada pedido: {N} pedidos...")
req_nueva = peticion("close")
http_nueva_ms = []
for _ in range(N):
    t = time.perf_counter()
    with socket.create_connection((HOST, PUERTO_HTTP), timeout=5) as s:
        s.sendall(req_nueva)
        bytes_resp = leer_respuesta(s)
    http_nueva_ms.append((time.perf_counter() - t) * 1000)
    time.sleep(PAUSA)

print(f"3/3 HTTP con conexión reutilizada (keep-alive): {N} pedidos...")
req_ka = peticion("keep-alive")
http_ka_ms = []
with socket.create_connection((HOST, PUERTO_HTTP), timeout=5) as s:
    for _ in range(N):
        t = time.perf_counter()
        s.sendall(req_ka)
        bytes_resp_ka = leer_respuesta(s)
        http_ka_ms.append((time.perf_counter() - t) * 1000)
        time.sleep(PAUSA)

# --- Resultados -------------------------------------------------------------
print()
print(f"Resultados ({N} repeticiones cada uno, desde este PC hasta la EC2 en us-east-1)")
print()
print("| Protocolo | Latencia prom. (ms) | mín | máx | Bytes enviados | Bytes recibidos | Viajes de ida y vuelta |")
print("|---|---|---|---|---|---|---|")
print(f"| MQTT (conexión abierta) | {resumen(mqtt_ms)} | {bytes_mqtt} | {bytes_mqtt} (eco) | 1 |")
print(f"| HTTP (conexión nueva) | {resumen(http_nueva_ms)} | {len(req_nueva)} | {bytes_resp} | 2 (abrir + pedido) |")
print(f"| HTTP (keep-alive) | {resumen(http_ka_ms)} | {len(req_ka)} | {bytes_resp_ka} | 1 |")
print()
print(f"Conexión MQTT inicial (se paga una sola vez): {conexion_mqtt_ms:.1f} ms")
print("Bytes sin contar encabezados TCP/IP (~40-52 bytes por paquete).")
