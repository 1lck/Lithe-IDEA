# Workbench built-in backgrounds

This directory is reserved for background images bundled with the macOS app.

Use one of the ten numbered slots below. Place one image in the slot and name
it `background` with one of the supported extensions: `jpg`, `jpeg`, `png`,
`heic`, or `webp`. For example:

```text
macos/Sources/Lithe/Resources/WorkbenchBackgrounds/01/background.jpg
```

Slots `01` through `10` are intentionally independent so images with the same
filename do not collide when they are loaded from the application bundle. Keep
the source image and its usage permission in the project before adding it.

The application automatically shows every occupied slot in the built-in
background picker after it is rebuilt. Empty slots are not shown.
