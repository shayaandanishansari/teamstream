# Why this manifest looks like it does

Three things here are deliberate and easy to "clean up" wrongly.

**`"id": "/"`.** Without an explicit id, a PWA's identity is its `start_url`.
The Flutter manifest used `"start_url": "."`, which resolves relative to the
manifest URL. Changing that without pinning an id makes the browser treat this
as a DIFFERENT app: the three phones would keep their old home-screen icon
pointing at a dead shell and get a second icon for the new one. Pinning the same
id makes the existing icon update in place.

**The filename stays `manifest.json`.** A cached `index.html` still asks for
that exact path.

**The icons are the OLD icons, copied over.** Four files of insurance so that a
phone serving a cached shell, or an installed PWA that has not refreshed, gets a
picture rather than a broken tile.

See also `flutter_service_worker.js` in this directory, which is kept for a
related reason.
