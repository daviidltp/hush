# Hush

Gestor de contraseñas para macOS sobre archivos KDBX (compatibles con otras apps KeePass, también en el móvil).

- Swift + SwiftUI, paquete SPM sin proyecto de Xcode. `./build-app.sh` compila, firma e instala en `~/Applications/Hush.app` (certificado en `SIGN_IDENTITY` o `.sign-identity`). `CONFIG=debug ./build-app.sh` deja una versión de pruebas en `build/` sin instalarla.
- `Sources/BovedaCore`: lógica (abrir/guardar, árbol, 2FA, generador, Touch ID). `Sources/Boveda`: interfaz.
- Formato KDBX: copia local de KDBXKit en `Vendor/KDBXKit` con un parche de fechas (ver `PARCHE-BOVEDA.md`). No actualizarla sin repetir el parche y los tests.
- Tests: `swift test`. Incluyen comprobaciones contra `keepassxc-cli` (KeePassXC instalado).
- Diseño: tokens en `Theme.swift`. Úsalos siempre.
- Seguridad: nunca escribir un archivo sin verificar que se reabre; copia previa en Application Support; no sobrescribir si el archivo cambió fuera.
- Probar la interfaz con una base de prueba (por ejemplo `~/Desktop/demo-boveda/Demo.kdbx`, contraseña `demo1234`), lanzando la versión debug con `open -n --env BOVEDA_TEST_PASSWORD=demo1234 build/Hush.app`. Nunca con una base real.
- En la interfaz no se nombran otros gestores de contraseñas.
