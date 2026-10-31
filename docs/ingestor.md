# Ingestor — MQTT → InfluxDB + CSV

Programa en Python que **escucha los mensajes del ESP32 en Mosquitto y guarda cada lectura en InfluxDB y en un archivo CSV**. Cumple el punto 4 de la guía: *"Almacene los datos en una base de datos de series de tiempo llamada Influx y en un archivo CSV"*.

Código: [`../ingestor/`](../ingestor/)

---

## 1. Dónde encaja

```
ESP32 ──publica──▶ Mosquitto ──entrega──▶ ingestor.py ──┬──▶ InfluxDB  (EC2 influx, subred privada)
       rack1/temperatura          (EC2 broker)          │     bucket "racks"
       rack1/humedad                                    └──▶ datos.csv (EC2 broker)
```

- Corre en la **EC2 del bróker**: llega a Mosquitto por `localhost` y a InfluxDB por la red interna (`10.0.2.x:8086`).
- El ESP32 **no sabe que el ingestor existe**: solo publica en el bróker. Esa es la ventaja del modelo publicar/suscribir de MQTT.
- Corre como **servicio `systemd`**: arranca solo al encender la máquina y se reinicia si falla.

## 2. Archivos

| Archivo | Qué es |
|---|---|
| `ingestor.py` | El programa (~120 líneas) |
| `requirements.txt` | Librerías: `paho-mqtt` (MQTT), `influxdb-client` (InfluxDB), `python-dotenv` (lee el `.env`) |
| `.env.example` | Plantilla de configuración. El `.env` real solo existe en la EC2 y **no se sube a GitHub** |
| `ingestor.service` | Definición del servicio `systemd` |
| `instalar.sh` | Instala todo en la EC2: entorno virtual, librerías, `.env` y servicio |

## 3. Configuración (`.env`)

| Variable | Valor | Para qué |
|---|---|---|
| `MQTT_HOST` / `MQTT_PORT` | `localhost` / `1883` | Mosquitto corre en la misma EC2 |
| `MQTT_USER` / `MQTT_PASS` | `ingestor` / *(secreto)* | Usuario MQTT del ingestor |
| `INFLUX_URL` | `http://10.0.2.x:8086` | IP privada de la EC2 de InfluxDB |
| `INFLUX_TOKEN` | *(secreto)* | Token de **solo escritura** en el bucket `racks` |
| `INFLUX_ORG` / `INFLUX_BUCKET` | `uao` / `racks` | Dónde se guardan los datos |
| `CSV_PATH` | `/var/lib/ingestor/datos.csv` | Ruta del CSV |

`instalar.sh` crea el `.env` preguntando los 3 datos secretos y lo deja con permisos `600` (solo lo lee el usuario `ubuntu`).

---

## 4. Cómo funciona por dentro

El programa tiene tres partes: **arranque**, **conexión** y **procesamiento de cada mensaje**.

### 4.1 Arranque (`main`)

1. Lee la configuración del `.env`.
2. Crea la carpeta del CSV si no existe.
3. Crea el cliente MQTT con `client_id="ingestor"`, usuario y contraseña.
4. Registra tres funciones (*callbacks*) que la librería llama cuando pasa algo: `al_conectar`, `al_desconectar` y `al_recibir`.
5. Se conecta y se queda escuchando para siempre (`loop_forever`).

### 4.2 Conexión (`al_conectar`, `al_desconectar`)

- Al conectarse, **se suscribe** a `+/temperatura` y `+/humedad`. El `+` significa "cualquier valor en este nivel", así que recibe de `rack1`, `rack2`, etc., sin cambiar código.
- La suscripción se hace **dentro de `al_conectar`**: si la conexión se cae y se recupera, se vuelve a suscribir solo.
- Si se cae la conexión, `paho` **reintenta automáticamente**, esperando entre 1 y 30 segundos.

### 4.3 Procesamiento de cada mensaje (`al_recibir`)

Se ejecuta una vez por cada mensaje que llega:

```
mensaje "28.2" en "rack1/temperatura"
   │
   ├─ 1. Toma la hora actual en UTC (una sola vez)
   ├─ 2. Separa el topic   → rack = "rack1", variable = "temperatura"
   ├─ 3. Convierte a número → 28.2
   │      └─ si no es número, o es nan/inf → lo registra y lo descarta
   ├─ 4. Guarda en el CSV
   └─ 5. Guarda en InfluxDB
          └─ si falla → lo registra; el dato ya quedó en el CSV
```

---

## 5. Cómo quedan los datos

### InfluxDB

```
ambiente,rack=rack1 temperatura=28.2 1793068549637
└──┬───┘ └───┬────┘ └──────┬───────┘ └─────┬─────┘
measurement  tag         field         hora (ms)
```

| Elemento | Valor | Para qué sirve |
|---|---|---|
| Measurement | `ambiente` | El equivalente a una "tabla" |
| Tag | `rack` | Filtrar o separar por rack en Grafana |
| Field | `temperatura` o `humedad` | El valor medido |
| Hora | UTC, precisión de milisegundos | Grafana la muestra en hora local |

### CSV (`/var/lib/ingestor/datos.csv`)

