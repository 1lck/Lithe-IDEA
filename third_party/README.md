# Third-party source policy

`third_party/` records pinned upstream inputs that Lithe needs to audit or
prepare during a build. Keep only the smallest reproducible input here:

- a manifest with the upstream repository, immutable revision, download URL,
  and checksum when an archive is fetched;
- the applicable license and notice beside a retained artifact, or a pointer
  to the packaged copy when the artifact lives in its owning resource folder;
- narrowly scoped patched source only when Lithe actually compiles that source
  and the patch cannot be consumed from an upstream package revision.

Do not copy complete upstream repositories, release binaries, documentation
sites, screenshots, tests, or CI configuration here for reference alone.
Build-time downloads belong in ignored artifact caches and runtime assets
belong in the platform, plugin, or resource directory that packages them.
