# Pruebas

- Tests: `swift test`. Incluyen comprobaciones contra `keepassxc-cli` (KeePassXC instalado).
- Crea una base con una contraseña desechable para la interfaz (por ejemplo `~/Desktop/demo-boveda/Demo.kdbx`, con la contraseña en `~/Desktop/demo-boveda/password.txt`, fuera del repo), lanzando la versión debug con `open -g -n --env BOVEDA_TEST_PASSWORD="$(cat ~/Desktop/demo-boveda/password.txt)" build/Hush.app`. Nunca con una base real.
- En iPhone, genera primero el proyecto con XcodeGen y ejecuta `xcodebuild test -scheme Hush` en el simulador. Para probar la interfaz con la base demo, cópiala a «En mi iPhone» y usa `--launch-args -HushTestPassword "$(cat ~/Desktop/demo-boveda/password.txt)"` solo en debug.
