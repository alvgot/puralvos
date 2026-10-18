# ISO size: why the image grew, and what was done about it

The question that produced this document: *why is PuralvOS bigger than the
Ubuntu Studio ISO it is built from?* The short answer is that most of the
first growth was build residue rather than the product, and removing it made
the 0843 build smaller than stock.

**The current build is bigger again, and this file says why rather than
pretending otherwise.** The 2026-10-18 20:45 Live image is 7 348 336 640 bytes,
221 MB *above* stock. It carries the realtime kernel's modules, TONE3000 in
four plugin formats, and — the item still to remove — a 120 MB installer snap
that the Live build masks and therefore never uses. See
[the current build](#the-current-build-2026-10-18) below. Everything above
that section describes the 0843 build and is kept as the record of the
residue work.

All figures below are the files on disk, in bytes, measured on 2026-10-18.

| image | bytes | GiB |
| --- | ---: | ---: |
| Ubuntu Studio 26.04.1 stock | 7 127 195 648 | 6.64 |
| PuralvOS, first bootable build (0721/0757) | 7 751 788 544 | 7.22 |
| PuralvOS, final (0843) | 7 031 140 352 | 6.55 |

Final sha256: `805a8f1ced8a734238844c2c8e395857a28951f933084242ff3d6f62153c11fa`.

The final image is **96 055 296 bytes (92 MiB) smaller than stock**, and
**720 648 192 bytes (687 MiB) smaller than the first working build**.

## Where the 624 MB of growth came from

Two files held all of it:

| path in the ISO | stock | first build | delta |
| --- | ---: | ---: | ---: |
| `casper/minimal.standard.live.squashfs` | 160 600 064 | 676 261 888 | **+515 661 824** |
| `casper/initrd.realtime` | — | 100 586 760 | **+100 586 760** |
| `casper/initrd` | 103 029 402 | 103 029 402 | 0 |
| GRUB EFI modules and `/efi.img` | — | ~7.3 MB | +7.3 MB |

Inside the top layer, the growth was not the product:

| content | uncompressed | shipped in the layer |
| --- | ---: | ---: |
| `linux-modules-...-realtime` .deb left in `/var/cache/apt/archives` | 168.7 MB | ~169 MB (a .deb is already compressed; squashfs cannot shrink it) |
| the same modules installed in `/usr/lib/modules` | 170 MB | ~170 MB (`.ko.zst` is already compressed) |
| APT binary caches (`pkgcache.bin`, `srcpkgcache.bin`) | 110.2 MB | ~25 MB |
| generated RT initrd in `/boot` of the rootfs | 100.6 MB | ~100 MB |
| installer snap stored twice instead of hardlinked | 241.7 MB | ~120.8 MB |
| TONE3000 (standalone + VST3 + CLAP + LV2) | 96 MB | ~45 MB |
| RT kernel `vmlinuz` + `System.map` + `config` | 28 MB | ~28 MB |
| APT lists regenerated in the chroot | 26 MB | ~8 MB |

Two structural differences made it worse than the sum suggests:

1. **The stock image does not carry an initrd in its root filesystem.**
   `/casper/initrd` on the ISO is the only copy; `/boot/initrd.img` is a
   dangling symlink. The build generated an RT initrd, copied it to
   `casper/initrd.realtime`, and left the original inside the squashfs — so
   the ISO paid for it twice, and additionally kept the stock generic initrd
   plus the RT one, because GRUB loaded both.
2. **The stock image hardlinks the installer snap** between
   `/var/lib/snapd/seed/snaps` and `/var/lib/snapd/snaps`; mksquashfs stores
   a hardlink pair once. Unpacking the layers into the build tree broke the
   link into two 120.8 MB files, and both were staged into the new top layer.

## The fixes

### 1. One initrd, not three copies of one

The stock `/casper/initrd` used to be concatenated with
`/casper/initrd.realtime` on the kernel command line. The RT initrd is a
complete initramfs for the shipped kernel and carries its own early microcode
(`kernel/x86/microcode/`), which was the only reason to keep casper's copy.
The build now:

- copies `initrd.img-$RTVER` over `/casper/initrd`;
- deletes `casper/initrd.realtime` and the GRUB reference to it;
- checks the initrd for `kernel/x86/microcode/` and warns if a future kernel
  loses it.

Saves 100.6 MB on the ISO, plus the 100.6 MB copy inside the layer (next).

### 2. No initrd in the live root filesystem

The generated `/boot/initrd.img-7.0.0-38-realtime` was removed after it was
copied to the ISO, mirroring the stock layout. The symlink left behind dangles
exactly as stock's does; `update-initramfs` writes the file back on a kernel
upgrade. Saves 100.6 MB in the squashfs.

### 3. Package-manager residue out

`/var/cache/apt/archives/*.deb` (the modules download) and the binary caches
are deleted after the chroot work. The stock image has neither; a live system
regenerates the caches on first use. Saves ~194 MB in the layer.

The APT **lists** are different and were put back: the stock image ships them
inside `minimal.squashfs`, and the live session and installer use them. The
chroot's regenerated lists were replaced with the stock files, timestamps
included, so the diff does not stage a redundant second copy.

### 4. The installer snap is hardlinked again

After staging, every `.snap` present both under `seed/snaps` and `snaps` is
size-checked and `cmp`-verified, then re-linked with `ln -f`. The 120.8 MB
installer snap is stored once, as in the stock image. Saves 120.8 MB.

### 5. Hidden content removed from the base layer

The biggest single saving is not something the image shows: the stock ISO
carries files that its own top layer whiteouts. The generic kernel is the
clearest case — PuralvOS ships the realtime kernel, and the generic modules
were already hidden at runtime — but it is not the only one.

`minimal.squashfs` was unpacked and every path in `gone.list` (the paths the
final image hides, i.e. whiteouted) was removed from it, along with the
generic kernel's modules, image, `System.map` and `config`. 616 MB
uncompressed left the layer; the xz image shrank from 4 112 433 152 to
3 795 501 056 bytes, **saving 317 MB**, with no change to the live view: every
removed path was already invisible.

The same check was run against `minimal.standard.squashfs`: it hides nothing,
so it was left untouched.

## Result

| ISO path | stock | final | delta |
| --- | ---: | ---: | ---: |
| `casper/minimal.squashfs` | 4 112 433 152 | 3 795 501 056 | −316 932 096 |
| `casper/minimal.standard.squashfs` | 2 162 012 160 | 2 162 012 160 | 0 |
| `casper/minimal.standard.live.squashfs` | 160 600 064 | 375 619 584 | +215 019 520 |
| `casper/initrd` | 103 029 402 | 100 586 760 | −2 442 642 |
| `casper/initrd.realtime` | — | — | −100 586 760 |
| everything else | | | +7.3 MB (GRUB 2.12 EFI modules) |
| **total** | **7 127 195 648** | **7 031 140 352** | **−96 055 296** |

The remaining +215 MB in the top layer is the product, not residue:

- ~170 MB: the realtime kernel's modules (`.ko.zst`, incompressible), which
  replace the generic modules now removed from the base layer;
- ~45 MB: TONE3000 in all four formats a DAW or standalone host may load;
- ~28 MB: the RT kernel image and `System.map`;
- ~120.8 MB once: the installer snap, hardlinked as stock does.

The listed top-layer numbers overlap with the stock layer's own content
(wallpapers, presage data, themes), so the +215 MB is the net of additions,
removals and carried-over files, not a sum of the lines above.

## What was deliberately not done

- **Stripping TONE3000.** The project rule is stock packages and configuration
  only; modifying upstream binaries to save a few MB crosses it.
- **Removing the APT lists** from the base layer. They compress to roughly
  25 MB, and the installer and live session may need the package metadata that
  stock ships. Not worth the risk for 25 MB.
- **Dropping `System.map`.** 10.6 MB, present in stock images, used by
  debugging tools. Kept for parity.
- **Rebuilding the standard layer.** It contains no whiteouted content; there
  was nothing to gain.

## Reproducing the two large steps

```sh
# 1. strip hidden content from the base layer
unsquashfs -processors 32 -d /tmp/minimal-root iso/casper/minimal.squashfs
( cd /tmp/minimal-root && while IFS= read -r p; do rm -rf -- "$p"; done < gone.list )
mksquashfs /tmp/minimal-root iso/casper/minimal.squashfs \
    -noappend -comp xz -b 131072 -xattrs -processors 32

# 2. re-author the ISO (top layer, initrd, GRUB, packages docs)
PURALVOS_DIAG=1 tools/build-live.sh --keep --author-only
```

`gone.list` is produced by the build itself (the rsync diff between the
read-only union and the merged tree); the loop above is safe by construction:
it removes only paths the final image already hides.


## The current build (2026-10-18)

The ISO that boots in about 50 seconds on the T460s is the Live build, and it
is larger than stock:

| image | bytes | GiB |
| --- | ---: | ---: |
| Ubuntu Studio 26.04.1 stock | 7 127 195 648 | 6.64 |
| PuralvOS Live (current, 2045) | 7 348 336 640 | 6.84 |

The top layer is 586 MB uncompressed / 358 MB in the ISO. Its largest files:

| file | bytes | needed? |
| --- | ---: | --- |
| `var/lib/snapd/{seed/,}snaps/ubuntu-desktop-bootstrap_589.snap` | 120 856 576 (one inode, hardlinked) | **no in the Live build** — snapd and the installer are masked, so nothing reads it. This is the 120 MB duplicate the layer merge created: the same snap is already in `minimal.squashfs`, and the diff stages it again because the unpack broke the hardlink with the seed copy |
| `usr/lib/{vst3,lv2,clap}/TONE3000*` + `usr/bin/TONE3000` | ~96 MB | yes — the NAM player is part of the audio set |
| `boot/vmlinuz` + `System.map` for 7.0.0-38-realtime | ~28 MB | yes |
| `usr/share/presage/database_es.db` | 24 MB | no — Spanish predictive-text database inherited from the base |

**Identified saving, not yet taken:** deleting the snap from the working copy
in the Live branch would whiteout the base copy (a tombstone costs a few
bytes) and drop the staged duplicate from the top layer — about 120 MB off the
ISO. It is one `rm` in `tools/build-live.sh` inside the `PURALVOS_INSTALLER=0`
branch, plus a rebuild and a boot check. It is recorded here rather than done
in the documentation pass so the change gets its own test.
