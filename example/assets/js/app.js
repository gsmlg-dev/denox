import "../../deps/phoenix_html";
import { Socket } from "../../deps/phoenix";
import { LiveSocket } from "../../deps/phoenix_live_view";
import * as DuskmoonHooks from "../../deps/phoenix_duskmoon/assets/js/hooks/index.js";
import { registerAll } from "@duskmoon-dev/elements";

registerAll();

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...DuskmoonHooks },
});

liveSocket.connect();

window.liveSocket = liveSocket;
