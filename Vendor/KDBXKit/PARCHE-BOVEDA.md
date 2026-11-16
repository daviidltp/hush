# Copia local de KDBXKit

Origen: https://github.com/shadone/KDBXKit, commit `e9b8839f1226b82665e1e4b7f12f13635d189deb` (licencia BSD-2-Clause, ver LICENSE).

Cambio de Bóveda: `Sources/KDBXKit/Extensions/Date+dotnet.swift` calculaba la fecha de referencia de .NET
con el calendario de Foundation, que es juliano antes de 1582. Eso desplazaba 2 días todas las fechas
al leer y al escribir, y KeePassXC/KeePassium veían las fechas mal. Ahora usa la constante exacta.

Segundo cambio: `Sources/KDBXKit/KDBX/CustomDataItem.swift` tiene un inicializador público
para que Bóveda pueda guardar datos propios en las entradas (por ejemplo, el tipo: tarjeta o nota).

Tercer cambio: `Package.swift` compila Argon2 (`Sources/CArgon2`) con `-O3` en release en vez de `-Os`.
Argon2 es casi todo el tiempo de desbloqueo y así va un 15 % más rápido.

Cuarto cambio: `Sources/CArgon2/src/thread.c` crea los hilos de Argon2 con prioridad (QoS) explícita.
En macOS un hilo nuevo no hereda la de quien lo crea y, con el Mac ocupado, el descifrado iba a núcleos lentos
(+0,4–1 s). Si quien llama es user-initiated o más, los hilos van a user-interactive; si no, heredan.
