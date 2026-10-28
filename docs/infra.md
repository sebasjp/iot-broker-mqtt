# Infraestructura — Bróker MQTT en AWS

Infraestructura creada **manualmente** en la consola de AWS (AWS Academy Learner Lab, región `us-east-1`) para la Práctica 2.

---

## 1. Arquitectura

```
                               AWS · us-east-1
              ┌─ VPC iot-mqtt-mosquitto-manual (10.0.0.0/16) ─────────────────────────────┐
              │                                                                           │
 ┌──────────┐ │  ┌─ Subred pública 10.0.1.0/24 ─────┐     ┌─ Subred privada 10.0.2.0/24 ─┐ │
 │ ESP32-S3 │ │  │ sg-broker                        │     │ sg-influx                    │ │
 │ + DHT22  │─┼─▶│ EC2 broker (IP elástica)         │8086 │ EC2 influx (sin IP pública)  │ │
 └──────────┘ │  │  • Mosquitto :1883               │────▶│  • InfluxDB 2.7 :8086        │ │
  MQTT :1883  │  │                                  │ SSH │                              │ │
 ┌──────────┐ │  │                                  │────▶│                              │ │
 │ PC admin │─┼─▶│                                  │ :22 │                              │ │
 └──────────┘ │  └──────────────────────────────────┘     └──────────────────────────────┘ │
  SSH :22     │         ▲ rt-publica: 0.0.0.0/0 → IGW         rt-privada: solo local      │
  MQTT :1883  │   Internet Gateway                                                        │
              └───────────────────────────────────────────────────────────────────────────┘
```

**Flujo de un mensaje:** el ESP32 publica en la IP elástica → entra a la VPC por el **Internet Gateway** → la **tabla de rutas** lo dirige a la subred pública → el **grupo de seguridad** lo deja pasar (puerto 1883) → **Mosquitto** valida el usuario y la contraseña y entrega el mensaje a los suscriptores.

**InfluxDB** está en la subred privada: no tiene IP pública ni salida a internet, y solo acepta conexiones de las máquinas con el grupo de seguridad `sg-broker`.

---

## 2. Recursos creados

| # | Recurso | Nombre | Configuración clave |
|---|---|---|---|
| 1 | VPC | `iot-mqtt-mosquitto-manual` | CIDR `10.0.0.0/16` |
| 2 | Internet Gateway | `iot-mqtt-mosquitto-manual-igw` | Conectado (*attached*) a la VPC |
| 3 | Subred | `iot-mqtt-mosquitto-manual-subred-publica` | CIDR `10.0.1.0/24`, zona `us-east-1a`, asigna IP pública automáticamente |
| 4 | Tabla de rutas | `iot-mqtt-mosquitto-manual-rt-publica` | `10.0.0.0/16 → local` · `0.0.0.0/0 → igw` · asociada a la subred pública |
| 5 | Grupo de seguridad | `iot-mqtt-mosquitto-manual-sg-broker` | Entrada: 22 desde la IP del admin, 1883 desde `0.0.0.0/0` · Salida: todo |
| 6 | EC2 | `iot-mqtt-mosquitto-manual-broker` | Ubuntu 24.04 LTS, `t3.micro`, 8 GiB gp3, par de claves `vockey` |
| 7 | IP elástica | `iot-mqtt-mosquitto-manual-eip` | Asociada a la EC2 del bróker |
| 8 | Subred | `iot-mqtt-mosquitto-manual-subred-privada` | CIDR `10.0.2.0/24`, zona `us-east-1a`, **sin** IP pública automática |
| 9 | Tabla de rutas | `iot-mqtt-mosquitto-manual-rt-privada` | Solo `10.0.0.0/16 → local` · asociada a la subred privada |
| 10 | Grupo de seguridad | `iot-mqtt-mosquitto-manual-sg-influx` | Entrada: 8086 y 22 **solo desde `sg-broker`** · Salida: todo |
| 11 | EC2 | `iot-mqtt-mosquitto-manual-influx` | Ubuntu 24.04 LTS, `t3.micro`, subred privada, sin IP pública, par de claves `vockey` |
| — | NAT Gateway (temporal) | `iot-mqtt-mosquitto-manual-nat` | Se usó solo para instalar InfluxDB. **Ya fue eliminado**, junto con su IP elástica y su ruta |

### Qué es cada uno

