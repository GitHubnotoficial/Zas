# Zas

Capturas y video para Mac: seleccionas, y ya está copiado para pegar.

Requiere macOS 13 (Ventura) o más nuevo. Funciona en Apple Silicon e Intel. Todo se queda en tu Mac: nada se envía a internet.

## Instalar

Abre Terminal, pega esto y pulsa Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/GitHubnotoficial/Zas/main/instalar-rapido.sh | bash
```

No hace falta instalar nada más. Para actualizar, corre el mismo comando; también lo puedes copiar desde **Ajustes**. Zas no se actualiza sola, porque no se conecta a internet.

Zas queda activada para abrirse al iniciar sesión. Puedes apagarlo en **Ajustes**.

La primera vez:

1. En la ventana de Zas, pulsa **Abrir Ajustes** y activa Zas en **Grabación de pantalla**.
2. Zas se reinicia sola al detectar el permiso. Si no lo hace, pulsa **Ya lo activé, reiniciar Zas**.
3. En macOS 15 o más nuevo, el sistema muestra su propio aviso en la primera captura y puede repetirlo cada cierto tiempo. Pulsa **Permitir**.

## Atajos

| Atajo | Acción |
| --- | --- |
| ⇧⌘2 | Capturar: arrastra para un área o haz clic en una ventana |
| ⇧⌘1 | Capturar la pantalla donde está el cursor |
| ⇧⌘8 | Elegir un área y capturarla 3 segundos después, para abrir antes un menú o un aviso |
| ⇧⌘7 | Copiar el texto de un área |
| ⇧⌘6 | Empezar o detener una grabación de video |
| Esc, clic derecho o repetir el atajo | Cancelar |

Puedes cambiarlos en **Ajustes**, desde el icono de Zas en la barra de menú.

## Con Claude

| Dónde | Imagen | Video |
| --- | --- | --- |
| Claude Code en Terminal | **Ctrl+V**, no ⌘V (en iTerm2 también sirve ⌘V) | Ctrl+V pega el resumen |
| Por ruta, para cualquier agente | Botón de terminal en la miniatura, y pega la ruta en el mensaje | Igual, sobre el resumen |
| Arrastrar | Arrastra la miniatura a la ventana de Claude | Arrastra la miniatura del resumen |

Claude no suele poder ver un video. Por eso, al terminar una grabación Zas copia una **imagen resumen** con hasta doce momentos y su minuto. El MP4 sigue guardado y se puede copiar desde su miniatura. En **Ajustes** puedes hacer que siempre se copie el video.

## Después de capturar

- La imagen queda copiada: pégala con ⌘V.
- Aparece una miniatura en la esquina. Las capturas seguidas se apilan, hasta cuatro.
- Arrastra una miniatura para soltar el archivo en otra app.
- Si ya se cerró, búscala en **Capturas recientes**, en el menú de Zas.
- Pasa el cursor por encima para copiarla otra vez, copiar su ruta, anotar, fijar en pantalla o verla en Finder. "Copiado" marca la que está en el portapapeles.
- El archivo queda guardado en `Imágenes/Zas`, o en la carpeta que elijas en Ajustes. Si apagas **Guardar una copia de cada captura**, las imágenes se borran al cerrar Zas; los videos siempre se guardan.

## Editor

Haz clic en una miniatura para abrirlo. Enter copia el resultado y cierra.

| Tecla | Herramienta |
| --- | --- |
| V | Mover o borrar una marca |
| A | Flecha |
| R | Cuadro |
| O | Círculo |
| H | Resaltar |
| P | Lápiz |
| T | Texto |
| N | Número |
| X | Pixelar |
| C | Recortar |

⌘Z deshace y ⇧⌘Z rehace. Mayúsculas alinea las flechas y hace cuadros y círculos perfectos. Supr borra la marca seleccionada. Esc cierra el editor y, si dibujaste algo, pregunta antes de perderlo.

## Video

Se graba en MP4. Al terminar queda copiado un resumen en imágenes para pegar en Claude. Para detenerlo, usa ⇧⌘6 o haz clic en el contador de la barra de menú. Para grabar tu voz, activa el micrófono en Ajustes; requiere macOS 15 o más nuevo.

## Desinstalar

Cierra Zas desde su menú, borra `Zas` de Aplicaciones y corre esto para quitar sus permisos y ajustes. Tus capturas se quedan en `Imágenes/Zas`.

```bash
tccutil reset All local.zas.app; defaults delete local.zas.app
```

## Compilar desde el código

```bash
bash instalar.sh
```

Requiere las herramientas de desarrollo de Apple. Una versión compilada en tu Mac vuelve a pedir los permisos en cada instalación, porque no lleva la firma de Zas.
