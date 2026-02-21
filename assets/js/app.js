import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import CanvasHook from "./canvas_hook";

let csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");

let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { Canvas: CanvasHook },
});

liveSocket.connect();
window.liveSocket = liveSocket;