- **VPC**: la red privada propia dentro de AWS. Aísla los recursos del resto de AWS.
- **Subred**: una parte del rango de la VPC, ubicada en una zona de disponibilidad (un centro de datos).
- **Internet Gateway (IGW)**: la conexión de la VPC con internet, en ambas direcciones.
- **Tabla de rutas**: indica a dónde se envía el tráfico. **Una subred es pública porque su tabla de rutas envía `0.0.0.0/0` al IGW.**
- **Grupo de seguridad**: el firewall de la EC2. Es *stateful*: si deja entrar una conexión, deja salir automáticamente la respuesta. Todo lo que no está permitido queda bloqueado.
- **EC2**: la máquina virtual donde corre Mosquitto.
- **IP elástica**: IP pública fija. Sin ella, la IP cambia cada vez que la instancia se apaga, y el Learner Lab apaga las instancias al terminar cada sesión.
- **Par de claves `vockey`**: la clave pública queda en la EC2 y la privada es el archivo `labsuser.pem`, que permite entrar por SSH sin contraseña.
- **Subred privada**: su tabla de rutas solo tiene la ruta `local`, así que no tiene salida ni entrada desde internet. Las máquinas de la VPC se comunican entre sí gracias a esa ruta, sin necesidad de NAT.
- **NAT Gateway**: permite que una subred privada **salga** a internet sin que nadie pueda entrar desde afuera. Va en la subred **pública** y la subred privada lo usa con la ruta `0.0.0.0/0 → nat`. Se usó solo mientras se instalaba InfluxDB, porque se cobra por hora.

### Puertos abiertos

| Máquina | Puerto | Origen | Motivo |
|---|---|---|---|
| broker | 22 (SSH) | Solo la IP del administrador | Quien entra por SSH controla toda la máquina |
| broker | 1883 (MQTT) | `0.0.0.0/0` | El ESP32 se conecta desde cualquier red WiFi; Mosquitto exige usuario y contraseña |
| influx | 8086 (InfluxDB) | `sg-broker` | Lo usan el ingestor y Grafana, que corren en el bróker |
| influx | 22 (SSH) | `sg-broker` | Administración usando el bróker como bastión |

Las reglas de `sg-influx` usan un **grupo de seguridad como origen**, en lugar de una IP: acepta conexiones de cualquier máquina que tenga `sg-broker`, aunque cambie su IP privada.

### IP pública vs. privada

| IP | Ejemplo | Uso |
|---|---|---|
| Privada | `10.0.1.x` (broker) · `10.0.2.x` (influx) | Comunicación dentro de la VPC. No es accesible desde internet |
| Pública (elástica) | `x.x.x.x` | La usan el ESP32, MQTT Explorer y SSH |

---

## 3. Mosquitto

Instalado con `apt install mosquitto mosquitto-clients`. Corre como servicio (`systemctl`) y arranca solo cuando se enciende la máquina.

**Configuración** en `/etc/mosquitto/conf.d/practica.conf`:

```
listener 1883                          # escuchar en el puerto 1883 desde cualquier IP
allow_anonymous false                  # exigir usuario y contraseña
password_file /etc/mosquitto/passwd    # archivo de usuarios
```

**Usuarios** (las contraseñas se guardan cifradas en `/etc/mosquitto/passwd`, con permisos `700` y dueño `mosquitto`):

| Usuario | Uso |
|---|---|
| `esp32` | Publicar desde el ESP32 |
| `ingestor` | Suscribirse (MQTT Explorer / programa Python) |

Las contraseñas **no** están en el repositorio. Pídanlas al equipo.

---

## 4. InfluxDB

### Instalación

Como la subred privada no tiene internet, se hizo así:

1. Se creó un **NAT Gateway temporal** en la subred pública y se agregó la ruta `0.0.0.0/0 → nat` a `rt-privada`.
2. Se instaló **InfluxDB 2.7** desde el repositorio oficial de InfluxData (paquetes `influxdb2` e `influxdb2-cli`), verificando la huella digital de la llave del repositorio.
3. Se dejó como servicio: `sudo systemctl enable --now influxdb`.
4. Se eliminaron la ruta, el NAT Gateway y su IP elástica. Desde entonces `ping google.com` falla en esa máquina, lo que confirma que está aislada.

Si en el futuro hay que instalar o actualizar algo en esa máquina, se repite el paso 1 y luego el 4.

### Configuración (`influx setup`)

| Concepto | Valor | Qué es |
|---|---|---|
| Usuario | `admin` | Administrador de InfluxDB |
| Organización | `uao` | Espacio de trabajo que agrupa todo |
| Bucket | `racks` | Donde se guardan los datos (se creó como `invernadero` y se renombró con `influx bucket update`) |
| Retención | Infinita (`0`) | Los datos no se borran automáticamente |

### Tokens

Cada programa usa un token con el **permiso mínimo** que necesita:

| Token | Lo usa | Permiso |
|---|---|---|
| Operador (admin) | CLI `influx` dentro de la EC2 | Total |
| `ingestor - escritura` | Ingestor Python | Solo escribir en `racks` |
| `grafana - lectura` | Grafana | Solo leer de `racks` |

Los permisos se asignan por el **ID** del bucket, por eso los tokens siguieron funcionando después de renombrarlo.

Los tokens **no** están en el repositorio. Pídanlos al equipo. Para verlos, dentro de la EC2 de InfluxDB: `influx auth list`.

### Formato de los datos (*line protocol*)

```
ambiente,dispositivo=prueba temperatura=24.5,humedad=60
└──┬───┘ └───────┬────────┘ └────────────┬────────────┘
measurement     tag                    fields
```

