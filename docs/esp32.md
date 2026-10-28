# Guía — Configurar el ESP32-S3 con el sensor DHT22

El ESP32 lee temperatura y humedad del DHT22 cada 5 segundos y las publica en el bróker MQTT (Mosquitto en AWS).

```
DHT22 ──▶ ESP32-S3 ──WiFi──▶ Mosquitto (EC2) ──▶ ingestor ──▶ InfluxDB + CSV ──▶ Grafana
```

Código: [`esp32-s3/esp32-s3.ino`](../esp32-s3/esp32-s3.ino)

---

## 1. Materiales

- ESP32-S3 (probado con **ESP32-S3-WROOM-1 N16R8**)
- Sensor **DHT22 en módulo de 3 pines**: trae la resistencia pull-up, no hay que agregar nada
- 3 cables dupont hembra-hembra
- Cable USB-C **de datos** (algunos cables solo cargan)

## 2. Conexión

**Con el ESP32 desconectado del USB:**

| DHT22 | ESP32-S3 |
|---|---|
| `+` (VCC) | **3V3** (no 5V) |
| `out` (DATA) | **GPIO 15** |
| `-` (GND) | **GND** |

El orden de los pines cambia según el fabricante del módulo: **lean lo que dice la plaquita**. Si `+` y `-` quedan invertidos, el sensor se calienta y se puede dañar.

En el N16R8 no usen los GPIO 35, 36 y 37: los usa la PSRAM.

## 3. Arduino IDE (solo la primera vez)

1. Instalar **Arduino IDE 2**: https://www.arduino.cc/en/software
2. **Soporte para ESP32:** *Herramientas → Placa → Gestor de placas* → buscar `esp32` → instalar **esp32 by Espressif Systems**.
3. **Librerías:** *Herramientas → Administrar bibliotecas*:
   - **DHT sensor library** (Adafruit). Cuando pregunte por dependencias, elegir *Instalar todo*.
   - **PubSubClient** (autor **Nick O'Leary**). No instalar también `PubSubClient3`: las dos chocan.

## 4. Credenciales (`secrets.h`)

En la carpeta `esp32-s3/`, copiar `secrets.h.example` con el nombre **`secrets.h`** y completarlo:

```cpp
const char* WIFI_SSID = "NOMBRE_DE_SU_RED";
const char* WIFI_PASS = "CONTRASEÑA_WIFI";
const char* BROKER    = "x.x.x.x";            // IP elástica del bróker (pedir al equipo)
const char* MQTT_USER = "esp32";
const char* MQTT_PASS = "CLAVE_MQTT_ESP32";   // pedir al equipo
```

- `secrets.h` está en el `.gitignore`: **nunca se sube a GitHub**.
- **WiFi:** el ESP32-S3 solo funciona en **2.4 GHz**.
  - Si su router emite 2.4 y 5 GHz con el mismo nombre, sirve: el ESP32 usa la de 2.4 sola.
  - **No sirven** las redes institucionales con usuario y contraseña (como la de la universidad). Usen el **hotspot del celular**; en iPhone, activen *Maximizar compatibilidad*.
  - Para ver el nombre y la banda de su red en Windows: `netsh wlan show interfaces` (campos `SSID` y `Banda`).
  - El nombre de la red distingue mayúsculas y minúsculas.

## 5. Identificar su rack

En `esp32-s3.ino`:

```cpp
const char* RACK = "rack1";
```

**Si hay más de un ESP32 conectado, cada uno debe tener un nombre distinto** (`rack1`, `rack2`, …). El ingestor y Grafana los separan automáticamente por este nombre.

Topics que se publican: `<RACK>/temperatura` y `<RACK>/humedad`, por ejemplo `rack2/temperatura`.

## 6. Subir el programa

1. Conectar el ESP32 por USB, preferiblemente al puerto marcado **COM** o **UART**.
2. Abrir `esp32-s3/esp32-s3.ino`. Arriba deben aparecer las pestañas `esp32-s3.ino` y `secrets.h`.
3. En **Herramientas**. Las opciones aparecen después de elegir la placa; hay que abrir cada una:

   | Opción | Valor |
   |---|---|
   | Placa | `esp32` → **ESP32S3 Dev Module** |
   | Puerto | El `COM` que aparece al conectar el ESP32 (ej. `COM3`). Si hay varios, desconectar el ESP32 y ver cuál desaparece |
   | Flash Size | **16MB (128Mb)** |
   | PSRAM | **OPI PSRAM** |
   | USB CDC On Boot | **Enabled**, solo si se conectó al puerto marcado **USB** |

4. Clic en **→ Subir**. La primera vez tarda 1 o 2 minutos en compilar. Termina con `Hard resetting via RTS pin...`.

## 7. Verificar

Abrir el **Monitor Serie** (ícono de lupa) a **115200 baud**. Si no sale nada, presionar **RST** en la placa.

```
Conectando a Wi-Fi..... Wi-Fi conectado, IP: 192.168.x.x
Conectando a x.x.x.x como esp32-rack1-a3f... conectado
Publicado 28.2 °C en rack1/temperatura
Publicado 70.5 % en rack1/humedad
```

Para confirmar que llega a AWS:

- **MQTT Explorer** → Host: IP elástica, Port: `1883`, usuario `ingestor` → debe aparecer `rack1 → temperatura / humedad`.
- **Grafana** → `http://<IP_ELASTICA>:3000` → *Dashboards → Racks → Monitoreo de racks*.

Prueba física: soplar suave sobre el sensor hace subir la humedad.

## 8. Problemas comunes

| Síntoma | Causa | Solución |
|---|---|---|
| No aparece ningún puerto COM | Cable de solo carga | Probar otro cable o el otro USB-C de la placa |
| Al subir: `Failed to connect to ESP32` | La placa no entró en modo de carga | Mantener **BOOT**, presionar y soltar **RST**, soltar **BOOT**, subir de nuevo |
| Monitor serie en blanco | Puerto USB nativo sin CDC | `USB CDC On Boot: Enabled`, o usar el puerto COM |
| Se queda en `Conectando a Wi-Fi.....` | Red de 5 GHz, institucional o contraseña incorrecta | Usar el hotspot de 2.4 GHz y revisar `secrets.h` |
| `falló (estado 4)` o `(estado 5)` | Usuario o clave MQTT incorrectos | Revisar `MQTT_USER` y `MQTT_PASS` |
| `falló (estado -2)` | IP del bróker incorrecta, EC2 apagada o puerto 1883 bloqueado por la red | Revisar `BROKER`, que el Learner Lab esté iniciado y probar con el hotspot |
| `Error leyendo el DHT22` | Cableado | Revisar que `out` esté en el **GPIO 15** y la alimentación en **3V3** |
| Error de compilación con `PubSubClient` | Están instaladas `PubSubClient` y `PubSubClient3` | Desinstalar `PubSubClient3` |

## 9. Simulación en Wokwi (opcional)

Se puede probar el mismo código en https://wokwi.com con una plantilla ESP32-S3. La carpeta trae `libraries.txt` con las librerías que usa Wokwi. En Wokwi:

- Circuito: agregar un **DHT22** y conectar `VCC → 3V3`, `SDA → 15`, `GND → GND` (`NC` sin conectar).
- WiFi: `WIFI_SSID = "Wokwi-GUEST"`, `WIFI_PASS = ""`.
- Como Wokwi no usa archivos aparte, pegar las 5 constantes de `secrets.h` directamente en el código, en lugar del `#include "secrets.h"`. **No suban esa versión a GitHub.**
