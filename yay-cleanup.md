# Cleaning Orphaned Packages and Make Dependencies with yay

Over time, Arch accumulates packages that are no longer needed: orphaned
dependencies left behind after removing a package, and make dependencies
pulled in while building AUR packages. This guide covers how to clean them up.

## Quick cleanup (yay built-in)

```bash
yay -Yc
```

Removes all packages that are no longer required by any installed package
(orphans and leftover make dependencies).

## Manual method (pacman-style)

List orphans (installed as dependencies, no longer required by anything):

```bash
yay -Qdtq
```

Remove them along with their config files and now-unneeded dependencies:

```bash
yay -Rns $(yay -Qdtq)
```

Include optional dependencies that are no longer needed:

```bash
yay -Qdttq
```

Note: if there are no orphans, `yay -Qdtq` prints nothing and `yay -Rns`
fails with "no targets specified". That is expected and harmless.

## Clean the package cache

```bash
yay -Sc    # remove uninstalled packages from cache, keep installed versions
yay -Scc   # remove everything from the cache, including AUR build dirs
```

## Prevent leftover make dependencies

Configure yay to automatically remove make dependencies after building:

```bash
yay -Y --removemake --save
```

This writes the setting to `~/.config/yay/config.json` so it applies to all
future AUR builds.

## Summary

| Command                    | Purpose                                   |
| -------------------------- | ----------------------------------------- |
| `yay -Yc`                  | Remove orphans and unneeded make deps     |
| `yay -Qdtq`                | List orphaned packages                    |
| `yay -Rns $(yay -Qdtq)`    | Remove orphans recursively with configs   |
| `yay -Sc` / `yay -Scc`     | Clean package cache                       |
| `yay -Y --removemake --save` | Auto-remove make deps after AUR builds  |
