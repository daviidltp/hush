# Arquitectura

- Swift + SwiftUI, paquete SPM sin proyecto de Xcode. `./build-app.sh` compila, firma e instala en `~/Applications/Hush.app` (certificado en `SIGN_IDENTITY` o `.sign-identity`). `CONFIG=debug ./build-app.sh` deja una versión de pruebas en `build/` sin instalarla.
- `Sources/BovedaCore`: lógica (abrir/guardar, árbol, 2FA, generador, Touch ID). `Sources/Boveda`: interfaz.
- Formato KDBX: copia local de KDBXKit en `Vendor/KDBXKit` con un parche de fechas (ver [parche de fechas](../Vendor/KDBXKit/PARCHE-BOVEDA.md)). No actualizarla sin repetir el parche y los tests.
- El proyecto iOS se genera con `cd iOS && xcodegen generate` a partir de `project.yml`. `Hush.xcodeproj` queda fuera de Git. Comparte `BovedaCore` con el Mac, y el grupo `group.com.david.hush` comparte bases y Face ID con la extensión `iOS/HushAutoFill`.
