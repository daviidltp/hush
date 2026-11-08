# Copia local de KDBXKit

Origen: https://github.com/shadone/KDBXKit, commit `e9b8839f1226b82665e1e4b7f12f13635d189deb` (licencia BSD-2-Clause, ver LICENSE).

Cambio de Bóveda: `Sources/KDBXKit/Extensions/Date+dotnet.swift` calculaba la fecha de referencia de .NET
con el calendario de Foundation, que es juliano antes de 1582. Eso desplazaba 2 días todas las fechas
al leer y al escribir, y KeePassXC/KeePassium veían las fechas mal. Ahora usa la constante exacta.

Segundo cambio: `Sources/KDBXKit/KDBX/CustomDataItem.swift` tiene un inicializador público
para que Bóveda pueda guardar datos propios en las entradas (por ejemplo, el tipo: tarjeta o nota).
