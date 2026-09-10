# Readable GRUB menu on a HiDPI (3840x2400) display

On a 14" 3840x2400 panel the default GRUB font is unreadably small. Fix it by
generating a larger font from a Nerd Font and pointing GRUB at it.

## 1. Install a monospace Nerd Font

```sh
sudo pacman -S ttf-jetbrains-mono-nerd
```

Any `*NerdFontMono-*.ttf` works. Use the **Mono** variant so all glyphs share
one cell width.

## 2. Generate the GRUB font

```sh
sudo grub-mkfont -s 32 \
  -r 0x20-0x7F,0xA0-0x2FF,0x2500-0x25FF \
  -o /boot/grub/fonts/JetBrainsMonoNF32.pf2 \
  /usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf
```

- `-s 32` — point size. Try 28–40 depending on preference.
- `-r ...` — restricts glyphs to ASCII, Latin-1/Extended, and box-drawing
  chars. Keeps the `.pf2` small and menu load fast.
- `-o` — output path; `/boot/grub/fonts/` is where GRUB looks by default.

## 3. Configure GRUB

Edit `/etc/default/grub`:

```sh
GRUB_FONT=/boot/grub/fonts/JetBrainsMonoNF32.pf2
```

Optional, if you also want to fix the resolution:

```sh
GRUB_GFXMODE=3840x2400
GRUB_GFXPAYLOAD_LINUX=keep
```

## 4. Regenerate the config

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Reboot to verify.

## Troubleshooting

- **Font not applied**: confirm `/boot/grub/grub.cfg` contains
  `loadfont /boot/grub/fonts/JetBrainsMonoNF32.pf2` (path may be prefixed with
  `($root)`). If `/boot` is a separate partition, the path GRUB sees may differ.
- **Text too thin**: regenerate with the `-Medium` or `-SemiBold` TTF.
- **Unsupported resolution**: at the GRUB menu press `c`, run `videoinfo`, and
  only use listed modes.
- **Need icons in menu titles**: add `0xE000-0xF8FF,0xF0000-0xF1AF0` to the
  `-r` range.
