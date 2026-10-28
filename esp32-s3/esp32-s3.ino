#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>
#include "secrets.h"  // WIFI_SSID, WIFI_PASS, BROKER, MQTT_USER, MQTT_PASS (no se sube a GitHub)

#define DHT_PIN  15
#define DHT_TIPO DHT22

const int   PUERTO = 1883;
const char* RACK   = "rack1";

String topicoTemp = String(RACK) + "/temperatura";
String topicoHume = String(RACK) + "/humedad";

WiFiClient wifi;
PubSubClient mqtt(wifi);
DHT dht(DHT_PIN, DHT_TIPO);
unsigned long ultimo = 0;

void conectarWiFi() {
  Serial.print("Conectando a Wi-Fi");
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
    Serial.print(".");
  }
  Serial.print(" Wi-Fi conectado, IP: ");
  Serial.println(WiFi.localIP());
}

void conectarBroker() {
  while (!mqtt.connected()) {
    String id = String("esp32-") + RACK + "-" + String(random(0xffff), HEX);
    Serial.printf("Conectando a %s como %s... ", BROKER, id.c_str());
    if (mqtt.connect(id.c_str(), MQTT_USER, MQTT_PASS)) {
      Serial.println("conectado");
    } else {
      // 4 = usuario/clave incorrectos, 5 = no autorizado, -2 = no hay conexión con el bróker
      Serial.printf("falló (estado %d). Reintento en 2 s\n", mqtt.state());
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  dht.begin();
  randomSeed(esp_random());
  conectarWiFi();
  mqtt.setServer(BROKER, PUERTO);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) conectarWiFi();
  if (!mqtt.connected()) conectarBroker();
  mqtt.loop();  // mantiene viva la conexión con el bróker

  if (millis() - ultimo > 5000) {
    ultimo = millis();

    float t = dht.readTemperature();
    float h = dht.readHumidity();

    if (isnan(t) || isnan(h)) {
      Serial.println("Error leyendo el DHT22");
      return;
    }

    String sT = String(t, 1);
    String sH = String(h, 1);

    mqtt.publish(topicoTemp.c_str(), sT.c_str());
    mqtt.publish(topicoHume.c_str(), sH.c_str());

    Serial.printf("Publicado %s °C en %s\n", sT.c_str(), topicoTemp.c_str());
    Serial.printf("Publicado %s %% en %s\n", sH.c_str(), topicoHume.c_str());
  }
}