```
timestamp_utc,rack,variable,valor
2026-10-27T02:35:49.637+00:00,rack1,temperatura,28.2
2026-10-27T02:35:49.712+00:00,rack1,humedad,70.5
```

Formato "largo": **una fila por mensaje**. Como cada mensaje trae una sola variable, así no quedan celdas vacías.

- **Dónde queda:** en la **EC2 del bróker**. `/var/lib/` es la ubicación estándar en Linux para los datos que generan los servicios. La carpeta la crea `systemd` (`StateDirectory=ingestor` en `ingestor.service`) con permisos para el usuario `ubuntu`. Se puede cambiar con `CSV_PATH` en el `.env`.
- **Para verlo o descargarlo:** ver la sección 9. Una vez descargado, se abre directamente en Excel.

---

## 6. Decisiones de diseño

| Decisión | Por qué |
|---|---|
| **La hora la pone el ingestor**, no el ESP32 | El ESP32 no tiene reloj real: tendría que sincronizarse por internet (NTP). La demora entre medir y recibir es de milisegundos, despreciable para temperatura |
| **Hora en UTC** | Es el estándar y evita confusiones con zonas horarias. Grafana la convierte a hora de Colombia |
| **La misma hora para InfluxDB y CSV** | Se toma una sola vez, así las dos fuentes coinciden exactamente |
| **Primero el CSV, después InfluxDB** | Si InfluxDB falla, el dato no se pierde |
| **Descartar `nan` e `inf`** | Son lecturas fallidas del DHT22; guardarlas dañaría las gráficas y las alertas |
| **Suscripción con `+`** | Agregar un rack nuevo no requiere cambiar el ingestor |
| **Escritura síncrona en InfluxDB** | Más simple: se sabe al instante si el dato se guardó. Con una lectura cada 5 s, el rendimiento no es un problema |
| **Token de solo escritura** | Si alguien roba el token, no puede leer ni borrar datos |
| **Entorno virtual (`venv`)** | Ubuntu 24.04 no permite instalar librerías con `pip` directamente en el sistema |

## 7. Resiliencia

| Si pasa esto… | El ingestor… |
|---|---|
| Se reinicia Mosquitto | Se reconecta y se vuelve a suscribir solo |
| InfluxDB no responde | Guarda en el CSV y registra el error |
| Llega un valor inválido | Lo descarta y lo registra |
| El programa se cae | `systemd` lo reinicia a los 5 segundos (`Restart=always`) |
| Se reinicia la EC2 | Arranca solo, después de la red y de Mosquitto |

---

## 8. Instalación y actualización

Desde el PC, en la carpeta del repositorio (requiere el alias SSH `broker` de [`infra.md`](infra.md)):

```powershell
scp -r ingestor broker:~/
ssh -t broker "bash ~/ingestor/instalar.sh"
```

El script:
1. Instala `python3-venv`.
2. Crea el entorno virtual e instala las librerías.
3. Crea el `.env`, preguntando la IP de InfluxDB, la contraseña MQTT y el token. **Si ya existe, lo conserva.**
4. Instala el servicio, lo arranca y muestra su estado.

**Para actualizar el código**, se repiten los mismos dos comandos. No vuelve a preguntar los secretos.

## 9. Operación (dentro de `ssh broker`)

```bash
sudo systemctl status ingestor        # ¿está corriendo?
journalctl -u ingestor -f             # log en vivo (Ctrl+C para salir)
sudo systemctl restart ingestor       # reiniciar
tail /var/lib/ingestor/datos.csv      # últimas filas del CSV
wc -l /var/lib/ingestor/datos.csv     # cuántas filas tiene
```

Probar sin el ESP32:

```bash
mosquitto_pub -h localhost -u esp32 -P '<CLAVE>' -t rack1/temperatura -m 25.1
# En el log debe aparecer:  INFO rack1 temperatura=25.1
```

Descargar el CSV al PC:

```powershell
scp broker:/var/lib/ingestor/datos.csv .
```

### Mensajes del log

| Mensaje | Significado |
|---|---|
| `Conectado a Mosquitto` + `Suscrito a ...` | Arrancó bien |
| `rack1 temperatura=28.2` | Lectura guardada en InfluxDB y CSV |
| `Valor no numérico` / `Valor inválido` | Mensaje descartado |
| `Error escribiendo en InfluxDB (guardado solo en CSV)` | InfluxDB no respondió. Revisar la EC2 de InfluxDB y el grupo de seguridad |
| `Desconectado de Mosquitto ... Reintentando` | Se perdió la conexión con el bróker; se reconecta solo |
| `No se pudo conectar a Mosquitto: Not authorized` | Usuario o contraseña MQTT incorrectos en el `.env` |

## 10. Limitaciones conocidas

- **Los mensajes que llegan mientras el ingestor está caído se pierden.** El ESP32 publica con QoS 0 (sin confirmación), y Mosquitto no los guarda para suscriptores desconectados.
- **El CSV crece sin límite.** Con una lectura cada 5 s son unos 2 MB por día; no es problema para la práctica, pero en producción habría que rotarlo.
- **Si InfluxDB falla, el dato queda solo en el CSV.** No se reintenta después la escritura en InfluxDB.
