# xenia_installer

Instalador automatizado de **Xenia Canary** (build Windows) sobre
`umu-launcher` + `proton-cachyos`, con offload a GPU dedicada NVIDIA.

Pensado para CachyOS + niri + Noctalia, pero funciona en cualquier Arch
con Wayland.

## Por qué la build de Windows y no la nativa

El backend Vulkan nativo de Xenia sigue incompleto. La build de Windows
bajo Proton usa **D3D12** vía vkd3d-proton, que es el camino maduro y el
único que expone Rasterizer-Ordered Views — necesario para que Xenia
emule correctamente el framebuffer del Xenos.

## Requisitos

| Paquete | Para qué |
|---|---|
| `umu-launcher` | corre Proton sin cliente de Steam |
| `proton-cachyos-slr` | runtime Proton |
| `nvidia-prime` | `prime-run`, offload a la dGPU |
| `xwayland-satellite` | Xenia es X11; requerido bajo niri |
| `python3`, `curl`, `unzip` | |

## Uso

```bash
chmod +x install-xenia.sh
./install-xenia.sh
```

Opciones:

```
--root DIR          raíz de instalación (default: ~/Games/xenia)
--no-firstrun       no lanzar Xenia para generar el config
--skip-powerd       no tocar nvidia-powerd
--force-download    rebajar el .exe aunque ya exista
```

Idempotente: se puede volver a correr sin romper una instalación existente.

## Qué hace

1. Verifica dependencias del host y avisa si falta xwayland-satellite.
2. Activa `nvidia-powerd` (Dynamic Boost) si está inactivo.
3. Descarga el release Windows más reciente de `xenia-canary-releases`.
4. Genera `run-xenia.sh` con `prime-run` + `umu-run`.
5. Primer arranque con polling hasta que aparezca el config portable.
6. Aplica config: `d3d12`, escala 2x2, FXAA, vsync, idioma español.
7. Descarga los parches de *Banjo-Kazooie: Nuts & Bolts* (`4D5307ED`)
   y activa AF 16x + sin motion blur.
8. Registra el `.desktop` para el launcher.
9. Verifica todo releyendo del disco; sale con `exit 1` si algo falla.

## Notas de diseño

- **Sin `gamemoderun`**: umu corre dentro de pressure-vessel, que no
  comparte `/usr`. `libgamemodeauto.so` nunca entra al contenedor, así que
  gamemode no se aplica y solo ensucia el log.
- **`Exec` absoluto en el `.desktop`**: el campo no expande `$HOME` ni `~`,
  y greetd lanza el compositor vía PAM sin `~/.local/bin` en `PATH`.
- **Guarda contra Xenia corriendo** antes de editar el config: Xenia lo
  reescribe al salir y se comería las ediciones.
- **Escala 2x2, no 3x3**: 3x3 no cabe en 6 GB de VRAM.

## Aporta tu propio dump

El script no descarga juegos. Necesitas tu propio volcado del disco
(`.iso`, GoD/STFS, o `default.xex` extraído).

## Licencia

MIT
