import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

/* Fonts are self-hosted, not linked from Google. The team installs this as a
 * PWA on their phones over a home uplink; a CDN in the critical path means the
 * app renders in Segoe when the network is slow and leaks a request per person
 * per load to a third party. Two packages, served from our own origin.
 *
 * Instrument Sans is variable, so one file covers 400-650. Plex Mono is not,
 * so we take exactly the two weights the design uses and no more. */
import "@fontsource-variable/instrument-sans";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";

import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/motion.css";

import App from "./App.tsx";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