- **measurement**: el equivalente a una tabla.
- **tag**: una etiqueta para filtrar (por ejemplo, qué rack).
- **fields**: los valores medidos.
- Cada punto lleva fecha y hora. Si no se envía, la pone InfluxDB.

---

## 5. Cómo conectarse

### MQTT Explorer

| Campo | Valor |
|---|---|
| Protocol | `mqtt://` |
| Host | IP elástica |
| Port | `1883` |
| Encryption (tls) | Desactivado |
| Username / Password | `ingestor` / *(pedir al equipo)* |

### ESP32 (Arduino, PubSubClient)

```cpp
const char* BROKER = "<IP_ELASTICA>";
mqtt.setServer(BROKER, 1883);
mqtt.connect(id.c_str(), "esp32", "<CLAVE>");
```

### SSH (administración)

1. Learner Lab → **AWS Details** → **Download PEM** → guardar `labsuser.pem` en `C:\Users\<usuario>\.ssh\`.
2. Proteger la llave (solo la primera vez):
   ```powershell
   icacls labsuser.pem /inheritance:r /grant:r "$($env:USERNAME):R"
   ```
3. Crear el archivo `C:\Users\<usuario>\.ssh\config` (sin extensión: `notepad "$HOME\.ssh\config."`):
   ```
   Host broker
       HostName <IP_ELASTICA>
       User ubuntu
       IdentityFile ~/.ssh/labsuser.pem

   Host influx
       HostName <IP_PRIVADA_INFLUX>
       User ubuntu
       IdentityFile ~/.ssh/labsuser.pem
       ProxyJump broker
   ```
4. Conectarse:
   ```powershell
   ssh broker    # EC2 del bróker
   ssh influx    # EC2 de InfluxDB, saltando por el bróker (bastión)
   ```

`ProxyJump` usa la llave desde el PC para los dos saltos. **No copien `labsuser.pem` al bróker.**

**El puerto 22 del bróker solo acepta la IP de quien creó la regla.** Si otro dev necesita entrar, o si cambia su IP, hay que agregarla: EC2 → Grupos de seguridad → `iot-mqtt-mosquitto-manual-sg-broker` → *Editar reglas de entrada* → SSH → **Mi IP**.

### InfluxDB (desde la EC2 del bróker)

```bash
curl -s http://<IP_PRIVADA_INFLUX>:8086/health    # "status":"pass"
```

URL para el ingestor y Grafana: `http://<IP_PRIVADA_INFLUX>:8086`, org `uao`, bucket `racks`.

### Pruebas realizadas — Mosquitto (dentro de la EC2 del bróker)

```bash
sudo systemctl status mosquitto          # active (running)

# Sin credenciales → falla con "not authorised"
mosquitto_pub -h localhost -t "rack1/temperatura" -m "24.5"

# Con credenciales → funciona
mosquitto_pub -h localhost -u esp32 -P '<CLAVE>' -t "rack1/temperatura" -m "24.5"
```

Desde MQTT Explorer (con el usuario `ingestor`) se recibió el mensaje publicado, lo que confirma que el bróker es accesible desde internet.

Para ver errores de Mosquitto: `sudo journalctl -u mosquitto -n 20`.

### Pruebas realizadas — InfluxDB (desde la EC2 del bróker)

| Prueba | Resultado |
|---|---|
| `curl http://<IP_PRIVADA_INFLUX>:8086/health` | `"status":"pass"`: el bróker llega a InfluxDB por la red interna |
| Escribir un punto con el token del ingestor (`POST /api/v2/write`) | `204 No Content`: dato guardado |
| Leer con el token de Grafana (`POST /api/v2/query`, Flux) | Devuelve el dato escrito |
| Escribir con el token de Grafana | `401/403`: rechazado, el token solo lee |
| `ping google.com` desde la EC2 de InfluxDB | Sin respuesta: sin salida a internet |

```bash
# Escribir (token del ingestor)
curl -i -X POST "http://<IP_PRIVADA_INFLUX>:8086/api/v2/write?org=uao&bucket=racks&precision=s" \
  -H "Authorization: Token <TOKEN_INGESTOR>" \
  --data-binary "ambiente,dispositivo=prueba temperatura=24.5,humedad=60"

# Leer (token de Grafana)
curl -s -X POST "http://<IP_PRIVADA_INFLUX>:8086/api/v2/query?org=uao" \
  -H "Authorization: Token <TOKEN_GRAFANA>" \
  -H "Content-Type: application/vnd.flux" -H "Accept: application/csv" \
  --data 'from(bucket:"racks") |> range(start: -1h)'
```

---

## 6. Operación en el Learner Lab

- **Al terminar la sesión**, AWS **apaga** las dos EC2, pero no las borra. Al iniciar una sesión nueva (**Start Lab**) vuelven a encenderse, y Mosquitto e InfluxDB arrancan solos. Gracias a la IP elástica, **la IP pública del bróker no cambia**, y las IP privadas se conservan.
- **Las credenciales de la AWS CLI caducan** en cada sesión: AWS Details → AWS CLI → Show → pegarlas en `~/.aws/credentials`.
