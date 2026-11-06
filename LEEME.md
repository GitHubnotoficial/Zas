# Zas

Capturas y video para Mac: seleccionas, y ya está copiado para pegar.

Requiere macOS 13 (Ventura) o más nuevo. Funciona en Apple Silicon e Intel. Todo se queda en tu Mac: nada se envía a internet.

## Instalar

Abre Terminal, pega esto y pulsa Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/GitHubnotoficial/Zas/main/instalar-rapido.sh | bash
```

No hace falta instalar nada más. Para actualizar, corre el mismo comando.

La primera vez:

1. En la ventana de Zas, pulsa **Abrir Ajustes** y activa Zas en **Grabación de pantalla**.
2. Vuelve a Zas y pulsa **Ya lo activé, reiniciar Zas**.
3. En macOS 15 o más nuevo, el sistema muestra su propio aviso en la primera captura y puede repetirlo cada cierto tiempo. Pulsa **Permitir**.

## Atajos

| Atajo | Acción |
| --- | --- |
| ⇧⌘2 | Capturar: arrastra para un área o haz clic en una ventana |
| ⇧⌘1 | Capturar la pantalla donde está el cursor |
| ⇧⌘7 | Copiar el texto de un área |
| ⇧⌘6 | Empezar o detener una grabación de video |
| Esc o clic derecho | Cancelar |

Puedes cambiarlos en **Ajustes**, desde el icono de Zas en la barra de menú.

## Después de capturar

- La imagen queda copiada: pégala con ⌘V.
- Aparece una miniatura en la esquina. Las capturas seguidas se apilan, hasta cuatro.
- Arrastra una miniatura para soltar el archivo en otra app.
- Pasa el cursor por encima para anotar, fijar en pantalla o verla en Finder.
- El archivo queda guardado en `Imágenes/Zas`, o en la carpeta que elijas en Ajustes.

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

⌘Z deshace y ⇧⌘Z rehace. Mayúsculas alinea las flechas y hace cuadros y círculos perfectos. Supr borra la marca seleccionada y Esc cierra sin guardar.

## Video

Se graba en MP4 y queda copiado como archivo. Para detenerlo, usa ⇧⌘6 o haz clic en el contador de la barra de menú. Para grabar tu voz, activa el micrófono en Ajustes; requiere macOS 15 o más nuevo.

## Compilar desde el código

```bash
bash instalar.sh
```

Requiere las herramientas de desarrollo de Apple. Una versión compilada en tu Mac vuelve a pedir los permisos en cada instalación, porque no lleva la firma de Zas.
