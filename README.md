# Clipz

> Wayland Clipboard history (`wlr-data-control-unstable-v1`)

Repo: https://codeberg.org/0x52534B/clipz  
Mirror: https://github.com/revathskumar/clipz


### Usage

```
clipz print
```

### Build

```
PKG_CONFIG=/usr/bin/pkg-config zig build
```

```
PKG_CONFIG=/usr/bin/pkg-config zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSmall --summary all
```


### License

[MIT](LICENSE)