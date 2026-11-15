# ZXUNZIP

`.zxunzip` is an esxDOS dot command for extracting ZX Spectrum files from ZIP archives
on the SD card. It searches the entire ZIP, including files inside directories.

## Install and run

Copy `bin/ZXUNZIP` to `/BIN/ZXUNZIP` on the esxDOS SD card. Run the command
directly from BASIC:

```text
.zxunzip GAMES.ZIP
```

Use the ZIP's esxDOS filename as it appears on the SD card. If the archive
contains one supported file, the command extracts it immediately. If there are
several, it lists the numbered paths inside the ZIP. Run the command again with
the number of the file you want:

```text
.zxunzip GAMES.ZIP 2
```

Use `.zxunzip -l GAMES.ZIP` to list supported files without extracting. Use
`.zxunzip -h` for on-screen help. 

The output goes into the current SD directory as an 8.3 filename. For example,
`Games/Side A/Example Game.tap` becomes `EXAMPLE_.TAP`. If that name is already
in use, the command tries `EXAMPLE1.TAP`, then `EXAMPLE2.TAP`. The ZIP is kept.
Press **CAPS SHIFT + SPACE** to cancel. The command checks the extracted size
and CRC-32 and removes incomplete output on cancellation or error if the SD card
allows deletion.

With the normal BASIC memory layout, the command checks and borrows
`$7000–$EFFF` for the 32 KiB DEFLATE history. It leaves RAMTOP as it was, so
you can return to `.ZXBBS` after extracting. Keep machine code and data you
want to retain outside the borrowed range.

## Supported files

`.tzx`, `.tap`, `.mdv`, `.z80`, `.sna`, `.dsk`, `.trd` and `.scr`.
Extensions are matched regardless of case. These are extraction formats.
Opening or mounting each extracted file depends on the Spectrum setup.

This version supports standard single-volume ZIP archives using Store or
DEFLATE, including archives with data descriptors. ZIP64 archives, encrypted
files, split archives and other compression methods are outside the supported
formats. The command lists member paths up to 512 bytes.

## Build and test

Run the build from the source directory with sjasmplus:

```sh
cd src
sjasmplus ZXUNZIP.asm --sym=../bin/ZXUNZIP.sym
cd ..
python -m pip install z80
python -m unittest discover -s tests -v
```
## References

[ZIP format specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT) ·
[DEFLATE specification](https://www.rfc-editor.org/rfc/rfc1951) ·
[esxDOS](https://www.esxdos.org/)

This dot command was crafted with the help of AI (**ChatGPT**)
