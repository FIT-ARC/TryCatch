# Bundled recordings

Drop `.bin` recordings here and they are baked into the app.

Every `assets/recordings/*.bin` is listed in the Recorded flights screen next
to the user's own recordings and replays straight from the asset bytes — it is
never copied to disk. Bundled samples are read-only: rename, trim and delete
are not offered, and the card is marked `BUNDLED`.

Assets are bundled at build time, so after adding or removing a file here,
stop and restart the app (a hot reload/restart keeps the previous asset
bundle). If a new file still does not appear, run `flutter clean` once.
