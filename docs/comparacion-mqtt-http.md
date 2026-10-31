# Experimento — MQTT vs HTTP

Comparación de **latencia**, **tamaño de los mensajes** y **consumo de energía** entre MQTT y HTTP para enviar una lectura del sensor desde la red del ESP32 hasta la nube.

- **Fecha:** 2026-10-31
- **Script:** [`../comparacion/mqtt_vs_http.py`](../comparacion/mqtt_vs_http.py)

---

## 1. Objetivo e hipótesis

**Objetivo:** medir cuánto cuesta enviar una lectura (`28.2`) con cada protocolo.

**Hipótesis:** MQTT envía menos bytes y tiene menor latencia, porque:

| | MQTT | HTTP |
|---|---|---|
| Conexión | Se abre una vez y queda abierta | Normalmente una conexión nueva por cada lectura |
| Encabezado | Binario, 2 bytes fijos + el topic | Texto: `GET`/`POST`, `Host`, `User-Agent`, etc. |
| Respuesta | Con QoS 0, ninguna | Siempre (`200 OK` + encabezados + cuerpo) |

## 2. Montaje

```
PC (misma red WiFi que el ESP32) ──internet──▶ EC2 broker (AWS us-east-1)
                                                 • Mosquitto :1883  ← prueba MQTT
                                                 • Grafana   :3000  ← prueba HTTP
```

- Las dos pruebas usan **el mismo origen** (la red del ESP32), **el mismo destino** (la misma EC2) y **la misma distancia**.
- **No se modificó nada del sistema en producción.** El script usa lo que ya estaba corriendo:
  - **MQTT:** Mosquitto, con el topic de prueba `prueba/latencia`. El ingestor solo escucha `+/temperatura` y `+/humedad`, así que **ignora** estos mensajes: no se guardó nada en InfluxDB ni en el CSV. El script usó un identificador de cliente propio (`comparacion-xxxxxx`), para no desconectar al ingestor ni al ESP32.
  - **HTTP:** `GET /api/health` de Grafana, que no pide autenticación, es de solo lectura y devuelve un JSON corto.

## 3. Método

50 repeticiones por prueba, con 0.1 s de pausa entre envíos. Tiempos medidos con `time.perf_counter()`.

| Prueba | Qué se mide |
|---|---|
| **MQTT** (conexión abierta) | El script publica `28.2` con **QoS 0** en `prueba/latencia` y mide el tiempo hasta **recibir su propio mensaje** de vuelta (está suscrito a ese topic). Es un viaje de ida y vuelta completo, comparable con pedido + respuesta en HTTP |
| **HTTP con conexión nueva** | Por cada pedido: abrir la conexión TCP, enviar `GET /api/health`, leer la respuesta y cerrar. Es el patrón típico de un dispositivo IoT que usa HTTP |
| **HTTP con *keep-alive*** | Una sola conexión TCP reutilizada para los 50 pedidos. Sirve para separar el costo de **abrir la conexión** del costo del **protocolo** |

**Bytes:**
- **HTTP:** se cuentan exactamente: el pedido enviado y la respuesta recibida, con encabezados y cuerpo.
- **MQTT:** se calcula el tamaño del paquete `PUBLISH` QoS 0: 1 byte de tipo + 1 de longitud + 2 del largo del topic + topic + valor.
- En ambos casos **sin** los encabezados TCP/IP, que suman unos 40–52 bytes por paquete.

Los encabezados del pedido HTTP imitan a los de la librería `HTTPClient` del ESP32 (`User-Agent: ESP32HTTPClient`).

## 4. Resultados

| Protocolo | Latencia prom. (ms) | Mín (ms) | Máx (ms) | Bytes enviados | Bytes recibidos | Viajes de ida y vuelta |
|---|---|---|---|---|---|---|
| **MQTT** (conexión abierta) | **82.0** | 78.5 | 109.1 | **23** | 23 (eco de la prueba) | 1 |
| **HTTP** (conexión nueva) | **177.8** | 159.4 | 204.4 | 127 | 358 | 2 (abrir + pedido) |
| HTTP (*keep-alive*) | 82.5 | 80.6 | 90.6 | 132 | 339 | 1 |

**Conexión MQTT inicial:** 244.1 ms. Se paga **una sola vez**, al encender el ESP32.

### Costo de una lectura en uso real

En el sistema real, el ESP32 publica con QoS 0 y **no recibe respuesta**, así que el eco de la prueba no cuenta:

