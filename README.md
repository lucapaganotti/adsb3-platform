# ADS-B Platform

Strumenti di generazione delle immagini ADS-B per Raspberry Pi.

## Layout immagine

| Partizione | FS    | Dimensione |
|------------|-------|------------|
| boot       | FAT32 | 1 GB       |
| rootfs     | EXT4  | 6 GB       |
| adsbdata   | EXT4  | restante   |

## Distribuzioni supportate

- Stretch
- Bookworm

## Utente applicativo

radair (UID/GID 1000)

## Output

radair-adsb-\${DISTRO}-\${VERSION}.\${BUILD}-\${DATE}.img.xz
