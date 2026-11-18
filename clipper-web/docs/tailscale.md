# Llegar al iMac desde la calle, con dirección fija (Tailscale)

El motor escucha solo en `127.0.0.1:8000`, o sea, solo dentro del propio iMac. Esto lo
saca a internet con una **dirección que no cambia nunca**, con certificado de verdad,
**sin dominio propio** y **sin abrir ningún puerto del router**.

Es la alternativa al túnel de Cloudflare. La diferencia que importa:

| | Túnel rápido de Cloudflare | Túnel con dominio | Tailscale |
|---|---|---|---|
| Dirección | cambia al reabrirse | fija | **fija** |
| Hace falta dominio | no | **sí** | no |
| Quién puede entrar | **cualquiera que sepa la dirección** | cualquiera | **solo tus aparatos** |
| En el iPhone | nada | nada | la app de Tailscale |

Lo que lo hace distinto es la última fila: con un túnel, la dirección es lo único que
protege tu motor. Con Tailscale, aunque alguien la adivine, sin estar en tu cuenta no
llega. A cambio, cada aparato tuyo tiene que llevar la app.

## Montarlo

```bash
brew install --cask tailscale        # o https://tailscale.com/download/mac
open -a Tailscale                    # entra con tu cuenta
cd clipper-web && ./scripts/tailscale.sh
```

El script comprueba que el motor esté encendido, lo saca por HTTPS y te enseña la
dirección. También la deja escrita en `~/Content-Scheduler-direccion.txt`.

Queda puesto para siempre: sobrevive a reinicios sin dejar ventanas abiertas.

## Si falla

Casi siempre es porque faltan dos interruptores de tu cuenta, que vienen apagados:

1. [login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns)
2. Enciende **MagicDNS**
3. En **HTTPS Certificates**, dale a **Enable HTTPS**
4. Corre el script otra vez

## En el iPhone

1. Instala **Tailscale** de la App Store y entra con la misma cuenta.
2. En Content Scheduler → **Ajustes** → **Servidor del motor**, pon la dirección
   `https://…ts.net` que te dio el script.

Se conecta sola a partir de ahí, estés donde estés.

## Quitarlo

```bash
./scripts/tailscale.sh --quitar
```

Tus aparatos siguen conectados entre sí; solo deja de publicarse el motor.

## Y ojo con esto

`./scripts/siempre-activo.sh` abre un túnel de Cloudflare en bucle. Si detecta que
Tailscale ya está dando la dirección fija, no lo abre: si no, la pisaría con una que
cambia a cada rato. No hay que hacer nada, pero conviene saberlo.
