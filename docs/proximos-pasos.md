# Próximos pasos — Visualización (Grafana) y alertas (Telegram)

Corresponde al **punto 5 de la guía**: *"Visualice los datos medidos a través de Grafana (genere alertas y notificaciones)"*.

La implementación queda a criterio de quien la haga. Abajo están el estado actual, lo que hay que entregar, las dos opciones para las alertas y los datos técnicos necesarios.

---

## 1. Estado actual (funcionando)

```
ESP32-S3 + DHT22 ──MQTT──▶ Mosquitto ──▶ ingestor.py ──┬──▶ InfluxDB (subred privada)
                           (EC2 broker)  (EC2 broker)   └──▶ /var/lib/ingestor/datos.csv
```

- El ESP32 real publica cada 5 s en `rack1/temperatura` y `rack1/humedad`.
- El ingestor guarda cada lectura en InfluxDB y en el CSV (probado de punta a punta).
- Detalle de la infraestructura: [`infra.md`](infra.md) · ESP32: [`esp32.md`](esp32.md) · Ingestor: [`../ingestor/ingestor.py`](../ingestor/ingestor.py)

## 2. Qué falta entregar

- [ ] **Grafana** con un dashboard de temperatura y humedad (criterio de evaluación: *"Los datos son visualizados a través de Grafana"*).
- [ ] **Alertas** cuando los valores salgan de rango.
- [ ] **Notificaciones por Telegram.**
- [ ] Actualizar la sección **Umbrales** del [`README`](../README.md) con lo que finalmente se implemente.

---

## 3. Datos técnicos que se necesitan

### InfluxDB

| Dato | Valor |
|---|---|
| URL (desde la EC2 del bróker) | `http://<IP_PRIVADA_INFLUX>:8086` |
| Organización | `uao` |
| Bucket | `racks` |
| Token de **lectura** (para Grafana) | `grafana - lectura` (pedir al equipo) |
| Lenguaje de consulta | **Flux** |

**Solo se necesita el token, no un usuario.** En InfluxDB 2.x los programas se autentican únicamente con un token, y el permiso (solo lectura del bucket `racks`) va dentro del token. En Grafana, el datasource de InfluxDB con Flux pide solo **URL, Organization, Token y Default Bucket**.

- En Grafana, elegir **Flux** como *Query language*. Con `InfluxQL` pide usuario y contraseña y requiere configuración extra en InfluxDB.
- El usuario `admin` de InfluxDB es solo para la interfaz web de InfluxDB; no se necesita.

InfluxDB **solo acepta conexiones de máquinas con el grupo de seguridad `sg-broker`**. Si Grafana se instala en la EC2 del bróker, ya tiene acceso. Si se instala en otra EC2, hay que darle `sg-broker` o agregar su grupo de seguridad a la regla 8086 de `sg-influx`.

### Modelo de datos

| Elemento | Valor |
|---|---|
| Measurement | `ambiente` |
| Tag | `rack` (ej. `rack1`; puede haber varios) |
| Fields | `temperatura` (°C), `humedad` (%) |
| Hora | UTC (Grafana la muestra en hora local) |

Consulta Flux de ejemplo (temperatura, una serie por rack):

```flux
from(bucket: "racks")
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)
  |> filter(fn: (r) => r._measurement == "ambiente" and r._field == "temperatura")
  |> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)
```

### MQTT (si las alertas se hacen en Python)

| Dato | Valor |
|---|---|
| Host (desde la EC2 del bróker) | `localhost:1883` |
| Usuario | `ingestor` (la contraseña se pide al equipo) |
| Topics | `+/temperatura`, `+/humedad` (payload: número en texto, ej. `28.2`) |

### Umbrales sugeridos

| Variable | Umbral | Referencia |
|---|---|---|
| Temperatura | > 27 °C | Límite superior recomendado por ASHRAE (ver *Caso de uso* en el README) |
| Humedad | > 60 % | Margen conservador, por debajo del máximo de ASHRAE (70 %) |
| Sin datos | Sin lecturas durante ~5 min | Detecta un sensor apagado o desconectado |

En el cuarto de pruebas el sensor marca alrededor de **28 °C y 70 %**, así que **con estos umbrales la alerta queda activa todo el tiempo**. Para la demo puede convenir subirlos (por ejemplo, 30 °C y 80 %) y disparar la alerta calentando el sensor con la mano o soplándole.

