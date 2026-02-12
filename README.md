# Clipz

> Wayland Clipboard history (`wlr-data-control-unstable-v1`)

Repo: https://codeberg.org/0x52534B/clipz  
Mirror: https://github.com/revathskumar/clipz


### Usage

```
clipz print  : print the selection history
clipz daemon : start listening to clipboard selection
```

### Build

```sh
PKG_CONFIG=/usr/bin/pkg-config zig build
```

```sh
PKG_CONFIG=/usr/bin/pkg-config zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall --summary all
```

### Debug

#### Memory leaks

```sh
valgrind -s --leak-check=full --show-leak-kinds=all ./zig-out/bin/clipz daemon
```


### License

[MIT](LICENSE)