| | MQTT | HTTP (conexión nueva) | Diferencia |
|---|---|---|---|
| Bytes por lectura | **23** | **485** (127 + 358) | **~21 veces más en HTTP** |
| Paquetes TCP extra por lectura | 0 | Apertura (3) y cierre (~4) de la conexión, no contados arriba | HTTP |
| Latencia | 82 ms | 178 ms | **~2.2 veces más en HTTP** |

## 5. Análisis

### Tamaño: MQTT es ~21 veces más liviano

MQTT usa un encabezado binario mínimo y, con QoS 0, no espera respuesta. HTTP envía encabezados en texto **en el pedido y en la respuesta**: de los 485 bytes, el dato útil (`28.2`) ocupa solo 4. Además, con conexión nueva, HTTP agrega los paquetes de abrir y cerrar la conexión TCP en **cada** lectura.

### Latencia: MQTT tarda menos de la mitad

- **MQTT (82 ms):** 1 viaje de ida y vuelta, porque la conexión ya está abierta.
- **HTTP con conexión nueva (178 ms):** 2 viajes, uno para abrir la conexión TCP y otro para el pedido y la respuesta.
- **HTTP con keep-alive (83 ms):** igual que MQTT. La ventaja de latencia de MQTT viene sobre todo de **mantener la conexión abierta**, que es como funciona por diseño. Pero aun con *keep-alive*, HTTP sigue enviando **~20 veces más bytes** (471 contra 23).

Unos 80 ms es el tiempo de ida y vuelta entre Colombia y Virginia (us-east-1), así que la latencia de MQTT está prácticamente en el mínimo que permite la red.

### Energía: no se midió, pero se deduce

Medirla requiere hardware (un medidor USB o un sensor INA219). A partir de los resultados:

- En el ESP32, lo que más energía consume es la **radio WiFi transmitiendo y esperando respuestas**.
- MQTT transmite **~21 veces menos bytes**, no espera respuesta y no abre ni cierra conexiones en cada lectura → **menos tiempo de radio activa → menos energía.**
- Con una lectura cada 5 s, el WiFi del ESP32 permanece encendido con los dos protocolos, así que la diferencia de consumo sería **moderada**. En un dispositivo a **batería** que duerme entre lecturas (*deep sleep*), la diferencia sería mucho mayor.

## 6. Relación con el sistema real (QoS 0)

El sistema usa **QoS 0**: el ESP32 publica con `PubSubClient` (que solo soporta QoS 0) y el ingestor se suscribe sin indicar QoS (por defecto, 0).

| QoS | Garantía | Paquetes por mensaje |
|---|---|---|
| **0** (el que se usa) | Como máximo una vez (puede perderse) | 1 |
| 1 | Al menos una vez (puede repetirse) | 2 (`PUBLISH` + `PUBACK`) |
| 2 | Exactamente una vez | 4 |

QoS 0 es adecuado aquí: si se pierde una lectura, la siguiente llega 5 s después. Con QoS 1, MQTT agregaría una confirmación de 4 bytes y seguiría siendo mucho más liviano que HTTP.

## 7. Limitaciones

- **Se midió desde un PC, no desde el ESP32.** Están en la misma red, así que la distancia hasta AWS es la misma, pero el ESP32 procesa más lento: sus tiempos absolutos serían algo mayores.
- **La prueba HTTP usa `GET` sobre Grafana.** Un sensor real enviaría un `POST` con `Content-Type`, `Content-Length` y el valor, unos 50 bytes más. La prueba **favorece levemente a HTTP**. Otro servidor HTTP podría responder con más o menos encabezados.
- **Los bytes de MQTT son calculados** a partir del formato del protocolo, no capturados. Para verificarlos se puede capturar el tráfico con `tcpdump` y abrirlo en Wireshark.
- **Una sola corrida** de 50 repeticiones, desde una sola red.
- **La energía no se midió**: se deduce de los bytes y la latencia.
- **Sin cifrado** en ninguno de los dos (MQTT en 1883, HTTP sin TLS). Con TLS, los dos aumentarían su costo, y la conexión persistente de MQTT sería aún más ventajosa, porque el saludo de TLS es costoso.

## 8. Cómo repetirlo

Requisitos: Python con `paho-mqtt`, el archivo `esp32-s3/secrets.h` con la IP y las credenciales MQTT, y la IP del PC autorizada en el puerto 3000 de `sg-broker`.

```powershell
pip install paho-mqtt
python comparacion/mqtt_vs_http.py
```

Tarda menos de 1 minuto y no modifica nada en la EC2.