---

## 4. Opciones para las alertas

### Opción A: alertas en Grafana

Grafana evalúa reglas sobre los datos de InfluxDB y envía las notificaciones por un *contact point* de Telegram.

| A favor | En contra |
|---|---|
| Lo que pide la guía, de forma literal ("genere alertas" en Grafana) | Más conceptos de configuración (reglas, contact points, políticas de notificación) |
| Sin código: todo se configura en la interfaz | Evalúa cada cierto intervalo (ej. 30 s), no en el instante |
| Trae la detección de "sin datos" (*No Data*) incluida | |
| Historial y estado de las alertas visibles en Grafana | |

**Borrador disponible (no probado):** la carpeta [`../grafana/`](../grafana/) tiene un script `instalar.sh` que instala Grafana en la EC2 del bróker y deja configurados, mediante *provisioning*:
- El datasource de InfluxDB.
- El dashboard (`dashboards/racks.json`).
- Las reglas de alerta (`provisioning/alerting/reglas.yaml`) y el contact point de Telegram.

Se puede usar, modificar o descartar. **No se ha ejecutado en la EC2**, así que hay que validarlo.

### Opción B: alertas en Python

El ingestor (o un script aparte suscrito a MQTT) compara cada lectura con los umbrales y llama a la API de Telegram. Grafana queda solo para visualizar.

| A favor | En contra |
|---|---|
| La alerta sale en el instante en que llega la lectura | Hay que programar: evitar alertas repetidas en cada lectura, avisar cuando se normaliza y detectar "sin datos" con un temporizador |
| Control total del mensaje y de la lógica | Si el proceso se cae, no hay alertas |
| Pocas dependencias (`requests` o `urllib`) | Hay que justificar en la presentación que las alertas no están en Grafana |

Si se integra en el ingestor, el punto de entrada natural es la función `al_recibir()` de [`../ingestor/ingestor.py`](../ingestor/ingestor.py), después de `guardar_influx()`. El token del bot y el chat ID deben ir en `ingestor/.env`, **nunca en el código**.

Envío de un mensaje a Telegram:

```
POST https://api.telegram.org/bot<TOKEN>/sendMessage
     chat_id=<CHAT_ID>&text=Temperatura alta en rack1: 28.2 °C
```

---

## 5. Pasos comunes a las dos opciones

### 5.1 Crear el bot de Telegram

1. En Telegram, buscar **@BotFather** → enviar `/newbot` → poner un nombre → copiar el **token** (`123456:ABC...`).
2. Abrir el chat con el bot nuevo y enviarle cualquier mensaje.
3. Abrir en el navegador `https://api.telegram.org/bot<TOKEN>/getUpdates` → copiar el número de `"chat":{"id": ...}`: es el **Chat ID**.
4. Para un grupo: agregar el bot al grupo y repetir el paso 3. El chat ID de un grupo es negativo.

### 5.2 Abrir Grafana en el grupo de seguridad

Si Grafana corre en la EC2 del bróker: EC2 → Grupos de seguridad → `iot-mqtt-mosquitto-manual-sg-broker` → *Editar reglas de entrada* → agregar **TCP 3000** desde **Mi IP**.

Para la presentación desde otra red (por ejemplo, la universidad), hay que agregar esa IP también.

### 5.3 Recursos de la EC2 del bróker

Es una `t3.micro` (1 GB de RAM) que ya corre Mosquitto y el ingestor. Grafana cabe con poco tráfico. Si se nota lenta, se puede crear una EC2 aparte en la subred pública (ver la nota de InfluxDB en la sección 3).

---

## 6. Criterios para dar el punto por terminado

- [ ] El dashboard muestra temperatura y humedad del ESP32 real, actualizándose solo.
- [ ] Al superar un umbral llega un mensaje a Telegram.
- [ ] Al desconectar el ESP32, llega un aviso de "sin datos" (recomendado).
- [ ] Ningún secreto (token del bot, chat ID, token de InfluxDB) quedó en el repositorio.
- [ ] El README (sección **Umbrales** y **Estructura del repositorio**) refleja lo implementado. Si se descarta la carpeta `grafana/`, hay que borrarla y quitarla del README.
- [ ] Capturas del dashboard y de la alerta en Telegram, para la presentación.
