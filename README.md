# PuenteWiFi

App de iPhone para usar redes Wi-Fi públicas con portal de términos cuando el portal no aparece, en especial con Nintendo Switch y Roku.

## Lo que iOS no permite

Una app de iPhone no puede crear una red Wi-Fi, activar el Hotspot personal ni enviarle el Wi-Fi público. PuenteWiFi resuelve el problema por otras vías.

## Qué hace

1. **Portal en el iPhone:** lo detecta y lo abre dentro de la app.
2. **QR universal:** abre `http://neverssl.com` en otro dispositivo con navegador, para que aparezca su propio portal.
3. **Aceptar por MAC:** abre el portal con la MAC de otro dispositivo. Solo funciona si el portal lleva la MAC en su enlace.
4. **Proxy con contraseña:** comparte la conexión del iPhone con dispositivos que admiten proxy.

## Nintendo Switch

Prueba en este orden:

1. **Portal de la consola:** conéctala a la red y haz la prueba de conexión. Si la red lo pide, la Switch ofrece abrir su propio navegador.
2. **Aceptar por MAC:** copia la MAC de Configuración de la consola > Internet y usa el paso 3 de la app.
3. **Proxy:** en la Switch, ve a Internet > tu red > Cambiar ajustes > Ajustes de proxy. Actívalo y escribe la dirección, el puerto, el usuario y la contraseña que muestra la app.

Por proxy pasa tráfico web, como la eShop y las descargas. El juego en línea directo suele usar UDP y no pasa por este proxy.

## Roku

Roku no tiene navegador ni ajustes de proxy, así que **el proxy no le sirve**. Prueba en este orden:

1. **Modo hotel o residencia del Roku:** al configurar la red inalámbrica, elige la opción para hoteles o residencias de estudiantes y sigue los pasos con el iPhone. No está disponible en todos los modelos.
2. **Aceptar por MAC:** copia la MAC de Ajustes > Red > Acerca de y usa el paso 3 de la app.
3. **Router de viaje:** si nada de lo anterior funciona, consulta la siguiente sección.

## Si necesitas un hotspot de verdad

Un **router de viaje** con modo repetidor (por ejemplo, GL.iNet) hace lo que pediste originalmente. Se conecta al Wi-Fi público, tú aceptas el portal una vez y la Switch y el Roku se conectan al router como a cualquier red. Con este método también funciona el juego en línea, salvo que la red lo bloquee.

## Límites de la app

- El proxy necesita que los dispositivos se vean entre sí. Muchas redes públicas lo impiden con el "aislamiento de clientes", y entonces no funciona.
- iOS pausa la app en segundo plano, así que debe quedarse abierta y en pantalla.
- Si la red autoriza por MAC y limita el tiempo, puede que tengas que aceptar de nuevo.
- Respeta los términos de la red: algunos solo permiten un dispositivo por persona.

## Instalación sin Xcode (recomendada para ti)

No hace falta Xcode en tu Mac. La app se compila en la nube y se instala con una herramienta de *sideload* y tu Apple ID gratuito.

1. **Sube el proyecto a GitHub.** Crea un repositorio y sube esta carpeta. En la pestaña **Actions**, ejecuta el flujo **Build IPA** (botón *Run workflow*).
2. **Descarga el IPA.** Al terminar, en esa ejecución verás el artefacto `PuenteWiFi-unsigned-ipa`. Descárgalo y descomprímelo: dentro está `PuenteWiFi-unsigned.ipa`. Está **sin firmar** a propósito.
3. **Fírmalo e instálalo en el iPhone.** Usa una de estas apps de Mac, que firman con tu Apple ID gratuito:
   - **Sideloadly** (sideloadly.io): conecta el iPhone, arrastra el `.ipa`, escribe tu Apple ID y pulsa *Start*.
   - **AltStore / SideStore**: instala AltServer en la Mac y añade el `.ipa` desde la app AltStore del iPhone.
4. En el iPhone, confía en tu perfil en **Ajustes > General > VPN y gestión de dispositivos**, activa el **Modo desarrollador** si lo pide y permite el acceso a la **red local**.

Con un Apple ID gratuito la app caduca a los 7 días; vuelve a firmarla con la misma herramienta para renovarla. AltStore/SideStore pueden renovarla solas.

## Instalación con Xcode

Si en algún momento tienes acceso a una Mac con Xcode (gratis en la App Store) y un Apple ID:

### Opción simple: desde Xcode

1. Abre `PuenteWiFi.xcodeproj`.
2. En el target, ve a **Signing & Capabilities** y elige tu equipo en **Team**. Si el Bundle Identifier da error, cámbialo por otro único.
3. Conecta el iPhone, selecciónalo arriba y pulsa **Run**.
4. Si iOS lo pide, activa **Ajustes > Privacidad y seguridad > Modo desarrollador**.
5. Confía en tu perfil en **Ajustes > General > VPN y gestión de dispositivos**.
6. Permite el acceso a la **red local** cuando la app lo pida.

Con una cuenta gratuita, la app caduca a los 7 días y hay que volver a instalarla desde Xcode. Con Apple Developer Program dura hasta un año.

### Opción IPA

```bash
./build_ipa.sh TU_TEAM_ID
```

El archivo queda en `build/ipa/PuenteWiFi.ipa` y solo se instala en iPhones registrados en tu cuenta. Con el iPhone conectado:

```bash
xcrun devicectl device install app --device NOMBRE_DEL_IPHONE build/ipa/PuenteWiFi.ipa
```

Si la exportación falla con una cuenta gratuita, usa la opción de Xcode.

## Pruebas

```bash
./Tests/run_smoke.sh
```

Compila el proxy para macOS y lo prueba con `curl`. No sustituye una prueba en un iPhone real.
